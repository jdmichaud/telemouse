// tms — the telemouse server.
//
// A headless daemon that generates mouse and keyboard input on behalf of remote
// clients through the platform input backend (uinput on Linux, SendInput on
// Windows).
//
// It serves commands on two sockets bound to the same address/port:
//   * a UDP socket for pointer motion (`mouse x y`) -- low latency, loss tolerant;
//   * a TCP socket for clicks and key strokes -- reliable and ordered.
// These are serviced by one `Io.Select` event loop, so the input device is
// never touched concurrently -- no locking.
//
// Discovery is separate: an mDNS/DNS-SD responder (src/common/mdns.zig) runs on
// its own thread and answers `_telemouse._udp.local` queries on UDP 5353. It
// only reads immutable data, so it too needs no locking.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const net = std.Io.net;

const clap = @import("common/clap.zig");
const log = @import("common/log.zig");
const protocol = @import("common/protocol.zig");
const mdns = @import("common/mdns.zig");
const config = @import("tms/config.zig");
const input = @import("tms/input.zig");
const xdisplay = @import("common/xdisplay.zig");
const clipboard = @import("common/clipboard.zig");

const version = "0.1.0";

/// Set by the SIGINT/SIGTERM (or Windows console) handler so the event loop can
/// return cleanly and let `main`'s deferred cleanup run — most importantly
/// destroying the uinput device, which releases any keys the device holds.
var g_shutdown = std.atomic.Value(bool).init(false);

fn onPosixSignal(_: std.posix.SIG) callconv(.c) void {
    g_shutdown.store(true, .monotonic);
}

fn onWindowsCtrl(_: u32) callconv(.winapi) i32 {
    g_shutdown.store(true, .monotonic);
    return 1; // handled
}

extern "kernel32" fn SetConsoleCtrlHandler(
    handler: ?*const fn (u32) callconv(.winapi) i32,
    add: i32,
) callconv(.winapi) i32;

fn installShutdownHandler() void {
    switch (builtin.os.tag) {
        .linux => {
            const posix = std.posix;
            var act = posix.Sigaction{
                .handler = .{ .handler = onPosixSignal },
                .mask = posix.sigemptyset(),
                .flags = 0,
            };
            posix.sigaction(posix.SIG.INT, &act, null);
            posix.sigaction(posix.SIG.TERM, &act, null);
        },
        .windows => _ = SetConsoleCtrlHandler(onWindowsCtrl, 1),
        else => {},
    }
}

const Edge = enum {
    none,
    left,
    right,
    top,
    bottom,
    fn name(self: Edge) []const u8 {
        return switch (self) {
            .none => "none",
            .left => "left",
            .right => "right",
            .top => "top",
            .bottom => "bottom",
        };
    }
};

const Server = struct {
    io: Io,
    logger: *log.Logger,
    backend: *input.Backend,
    // Optional X connection: used to place the cursor absolutely (XWarpPointer,
    // which actually works, unlike the REL/ABS-mixed uinput device) and to watch
    // where the cursor really is so we can tell the client when it hits an edge.
    display: ?xdisplay.Display = null,
    clip: ?*clipboard.Clipboard = null,
    scr_w: i32 = 1920,
    scr_h: i32 = 1080,
    last_edge: Edge = .none,
    // Set while this server is "away" (cursor hidden because control is on the
    // client or another screen): the pointer position at the moment we hid. If
    // the local pointer moves away from it, the machine's own mouse is being
    // used, so we reveal the cursor again and hand it back to local control.
    away_ptr: ?xdisplay.Point = null,

    fn apply(self: *Server, cmd: protocol.Command) void {
        // Absolute placement goes through the display server (XWarpPointer); the
        // uinput device can't do absolute positioning. Everything else (relative
        // motion, clicks, keys, scroll) is uinput.
        switch (cmd) {
            // A crossing onto this server: reveal the cursor (it may have been
            // hidden when control last left), stop watching for local motion, and
            // place it at the entry point.
            .place => |m| {
                if (self.display) |*d| d.showCursor();
                self.away_ptr = null;
                self.moveAbs(m.x, m.y);
            },
            .mouse => |m| self.moveAbs(m.x, m.y),
            .moveto => |m| self.moveAbs(m.x, m.y),
            // Control left this server: hide its cursor and remember where the
            // pointer is, so if the local mouse moves it we can reveal the cursor
            // and let this machine be used directly (see checkLocalReveal).
            .hide => if (self.display) |*d| {
                d.hideCursor();
                self.away_ptr = d.queryPointer();
            },
            // The shared clipboard is handled in the event loop (it needs the
            // client channel and the clipboard worker), not here.
            .clipboard => {},
            else => self.backend.execute(self.logger, cmd) catch |e|
                self.logger.warn("command failed: {s}", .{@errorName(e)}),
        }
    }

    fn moveAbs(self: *Server, x: i32, y: i32) void {
        if (self.display) |*d| {
            d.warp(x, y);
            self.logger.debug("warp cursor to ({d}, {d})", .{ x, y });
        } else {
            self.backend.execute(self.logger, .{ .mouse = .{ .x = x, .y = y } }) catch {};
        }
        // The cursor was just placed *at* the entry edge; treat it as already
        // reached so we don't immediately bounce the client back.
        self.last_edge = self.edgeAt(x, y).edge;
    }

    const EdgeHit = struct { edge: Edge, perp: i32 };
    fn edgeAt(self: *Server, x: i32, y: i32) EdgeHit {
        if (x <= 0) return .{ .edge = .left, .perp = y };
        if (x >= self.scr_w - 1) return .{ .edge = .right, .perp = y };
        if (y <= 0) return .{ .edge = .top, .perp = x };
        if (y >= self.scr_h - 1) return .{ .edge = .bottom, .perp = x };
        return .{ .edge = .none, .perp = 0 };
    }

    /// After applying relative motion, check where the cursor really is; when it
    /// reaches a screen edge (for the first time), tell the client which side, so
    /// it can decide to cross. `w` is the client's TCP channel.
    fn checkEdge(self: *Server, w: *Io.Writer) void {
        var d = if (self.display) |*dp| dp else return;
        const p = d.queryPointer() orelse return;
        const hit = self.edgeAt(p.x, p.y);
        // Only announce on the transition *into* an edge, not every frame held
        // against it.
        if (hit.edge != .none and hit.edge != self.last_edge) {
            w.print("reach {s} {d}\n", .{ hit.edge.name(), hit.perp }) catch {};
            w.flush() catch {};
            self.logger.debug("cursor reached {s} edge at {d}", .{ hit.edge.name(), hit.perp });
        }
        self.last_edge = hit.edge;
    }

    /// Reveal the cursor at the centre of the screen and stop watching for local
    /// motion. Used when local control resumes — the local mouse moved, or the
    /// controlling client dropped — so the cursor reappears in a predictable spot
    /// rather than wherever it was last parked.
    fn revealAtCentre(self: *Server) void {
        self.away_ptr = null;
        if (self.display) |*d| {
            d.warp(@divTrunc(self.scr_w, 2), @divTrunc(self.scr_h, 2));
            d.showCursor();
        }
    }

    /// While this server is "away" (hidden), watch for its own pointer moving.
    /// Once it has (the local mouse is being used), reveal the cursor (recentred)
    /// so the machine behaves as if it weren't connected to a client. Polled from
    /// the event loop; only touches X when actually away.
    fn checkLocalReveal(self: *Server) void {
        const base = self.away_ptr orelse return;
        var d = if (self.display) |*dp| dp else return;
        const p = d.queryPointer() orelse return;
        if (p.x != base.x or p.y != base.y) {
            self.revealAtCentre();
            self.logger.debug("local mouse moved on the server; recentring its cursor for local control", .{});
        }
    }

    /// The event-loop wait time: short while watching for local motion (so the
    /// cursor reappears promptly), otherwise a lazy tick for shutdown checks.
    fn pollMs(self: *const Server) i64 {
        return if (self.away_ptr != null) 60 else 250;
    }

    /// A `clipboard` update arrived from the client: make it the local clipboard.
    fn onRemoteClipboard(self: *Server, data: []const u8) void {
        const clip = self.clip orelse return;
        var buf: [clipboard.max_text]u8 = undefined;
        const text = clipboard.decode(&buf, data) orelse return;
        clip.setRemote(text);
    }

    /// If something was copied locally, send it to the client (which fans it out
    /// to the other machines). `w` is the client's TCP channel.
    fn pumpClipboardOut(self: *Server, w: *Io.Writer) void {
        const clip = self.clip orelse return;
        var text_buf: [clipboard.max_text]u8 = undefined;
        const text = clip.takeLocalCopy(&text_buf) orelse return;
        var b64: [clipboard.max_text * 2]u8 = undefined;
        const payload = clipboard.encode(&b64, text);
        if (payload.len == 0) return;
        w.print("clipboard {s}\n", .{payload}) catch return;
        w.flush() catch {};
    }

    /// Parse and apply one command line. Returns the parsed command so the TCP
    /// path can acknowledge a `place` (see `eventLoop`).
    fn handle(self: *Server, line: []const u8) ?protocol.Command {
        const cmd = protocol.parse(line) catch |pe| switch (pe) {
            error.EmptyCommand => return null,
            else => {
                self.logger.debug("rejecting command: {s}", .{@errorName(pe)});
                return null;
            },
        };
        self.apply(cmd);
        return cmd;
    }
};

// Events the loop waits on. Each variant's payload is the return type of the
// async helper that produces it.
const Event = union(enum) {
    udp: ?net.IncomingMessage,
    accept: ?net.Stream,
    keyboard: ?[]const u8,
};

fn recvUdp(io: Io, sock: net.Socket, buf: []u8, timeout_ms: i64) ?net.IncomingMessage {
    // A bounded wait so the loop wakes periodically — to check for shutdown, and
    // to poll for local pointer motion while away. A timeout returns null, like a
    // spurious wakeup.
    const timeout: Io.Timeout = .{ .duration = .{
        .raw = Io.Duration.fromMilliseconds(timeout_ms),
        .clock = .awake,
    } };
    return sock.receiveTimeout(io, buf, timeout) catch null;
}

fn acceptTcp(io: Io, server: *net.Server) ?net.Stream {
    return server.accept(io) catch null;
}

fn readKeyboard(reader: *net.Stream.Reader) ?[]const u8 {
    return (reader.interface.takeDelimiter('\n') catch return null) orelse null;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    const parsed = clap.parser(.{
        .name = "tms",
        .description = "The telemouse server: remote control of mouse and keyboard.",
        .version = version,
        .options = &.{
            .{ .short = "a", .long = "addr", .arg = .{ .name = "addr", .type = []const u8 }, .help = "Address to bind (default 0.0.0.0)" },
            .{ .short = "p", .long = "port", .arg = .{ .name = "port", .type = []const u8 }, .help = "Port to listen on (default 24800)" },
            .{ .short = "c", .long = "config", .arg = .{ .name = "file", .type = []const u8 }, .help = "Configuration file (default: XDG config path)" },
            .{ .short = "L", .long = "log-level", .arg = .{ .name = "level", .type = []const u8 }, .help = "silent|error|warn|info|debug (default info)" },
            .{ .short = null, .long = "log-file", .arg = .{ .name = "file", .type = []const u8 }, .help = "Log to this file instead of stdout" },
            .{ .short = null, .long = "syslog", .help = "Log to the system logger (Linux only)" },
            .{ .short = null, .long = "backend", .arg = .{ .name = "kind", .type = []const u8 }, .help = "Linux input backend: auto|xtest|kernel (default auto)" },
            .{ .short = null, .long = "dry-run", .help = "Do not emit real input, only log commands" },
        },
    }).parse(args);

    const explicit_config = parsed.getOption([]const u8, "config") catch null;
    const loaded = config.load(io, arena, init.environ_map, explicit_config) catch
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
    const dry_run = parsed.getSwitch("dry-run") or cfg.dry_run;

    // The whole point of dry-run is to see what would be emitted, and input
    // events are logged at debug — so force at least debug in dry-run, otherwise
    // "input events are logged" is a promise the default (info) level breaks.
    const effective_level = if (dry_run and @intFromEnum(level) < @intFromEnum(log.Level.debug))
        .debug
    else
        level;

    var logger = buildLogger(io, effective_level, parsed.getSwitch("syslog"), cli_log_file, cfg);
    defer logger.deinit();

    logger.debug("telemouse server (tms) {s}", .{version});
    if (loaded.loaded) {
        logger.debug("loaded configuration from {s}", .{loaded.path});
    } else {
        logger.debug("no configuration file at {s}, using defaults", .{loaded.path});
    }

    // Pick the Linux injection backend. On an X11 session, prefer XTEST — it
    // goes through the X server, so it needs no /dev/uinput access (no udev rule
    // or `input` group). Falls back to uinput otherwise. `--backend` overrides.
    const backend_kind = (parsed.getOption([]const u8, "backend") catch null) orelse cfg.backend;
    const try_xtest = resolveBackend(backend_kind, init.environ_map) catch {
        logger.err("invalid --backend '{s}' (expected auto|xtest|kernel)", .{backend_kind});
        std.process.exit(1);
    };

    var backend = input.Backend.init(.{
        .device_name = cfg.device_name,
        .screen_width = cfg.screen_width,
        .screen_height = cfg.screen_height,
        .dry_run = dry_run,
        .try_xtest = try_xtest,
    }) catch |e| {
        logger.err("cannot initialize input backend: {s}", .{@errorName(e)});
        if (builtin.os.tag == .linux and !dry_run) {
            logger.err("XTEST unavailable and /dev/uinput not writable. On X11, install", .{});
            logger.err("libXtst (no permissions needed); otherwise add a udev rule, or use --dry-run.", .{});
        }
        std.process.exit(1);
    };
    defer backend.deinit();
    if (dry_run)
        logger.info("dry-run mode: input events are logged (debug), not emitted", .{})
    else
        logger.info("input backend: {s}", .{backend.describe()});

    const address = net.IpAddress.parse(addr, port) catch |e| {
        logger.err("invalid bind address '{s}': {s}", .{ addr, @errorName(e) });
        std.process.exit(1);
    };

    const udp = address.bind(io, .{ .mode = .dgram }) catch |e| {
        logger.err("cannot bind udp {s}:{d}: {s}", .{ addr, port, @errorName(e) });
        std.process.exit(1);
    };
    defer udp.close(io);

    var tcp = address.listen(io, .{ .reuse_address = true }) catch |e| {
        logger.err("cannot listen on tcp {s}:{d}: {s}", .{ addr, port, @errorName(e) });
        std.process.exit(1);
    };
    defer tcp.deinit(io);

    // Start the mDNS/DNS-SD responder on its own thread so the server is
    // discoverable. Failure here only means "not discoverable".
    const screen = input.screenSize(cfg.screen_width, cfg.screen_height);
    if (mdns.openResponder(&logger)) |handle| {
        const responder = mdns.Responder{
            .handle = handle,
            .command_port = port,
            .device_name = cfg.device_name,
            .width = screen.w,
            .height = screen.h,
        };
        if (std.Thread.spawn(.{}, mdns.Responder.run, .{responder})) |thread| {
            thread.detach();
            logger.debug("mDNS responder announcing _telemouse._udp on udp {d}", .{mdns.port});
        } else |e| {
            logger.warn("discovery responder could not start: {s}", .{@errorName(e)});
        }
    }

    var server = Server{ .io = io, .logger = &logger, .backend = &backend };
    // Optional X connection for absolute placement (XWarpPointer) and cursor
    // edge detection (the "reach" events that drive edge switching precisely).
    if (xdisplay.Display.open()) |d| server.display = d;
    defer if (server.display) |*d| d.close();

    // Shared clipboard: text copied here is offered to the client (and thus every
    // machine), and clipboard updates from the client become the local clipboard.
    var clip = clipboard.Clipboard.init();
    clip.start(&logger);
    defer clip.stop();
    server.clip = &clip;
    if (server.display) |*d| {
        const sz = d.size();
        server.scr_w = sz.w;
        server.scr_h = sz.h;
        logger.debug("cursor tracking via X ({d}x{d})", .{ sz.w, sz.h });
    } else {
        logger.warn("no X display: absolute placement + edge-reach unavailable (relative motion still works)", .{});
    }

    logger.info("listening on {s}:{d} (udp: mouse, tcp: keyboard)", .{ addr, port });

    // Handle Ctrl-C / termination so cleanup (uinput destroy, sockets) runs.
    installShutdownHandler();

    eventLoop(io, &server, udp, &tcp);
}

fn eventLoop(io: Io, server: *Server, udp: net.Socket, tcp: *net.Server) void {
    var qbuf: [4]Event = undefined;
    var select = Io.Select(Event).init(io, &qbuf);

    var udp_buf: [2048]u8 = undefined;

    // The single connected keyboard client, if any.
    var kbd: ?net.Stream = null;
    var kbd_reader: net.Stream.Reader = undefined;
    var kbd_rbuf: [4096]u8 = undefined;
    var kbd_writer: net.Stream.Writer = undefined;
    var kbd_wbuf: [4096]u8 = undefined; // sized for clipboard lines, not just acks

    select.async(.udp, recvUdp, .{ io, udp, &udp_buf, server.pollMs() });
    select.async(.accept, acceptTcp, .{ io, tcp });

    while (true) {
        if (g_shutdown.load(.acquire)) break;
        const event = select.await() catch break;
        // Any wake is a chance to notice the server's own mouse being used while
        // it is away, and to forward anything copied locally to the client.
        server.checkLocalReveal();
        if (kbd != null) server.pumpClipboardOut(&kbd_writer.interface);
        switch (event) {
            .udp => |maybe| {
                if (maybe) |msg| {
                    // After applying relative motion, tell the client if the
                    // cursor reached an edge so it can cross precisely.
                    if (server.handle(msg.data)) |cmd| {
                        if (cmd == .move and kbd != null) server.checkEdge(&kbd_writer.interface);
                    }
                }
                select.async(.udp, recvUdp, .{ io, udp, &udp_buf, server.pollMs() });
            },
            .accept => |maybe| {
                if (maybe) |stream| {
                    if (kbd == null) {
                        kbd = stream;
                        kbd_reader = stream.reader(io, &kbd_rbuf);
                        kbd_writer = stream.writer(io, &kbd_wbuf);
                        server.logger.debug("keyboard client connected", .{});
                        select.async(.keyboard, readKeyboard, .{&kbd_reader});
                    } else {
                        server.logger.debug("refusing extra keyboard client", .{});
                        stream.close(io);
                    }
                }
                select.async(.accept, acceptTcp, .{ io, tcp });
            },
            .keyboard => |maybe| {
                if (maybe) |line| {
                    // A `place` (edge-crossing placement) is acknowledged so the
                    // client can gate its UDP motion stream on the ack; a
                    // `clipboard` update is applied to the local clipboard.
                    if (server.handle(line)) |cmd| switch (cmd) {
                        .place => ackPlace(&kbd_writer.interface, server.logger),
                        .clipboard => |c| server.onRemoteClipboard(c.data),
                        else => {},
                    };
                    select.async(.keyboard, readKeyboard, .{&kbd_reader});
                } else {
                    if (kbd) |stream| stream.close(io);
                    kbd = null;
                    // The controlling client is gone: hand the machine back to
                    // local control with the cursor revealed at the screen centre.
                    server.revealAtCentre();
                    server.logger.debug("keyboard client disconnected", .{});
                }
            },
        }
    }

    // Drain the in-flight async operations before the caller closes the sockets,
    // otherwise a pending receive/accept would fault on a closed fd.
    server.logger.info("shutting down", .{});
    if (kbd) |stream| stream.close(io);
    select.cancelDiscard();
}

fn ackPlace(w: *Io.Writer, logger: *log.Logger) void {
    w.writeAll("placed\n") catch |e| {
        logger.debug("could not send placement ack: {s}", .{@errorName(e)});
        return;
    };
    w.flush() catch {};
}

/// Decide whether to prefer the XTEST backend, from the `--backend`/config value
/// and the session type: "auto" → XTEST on an X11 session, uinput otherwise;
/// "xtest" → always try XTEST; "kernel" → always uinput.
fn resolveBackend(kind: []const u8, env: *const std.process.Environ.Map) error{InvalidBackend}!bool {
    if (std.mem.eql(u8, kind, "kernel")) return false;
    if (std.mem.eql(u8, kind, "xtest")) return true;
    if (std.mem.eql(u8, kind, "auto")) return onX11(env);
    return error.InvalidBackend;
}

/// True on an X11 session. A Wayland session is deliberately *not* the X11 fast
/// path: XWayland exposes a `DISPLAY`, but XTEST through it cannot drive native
/// Wayland clients — so Wayland falls back to the kernel (uinput) backend.
fn onX11(env: *const std.process.Environ.Map) bool {
    if (env.get("WAYLAND_DISPLAY")) |v| {
        if (v.len > 0) return false;
    }
    if (env.get("DISPLAY")) |v| return v.len > 0;
    return false;
}

fn buildLogger(
    io: Io,
    level: log.Level,
    cli_syslog: bool,
    cli_log_file: ?[]const u8,
    cfg: config.Config,
) log.Logger {
    if (cli_syslog) return log.Logger.fromChoice(io, level, "tms", true, null);
    if (cli_log_file) |path| return log.Logger.fromChoice(io, level, "tms", false, path);
    if (cfg.syslog) return log.Logger.fromChoice(io, level, "tms", true, null);
    if (cfg.log_file) |path| return log.Logger.fromChoice(io, level, "tms", false, path);
    return log.Logger.fromChoice(io, level, "tms", false, null);
}
