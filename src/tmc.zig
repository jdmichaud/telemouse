// tmc — the telemouse client.
//
// Three modes:
//   * discovery (default, launched with no arguments from a terminal): broadcast
//     a discovery query and print the address of every tms on the LAN;
//   * single command (`-e "mouse 100 200"`): send one command and exit;
//   * stream (stdin is piped): forward one command per input line.
//
// Commands are routed by type: pointer motion goes over UDP, clicks and key
// strokes over TCP (see src/common/protocol.zig). Sending is fire-and-forget;
// commands are validated locally before they leave.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const File = std.Io.File;
const net = std.Io.net;

const clap = @import("common/clap.zig");
const log = @import("common/log.zig");
const keymap = @import("common/keymap.zig");
const clipboard = @import("common/clipboard.zig");
const mdns = @import("common/mdns.zig");
const common_config = @import("common/config.zig");
const session = @import("tmc/session.zig");
const switcher = @import("tmc/switcher.zig");
const evdev = @import("tmc/evdev.zig");
const xcapture = @import("tmc/xcapture.zig");
const wincapture = @import("tmc/wincapture.zig");
const xcursor = @import("tmc/xcursor.zig");
const configui = @import("ui/configui.zig");

const Sender = session.Sender;

const version = "0.1.0";

/// One screen in the lattice. The first entry (with no `addr`) is the local
/// screen (the client); the rest are neighbour servers, positioned in shared
/// virtual-desktop pixel space. Written by the configuration UI, but also
/// hand-editable.
pub const ScreenEntry = struct {
    /// The server's mDNS display name (informational / future name-based
    /// re-resolution). Empty for the client.
    name: []const u8 = "",
    /// "ip:port" of the server behind this screen; null marks the client screen.
    addr: ?[]const u8 = null,
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 1920,
    h: i32 = 1080,
};

const Config = struct {
    addr: []const u8 = "127.0.0.1",
    port: u16 = 24800,
    log_level: []const u8 = "info",
    log_file: ?[]const u8 = null,
    syslog: bool = false,
    discover_timeout_ms: i64 = 600,
    // Linux capture backend: "auto" (XInput2 on X11, else evdev), "xinput", or
    // "evdev" (force /dev/input). Ignored on Windows.
    capture: []const u8 = "auto",

    // The full screen lattice (from the configuration UI). When present it
    // supersedes the `left/right/top/bottom` shorthand below. The client's own
    // resolution is auto-detected from the display, never configured.
    screens: ?[]const ScreenEntry = null,

    // Neighbour servers ("ip:port") reached by pushing the pointer off the
    // corresponding edge of the local screen. Null means that edge is a wall.
    // A simple shorthand for the common four-neighbour star; `screens` is the
    // general form.
    left: ?[]const u8 = null,
    right: ?[]const u8 = null,
    top: ?[]const u8 = null,
    bottom: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    const parsed = clap.parser(.{
        .name = "tmc",
        .description = "The telemouse client: discover servers and send mouse/keyboard commands.",
        .version = version,
        .options = &.{
            .{ .short = "a", .long = "addr", .arg = .{ .name = "addr", .type = []const u8 }, .help = "Server address (default 127.0.0.1)" },
            .{ .short = "p", .long = "port", .arg = .{ .name = "port", .type = []const u8 }, .help = "Server port (default 24800)" },
            .{ .short = "e", .long = "execute", .arg = .{ .name = "command", .type = []const u8 }, .help = "Send a single command then exit (e.g. -e \"mouse 100 200\")" },
            .{ .short = "c", .long = "config", .arg = .{ .name = "file", .type = []const u8 }, .help = "Configuration file (default: XDG config path)" },
            .{ .short = "C", .long = "configure", .help = "Open the screen-arrangement configuration UI" },
            .{ .short = "L", .long = "log-level", .arg = .{ .name = "level", .type = []const u8 }, .help = "silent|error|warn|info|debug (default info)" },
            .{ .short = null, .long = "log-file", .arg = .{ .name = "file", .type = []const u8 }, .help = "Log to this file instead of stdout" },
            .{ .short = null, .long = "capture", .arg = .{ .name = "kind", .type = []const u8 }, .help = "Linux capture backend: auto|xinput|evdev (default auto)" },
            .{ .short = null, .long = "syslog", .help = "Log to the system logger (Linux only)" },
        },
    }).parse(args);

    const explicit_config = parsed.getOption([]const u8, "config") catch null;
    const loaded = common_config.load(Config, io, arena, init.environ_map, "tmc.zon", explicit_config) catch
        std.process.exit(1);
    const cfg = loaded.config;

    const addr = (parsed.getOption([]const u8, "addr") catch null) orelse cfg.addr;
    const port: u16 = blk: {
        const p = parsed.getOption(u16, "port") catch {
            std.debug.print("error: invalid port value\n", .{});
            std.process.exit(1);
        };
        break :blk p orelse cfg.port;
    };
    const level_str = (parsed.getOption([]const u8, "log-level") catch null) orelse cfg.log_level;
    const level = log.Level.parse(level_str) orelse {
        std.debug.print("error: invalid log level '{s}'\n", .{level_str});
        std.process.exit(1);
    };
    const cli_log_file = parsed.getOption([]const u8, "log-file") catch null;
    const use_syslog = parsed.getSwitch("syslog") or cfg.syslog;
    const log_file = cli_log_file orelse cfg.log_file;

    var logger = log.Logger.fromChoice(io, level, "tmc", use_syslog, log_file);
    defer logger.deinit();

    const execute = parsed.getOption([]const u8, "execute") catch null;

    // Single-command mode.
    if (execute) |command| {
        const server = net.IpAddress.parse(addr, port) catch |e| {
            logger.err("invalid server address '{s}': {s}", .{ addr, @errorName(e) });
            std.process.exit(1);
        };
        var client = Sender.init(io, &logger, server) catch std.process.exit(1);
        defer client.deinit();
        const ok = client.dispatch(std.mem.trim(u8, command, " \t\r\n"));
        std.process.exit(if (ok) 0 else 1);
    }

    const configure = parsed.getSwitch("configure");
    const has_edges = cfg.left != null or cfg.right != null or cfg.top != null or cfg.bottom != null;
    const has_lattice = if (cfg.screens) |s| s.len > 1 else false;
    const configured = has_edges or has_lattice;
    const interactive_tty = File.stdin().isTty(io) catch false;

    // Configuration UI: explicit --configure, or a first run with no config file
    // from a terminal.
    if (configure or (!loaded.loaded and !configured and interactive_tty)) {
        if (!loaded.loaded and !configure) {
            printOut(io, "no config file, opening configuration UI\n", .{});
        }
        const disp = xcursor.displaySize(); // the client's own resolution
        const initial: configui.Arrangement = .{
            .screen_width = disp.w,
            .screen_height = disp.h,
            .screens = toUiScreens(arena, cfg.screens),
            .left = cfg.left,
            .right = cfg.right,
            .top = cfg.top,
            .bottom = cfg.bottom,
        };
        switch (configui.run(io, arena, &logger, initial)) {
            .no_display => {
                printOut(io, "no display available; run 'tmc --configure' on a desktop, or edit {s} by hand\n", .{loaded.path});
                std.process.exit(1);
            },
            .cancelled => printOut(io, "configuration unchanged\n", .{}),
            .saved => |screens| {
                saveConfig(io, arena, loaded.path, cfg, screens) catch |e| {
                    logger.err("could not save configuration to {s}: {s}", .{ loaded.path, @errorName(e) });
                    std.process.exit(1);
                };
                printOut(io, "configuration saved in {s}\n", .{loaded.path});
            },
        }
        return;
    }

    // Edge-switching mode: if a lattice or any neighbour is configured, watch
    // the pointer and hand control across screen edges.
    if (configured) {
        if (builtin.os.tag != .linux) {
            logger.err("edge switching is currently supported only on Linux", .{});
            std.process.exit(1);
        }
        // Choose the capture backend: XInput2 on an X11 session (no /dev/input
        // permission needed), else evdev. `--capture` overrides.
        const cap_kind = (parsed.getOption([]const u8, "capture") catch null) orelse cfg.capture;
        const capture_x11 = resolveCapture(cap_kind, init.environ_map) catch {
            logger.err("invalid --capture '{s}' (expected auto|xinput|evdev)", .{cap_kind});
            std.process.exit(1);
        };
        runEdgeSwitch(io, arena, &logger, cfg, capture_x11);
        return;
    }

    // No command given: from an interactive terminal, discover servers; from a
    // pipe/redirect, forward stdin.
    if (interactive_tty) {
        discover(io, arena, &logger, cfg.discover_timeout_ms);
        return;
    }

    const server = net.IpAddress.parse(addr, port) catch |e| {
        logger.err("invalid server address '{s}': {s}", .{ addr, @errorName(e) });
        std.process.exit(1);
    };
    var client = Sender.init(io, &logger, server) catch std.process.exit(1);
    defer client.deinit();

    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = File.stdin().reader(io, &stdin_buf);
    const sr = &stdin_reader.interface;
    while (true) {
        const line = (sr.takeDelimiter('\n') catch |e| switch (e) {
            error.StreamTooLong => {
                logger.err("input line too long", .{});
                break;
            },
            error.ReadFailed => break,
        }) orelse break;
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        _ = client.dispatch(trimmed);
    }
}

/// Decide whether to capture via XInput2 from the `--capture`/config value and
/// the session type: "auto" → XInput2 on an X11 session (no /dev/input needed),
/// evdev otherwise; "xinput" → always; "evdev" → never.
fn resolveCapture(kind: []const u8, env: *const std.process.Environ.Map) error{InvalidCapture}!bool {
    if (std.mem.eql(u8, kind, "evdev")) return false;
    if (std.mem.eql(u8, kind, "xinput")) return true;
    if (std.mem.eql(u8, kind, "auto")) return onX11(env);
    return error.InvalidCapture;
}

/// True on an X11 session. On Wayland, XInput2 through XWayland cannot see global
/// input, so Wayland falls back to evdev.
fn onX11(env: *const std.process.Environ.Map) bool {
    if (env.get("WAYLAND_DISPLAY")) |v| {
        if (v.len > 0) return false;
    }
    if (env.get("DISPLAY")) |v| return v.len > 0;
    return false;
}

fn discover(io: Io, arena: std.mem.Allocator, logger: *log.Logger, timeout_ms: i64) void {
    const servers = mdns.discover(io, arena, logger, timeout_ms) catch return;
    if (servers.len == 0) {
        printOut(io, "No telemouse servers found on the local network.\n", .{});
        return;
    }
    for (servers) |s| {
        if (s.width > 0 and s.height > 0)
            printOut(io, "{s}  {s} ({d}x{d})\n", .{ s.display, s.name, s.width, s.height })
        else
            printOut(io, "{s}  {s}\n", .{ s.display, s.name });
    }
}

fn printOut(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    File.stdout().writeStreamingAll(io, s) catch {};
}

/// Serialise the client configuration to ZON at `path`, merging the UI-produced
/// screen arrangement into the values already loaded. Preserves the unrelated
/// settings (address, logging, discovery) so re-running the UI is non-destructive.
/// Convert the config's `ScreenEntry` list into the UI's `Screen` type for
/// pre-populating the dialog.
fn toUiScreens(arena: std.mem.Allocator, entries: ?[]const ScreenEntry) []const configui.Screen {
    const e = entries orelse return &.{};
    const out = arena.alloc(configui.Screen, e.len) catch return &.{};
    for (e, 0..) |s, i| {
        out[i] = .{ .name = s.name, .addr = s.addr, .x = s.x, .y = s.y, .w = s.w, .h = s.h };
    }
    return out;
}

/// Serialise the client configuration to ZON at `path`, writing the `screens`
/// lattice produced by the UI and preserving the unrelated settings (address,
/// logging, discovery). The client's own resolution comes from `screens[0]`.
fn saveConfig(io: Io, arena: std.mem.Allocator, path: []const u8, base: Config, screens: []const configui.Screen) !void {
    _ = arena;
    var buf: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try w.print(".{{\n", .{});
    try w.print("    .addr = \"{s}\",\n", .{base.addr});
    try w.print("    .port = {d},\n", .{base.port});
    try w.print("    .log_level = \"{s}\",\n", .{base.log_level});
    if (base.log_file) |lf| try w.print("    .log_file = \"{s}\",\n", .{lf});
    if (base.syslog) try w.print("    .syslog = true,\n", .{});
    try w.print("    .discover_timeout_ms = {d},\n", .{base.discover_timeout_ms});
    if (screens.len > 0) {
        // `screens[0]` is the client (its resolution); the rest are neighbours.
        try w.print("    .screens = .{{\n", .{});
        for (screens) |s| {
            try w.print("        .{{ .name = \"{s}\"", .{s.name});
            if (s.addr) |a| try w.print(", .addr = \"{s}\"", .{a});
            try w.print(", .x = {d}, .y = {d}, .w = {d}, .h = {d} }},\n", .{ s.x, s.y, s.w, s.h });
        }
        try w.print("    }},\n", .{});
    }
    try w.print("}}\n", .{});

    if (std.fs.path.dirname(path)) |dir| {
        Io.Dir.cwd().createDirPath(io, dir) catch {};
    }
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = w.buffered() });
}

fn parseNeighbor(text: []const u8) ?net.IpAddress {
    const colon = std.mem.lastIndexOfScalar(u8, text, ':') orelse return null;
    const host = text[0..colon];
    const port = std.fmt.parseInt(u16, text[colon + 1 ..], 10) catch return null;
    return net.IpAddress.parse(host, port) catch null;
}

/// The discovered server matching a saved screen, by mDNS name first (stable
/// across DHCP) then by address; null if discovery didn't see it.
fn findDiscovered(e: ScreenEntry, discovered: []const mdns.Server) ?mdns.Server {
    if (e.name.len > 0) {
        for (discovered) |s| {
            if (s.name.len > 0 and std.mem.eql(u8, s.name, e.name)) return s;
        }
    }
    if (e.addr) |a| {
        for (discovered) |s| {
            if (std.mem.eql(u8, s.display, a)) return s;
        }
    }
    return null;
}

/// Fill `screens`/`addrs` (both `switcher.max_screens` long) with the lattice
/// and return its length. Screen 0 is always the local screen (the client, no
/// sender). Prefers the full `.screens` lattice; falls back to the four-edge
/// star shorthand.
///
/// `discovered` (may be empty) both re-resolves names to their current
/// addresses and provides startup liveness: a configured neighbour that
/// discovery cannot see is dropped from the lattice, so its edge becomes a wall
/// (and anything only reachable through it is walled off too). Liveness is only
/// applied when discovery found at least one server — if the scan came back
/// empty (mDNS unavailable) the saved lattice is trusted as-is.
fn buildLattice(
    cfg: Config,
    client_w: i32,
    client_h: i32,
    logger: *log.Logger,
    discovered: []const mdns.Server,
    screens: *[switcher.max_screens]switcher.Rect,
    addrs: *[switcher.max_screens]?net.IpAddress,
) usize {
    if (cfg.screens) |entries| {
        const apply_liveness = discovered.len > 0;
        var n: usize = 0;
        for (entries, 0..) |e, idx| {
            if (n >= switcher.max_screens) {
                logger.warn("more than {d} screens configured; ignoring the rest", .{switcher.max_screens});
                break;
            }
            screens[n] = .{ .x = e.x, .y = e.y, .w = @max(e.w, 1), .h = @max(e.h, 1) };
            // The first entry is the local screen (the client, no sender).
            if (idx == 0) {
                addrs[0] = null;
                n = 1;
                continue;
            }
            const disc = findDiscovered(e, discovered);
            if (apply_liveness and disc == null) {
                logger.info("neighbour '{s}' is offline; that edge acts as a wall", .{e.name});
                continue; // dropped -> the switcher sees a gap and clamps
            }
            const text = if (disc) |d| d.display else (e.addr orelse continue);
            const addr = parseNeighbor(text) orelse {
                logger.err("ignoring screen '{s}' with invalid address '{s}' (expected ip:port)", .{ e.name, text });
                continue;
            };
            if (disc != null and (e.addr == null or !std.mem.eql(u8, text, e.addr.?))) {
                logger.info("resolved '{s}' to {s} (from discovery)", .{ e.name, text });
            }
            addrs[n] = addr;
            n += 1;
        }
        if (n > 0) return n;
    }

    // Star shorthand: the client at the origin, each configured neighbour a
    // same-sized screen touching a client edge.
    const cw: i32 = @max(client_w, 1);
    const ch: i32 = @max(client_h, 1);
    const shorthand = [_]struct { text: ?[]const u8, rect: switcher.Rect }{
        .{ .text = cfg.left, .rect = .{ .x = -cw, .y = 0, .w = cw, .h = ch } },
        .{ .text = cfg.right, .rect = .{ .x = cw, .y = 0, .w = cw, .h = ch } },
        .{ .text = cfg.top, .rect = .{ .x = 0, .y = -ch, .w = cw, .h = ch } },
        .{ .text = cfg.bottom, .rect = .{ .x = 0, .y = ch, .w = cw, .h = ch } },
    };
    screens[0] = .{ .x = 0, .y = 0, .w = cw, .h = ch };
    addrs[0] = null;
    var n: usize = 1;
    for (shorthand) |sh| {
        const text = sh.text orelse continue;
        const addr = parseNeighbor(text) orelse {
            logger.err("ignoring invalid neighbour '{s}' (expected ip:port)", .{text});
            continue;
        };
        screens[n] = sh.rect;
        addrs[n] = addr;
        n += 1;
    }
    return n;
}

/// Watch the local pointer and hand mouse+keyboard control to a neighbour
/// server when it crosses a configured edge. The capture mechanism is platform
/// specific (evdev on Linux, low-level hooks on Windows).
fn runEdgeSwitch(io: Io, arena: std.mem.Allocator, logger: *log.Logger, cfg: Config, capture_x11: bool) void {
    // Re-resolve neighbour names to their current addresses (best-effort): a
    // server that changed IP (DHCP) is still reached by its stable mDNS name.
    const discovered: []const mdns.Server = if (cfg.screens != null)
        mdns.discover(io, arena, logger, cfg.discover_timeout_ms) catch &.{}
    else
        &.{};

    // The client's own resolution, auto-detected from the display.
    const disp = xcursor.displaySize();

    var screens: [switcher.max_screens]switcher.Rect = undefined;
    var addrs: [switcher.max_screens]?net.IpAddress = undefined;
    const n = buildLattice(cfg, disp.w, disp.h, logger, discovered, &screens, &addrs);

    var sess = session.Session.init(io, logger, screens[0..n], addrs[0..n]);
    defer sess.deinit();
    if (!sess.hasNeighbours()) {
        logger.err("no valid neighbours configured", .{});
        return;
    }

    // Share the clipboard across machines: copies here go to every server, and a
    // copy on any server is relayed to the rest through this client hub.
    var clip = clipboard.Clipboard.init();
    clip.start(logger);
    defer clip.stop();
    sess.clip = &clip;

    // Pre-open the neighbour TCP channels so the first crossing is snappy.
    sess.connectAll();

    switch (builtin.os.tag) {
        .linux => if (capture_x11)
            runCapture(xcapture.XCapture, &sess, logger, disp.w, disp.h)
        else
            runCapture(evdev.Devices, &sess, logger, disp.w, disp.h),
        .windows => wincapture.run(&sess, logger),
        else => logger.err("edge switching is not supported on this platform", .{}),
    }
}

/// Linux capture loop, generic over the capture backend (evdev or XInput2 — both
/// expose open/next/grab/ungrab/deinit and a `key_names` override). Reads input,
/// feeds the session, and grabs/ungrabs as control switches screens.
fn runCapture(comptime Cap: type, sess: *session.Session, logger: *log.Logger, client_w: i32, client_h: i32) void {
    const backend = if (Cap == xcapture.XCapture) "XInput2" else "evdev";
    var devices = Cap.open() catch |e| {
        logger.err("cannot start {s} input capture: {s}", .{ backend, @errorName(e) });
        if (Cap == evdev.Devices)
            logger.err("read access to /dev/input is required (add your user to the 'input' group), or use --capture xinput on X11.", .{})
        else
            logger.err("XInput2 capture is unavailable; is this an X11 session? Try --capture evdev.", .{});
        std.process.exit(1);
    };
    defer devices.deinit();

    // The display server lets us track the *real* (OS-accelerated) cursor while
    // local, and hide it while control is remote. Optional: null on Wayland /
    // headless, in which case switching still works off raw motion.
    var xc = xcursor.XCursor.open();
    defer if (xc) |*c| c.close();
    if (xc == null) logger.warn("no X display; cursor tracking/hiding disabled (edge crossing may be imprecise)", .{});

    // Snapshot the local keyboard layout so captured scancodes are forwarded
    // through the user's xmodmap/XKB remaps (e.g. a Caps Lock mapped to a meta
    // modifier sends `meta`, not `capslock`). Falls back to raw names with no X.
    var key_names: [256]?[]const u8 = @splat(null);
    if (xc) |*c| {
        c.loadKeyNames(&key_names);
        // Report only genuine remaps (forwarded key resolves to a *different*
        // scancode than the physical one), not mere name aliases (return/enter).
        for (key_names, 0..) |maybe, code| {
            const nm = maybe orelse continue;
            const mapped = keymap.keycode(nm) orelse continue;
            if (mapped != code) {
                const def = keymap.keyName(@intCast(code)) orelse "?";
                logger.info("carrying over local key remap: {s} -> {s}", .{ def, nm });
            }
        }
        devices.key_names = &key_names;
    }

    logger.info("edge switching active on a {d}x{d} screen ({s} capture); push the pointer to a configured edge", .{ client_w, client_h, backend });

    while (true) {
        const event = devices.next() orelse break;
        switch (event) {
            .motion => |m| {
                // On the local screen, snap the virtual cursor to the true cursor
                // position so the crossing is detected exactly at the edge (not
                // drifted by pointer acceleration).
                if (xc) |*c| {
                    if (sess.onClient()) {
                        if (c.queryPointer()) |p| sess.syncClientCursor(p.x, p.y);
                    }
                }
                const d = sess.decide(m.dx, m.dy);
                if (d.out) |o| {
                    if (o.tag == .move) logger.debug("forwarding remote move ({d}, {d})", .{ o.a, o.b });
                }
                applyTransition(sess, &devices, &xc, logger, d);
            },
            .button => |b| if (sess.captureButton(b.down, b.name)) |cmd| sess.forward(cmd),
            .key => |k| {
                // Panic escape: Ctrl+Alt+Esc always returns control here, so a
                // broken crossing can never leave you needing a reboot.
                if (sess.panicRequested(k.down, k.name)) {
                    returnHome(sess, &devices, &xc, "panic (Ctrl+Alt+Esc)", logger);
                    continue;
                }
                if (sess.captureKey(k.down, k.name)) |cmd| sess.forward(cmd);
            },
            .scroll => |sc| if (sess.captureScroll(sc.dx, sc.dy)) |cmd| sess.forward(cmd),
        }
        // Drain server->client messages: a `reach` crosses (hop to a neighbour or
        // back home) precisely; a `clipboard` update is applied and relayed.
        while (sess.pumpServers()) |rd| applyTransition(sess, &devices, &xc, logger, rd);
        // Forward anything just copied locally to the servers.
        sess.pumpClipboardOut();
        // If control is remote and the server's connection dropped (it quit or
        // the network broke), come home so the cursor is never stranded on a
        // dead remote with no way back.
        if (sess.activeServerLost())
            returnHome(sess, &devices, &xc, "lost connection to the active server", logger);
    }
}

/// Force control back to the local screen: release the grab, restore and place
/// the cursor, and reset the session. Shared by the panic key and the
/// connection-lost watchdog.
fn returnHome(sess: *session.Session, devices: anytype, xc: *?xcursor.XCursor, reason: []const u8, logger: *log.Logger) void {
    const home = sess.forceHome();
    devices.ungrab();
    if (xc.*) |*c| {
        c.warp(home.x, home.y);
        c.showCursor();
    }
    logger.warn("{s}: control returned to the local screen", .{reason});
}

/// Act on a switch decision (whether from local motion or a server reach event):
/// grab/ungrab the devices, hide/warp/show the cursor, and forward the command.
/// `devices` is the active capture backend (evdev or XInput2).
fn applyTransition(sess: *session.Session, devices: anytype, xc: *?xcursor.XCursor, logger: *log.Logger, d: session.Decision) void {
    switch (d.transition) {
        .none => {
            if (d.out) |cmd| sess.forward(cmd);
        },
        .grab => {
            // Confirm the neighbour is connected and answering BEFORE committing
            // the handover (grab + hide). Otherwise a configured-but-absent (or
            // dead) server would strand the cursor off-screen with no way back
            // short of a reboot. If it doesn't answer, roll back and stay local.
            const cmd = d.out orelse return;
            if (sess.confirmPlacement(cmd)) {
                devices.grab();
                if (xc.*) |*c| c.hideCursor();
                sess.clearUnreachable();
                logger.info("control handed to a neighbour screen", .{});
            } else {
                const home = sess.abortCross();
                if (xc.*) |*c| c.warp(home.x, home.y);
                sess.warnUnreachableOnce(cmd.edge);
                return; // not committed: no grab, no hide, nothing forwarded
            }
        },
        .ungrab => |p| {
            devices.ungrab();
            if (xc.*) |*c| {
                c.warp(p.x, p.y); // put the local cursor back where it left
                c.showCursor();
            }
            logger.info("control returned to local screen", .{});
            if (d.out) |cmd| sess.forward(cmd);
        },
    }
    while (sess.nextPending()) |cmd| sess.forward(cmd); // modifier hand-off
}
