// The live configuration dialog: discover servers, let the user arrange them
// around the client in a snap-together lattice, and hand back the resulting
// edge assignments. The rendering and layout maths are pure and unit-tested;
// the window/event loop is the only untestable-headless shell.

const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const log = @import("../common/log.zig");
const mdns = @import("../common/mdns.zig");
const fb = @import("framebuffer.zig");
const classic = @import("classic.zig");
const font = @import("font.zig");
const canvas = @import("canvas.zig");
const window = @import("window.zig");
const marlett = @import("marlett.zig");

const max_screens = 16;

/// One screen in the lattice, as read from / written to the config. The client
/// is the entry with `addr == null`.
pub const Screen = struct {
    name: []const u8 = "",
    addr: ?[]const u8 = null,
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 1920,
    h: i32 = 1080,
};

/// Input to the UI: the client resolution plus any pre-existing arrangement to
/// restore. If `screens` is non-empty it seeds the lattice; otherwise the legacy
/// `left/right/top/bottom` edge shorthand seeds the placement of discovered
/// servers.
pub const Arrangement = struct {
    screen_width: i32,
    screen_height: i32,
    screens: []const Screen = &.{},
    left: ?[]const u8 = null,
    right: ?[]const u8 = null,
    top: ?[]const u8 = null,
    bottom: ?[]const u8 = null,
};

pub const Outcome = union(enum) {
    /// No display available (headless / no DISPLAY): caller prints guidance.
    no_display,
    /// User cancelled or closed the window; leave the config untouched.
    cancelled,
    /// User accepted; persist this lattice (the connected screens, client first).
    saved: []const Screen,
};

// --------------------------------------------------------------------------
// Dialog geometry (fixed-size window, classic dialog metrics).
// --------------------------------------------------------------------------

// X11 keysym for Escape (XK_Escape).
const key_escape: u32 = 0xff1b;

const win_w = 900;
const win_h = 620;
const caption_rect = Rect{ .x = 3, .y = 3, .w = win_w - 6, .h = 20 };
const close_rect = Rect{ .x = win_w - 3 - 20, .y = 6, .w = 18, .h = 14 };
// Bottom strip layout: well, then the status bar, then the buttons — stacked
// with gaps so nothing overlaps.
const well_rect = Rect{ .x = 10, .y = 30, .w = win_w - 20, .h = win_h - 94 };
const status_rect = Rect{ .x = 10, .y = win_h - 58, .w = win_w - 20, .h = 16 };

const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    fn contains(self: Rect, px: i32, py: i32) bool {
        return px >= self.x and px < self.x + self.w and py >= self.y and py < self.y + self.h;
    }
};

const Button = struct { rect: Rect, label: []const u8, default: bool };

const btn_y = win_h - 32;
const buttons = [_]Button{
    .{ .rect = .{ .x = win_w - 4 * 74 - 8, .y = btn_y, .w = 70, .h = 24 }, .label = "OK", .default = true },
    .{ .rect = .{ .x = win_w - 3 * 74 - 8, .y = btn_y, .w = 70, .h = 24 }, .label = "Cancel", .default = false },
    .{ .rect = .{ .x = win_w - 2 * 74 - 8, .y = btn_y, .w = 70, .h = 24 }, .label = "Rescan", .default = false },
    .{ .rect = .{ .x = win_w - 1 * 74 - 8, .y = btn_y, .w = 70, .h = 24 }, .label = "Identify", .default = false },
};
const btn_ok = 0;
const btn_cancel = 1;
const btn_rescan = 2;
const btn_identify = 3;

// --------------------------------------------------------------------------
// Model
// --------------------------------------------------------------------------

const Node = struct {
    screen: canvas.Screen, // geometry in virtual-desktop pixels + state
    label: []const u8, // display name
    display: []const u8, // "ip:port" (empty for the client)
};

const Model = struct {
    nodes: [max_screens]Node = undefined,
    n: usize = 0,
    selected: usize = 0,
    status: []const u8 = "drag a screen to a client edge to connect it",

    fn recompute(self: *Model) void {
        var scr: [max_screens]canvas.Screen = undefined;
        for (0..self.n) |i| scr[i] = self.nodes[i].screen;
        canvas.recomputeConnectivity(scr[0..self.n]);
        for (0..self.n) |i| {
            // Client stays client; others reflect connectivity as online/orphaned.
            if (i == 0) continue;
            self.nodes[i].screen.snapped = scr[i].snapped;
            if (self.nodes[i].screen.state != .offline) {
                self.nodes[i].screen.state = if (scr[i].snapped) .online else .orphaned;
            }
        }
    }
};

/// Build the initial model. Client is node 0 at the world origin. If a saved
/// `screens` lattice is present it is restored (positions preserved, each server
/// marked online/offline by whether discovery currently sees it, and any
/// newly-discovered server added floating); otherwise discovered servers are
/// placed adjacent to the client, honouring the legacy edge shorthand.
fn buildModel(
    arena: std.mem.Allocator,
    cw: i32,
    ch: i32,
    existing: Arrangement,
    servers: []const mdns.Server,
) Model {
    var m = Model{};

    if (existing.screens.len > 0) {
        // Locate the client entry (addr == null) and normalise so it is at the
        // origin, then restore each saved server at its (translated) position.
        var cx: i32 = 0;
        var cy: i32 = 0;
        var client_w = cw;
        var client_h = ch;
        for (existing.screens) |e| {
            if (e.addr == null) {
                cx = e.x;
                cy = e.y;
                client_w = @max(e.w, 1);
                client_h = @max(e.h, 1);
                break;
            }
        }
        m.nodes[0] = .{
            .screen = .{ .x = 0, .y = 0, .w = client_w, .h = client_h, .state = .client, .snapped = true },
            .label = "this pc",
            .display = "",
        };
        m.n = 1;

        for (existing.screens) |e| {
            if (e.addr == null) continue; // the client, already placed
            if (m.n >= max_screens) break;
            // Match by name first (stable across DHCP), then by address.
            const disc = matchServer(servers, e.name, e.addr.?);
            const online = disc != null;
            const sw: i32 = if (disc) |d| (if (d.width > 0) d.width else @max(e.w, 1)) else @max(e.w, 1);
            const sh: i32 = if (disc) |d| (if (d.height > 0) d.height else @max(e.h, 1)) else @max(e.h, 1);
            const label = if (disc) |d| d.name else e.name;
            // Refresh the address from discovery so a moved server is re-saved
            // with its current ip:port.
            const cur_addr = if (disc) |d| d.display else e.addr.?;
            m.nodes[m.n] = .{
                .screen = .{ .x = e.x - cx, .y = e.y - cy, .w = sw, .h = sh, .state = if (online) .online else .offline, .snapped = true },
                .label = arena.dupe(u8, label) catch label,
                .display = arena.dupe(u8, cur_addr) catch cur_addr,
            };
            m.n += 1;
        }
        // Any newly-discovered server not already in the lattice: add floating.
        for (servers) |s| {
            if (m.n >= max_screens) break;
            if (hasServer(&m, s.name, s.display)) continue;
            addDiscovered(&m, arena, s, client_w, client_h, null);
        }
        m.recompute();
        return m;
    }

    // No saved lattice: place discovered servers around the client, honouring
    // the legacy edge shorthand.
    m.nodes[0] = .{
        .screen = .{ .x = 0, .y = 0, .w = cw, .h = ch, .state = .client, .snapped = true },
        .label = "this pc",
        .display = "",
    };
    m.n = 1;
    for (servers) |s| {
        if (m.n >= max_screens) break;
        addDiscovered(&m, arena, s, cw, ch, matchExistingSide(existing, s.display));
    }
    m.recompute();
    return m;
}

/// Append a discovered server to the model, placed on `forced_side` if given,
/// else the first free client edge (floating if none).
fn addDiscovered(m: *Model, arena: std.mem.Allocator, s: mdns.Server, cw: i32, ch: i32, forced_side: ?Side) void {
    const sw: i32 = if (s.width > 0) s.width else cw;
    const sh: i32 = if (s.height > 0) s.height else ch;
    const side = forced_side orelse freeSide(m);
    const pos = sidePlacement(side, cw, ch, sw, sh);
    m.nodes[m.n] = .{
        .screen = .{ .x = pos.x, .y = pos.y, .w = sw, .h = sh, .state = .online, .snapped = side != null },
        .label = arena.dupe(u8, s.name) catch s.name,
        .display = arena.dupe(u8, s.display) catch s.display,
    };
    m.n += 1;
}

/// Find the discovered server for a saved screen: by mDNS name first (stable
/// across DHCP), then by address.
fn matchServer(servers: []const mdns.Server, name: []const u8, addr: []const u8) ?mdns.Server {
    if (name.len > 0) {
        for (servers) |s| {
            if (s.name.len > 0 and std.mem.eql(u8, s.name, name)) return s;
        }
    }
    for (servers) |s| {
        if (std.mem.eql(u8, s.display, addr)) return s;
    }
    return null;
}

/// Whether the model already holds a node for this server (by address or name),
/// so a re-discovered server is not added twice.
fn hasServer(m: *const Model, name: []const u8, display: []const u8) bool {
    for (0..m.n) |i| {
        const nd = m.nodes[i];
        if (nd.display.len > 0 and std.mem.eql(u8, nd.display, display)) return true;
        if (name.len > 0 and i > 0 and std.mem.eql(u8, nd.label, name)) return true;
    }
    return false;
}

/// The connected lattice (client first) as `Screen` entries, for persistence.
fn saveScreens(arena: std.mem.Allocator, m: *const Model) []const Screen {
    var list: std.ArrayList(Screen) = .empty;
    for (0..m.n) |i| {
        if (!m.nodes[i].screen.snapped) continue; // only screens joined to the client
        const nd = m.nodes[i];
        list.append(arena, .{
            .name = nd.label,
            .addr = if (i == 0) null else nd.display,
            .x = nd.screen.x,
            .y = nd.screen.y,
            .w = nd.screen.w,
            .h = nd.screen.h,
        }) catch break;
    }
    return list.toOwnedSlice(arena) catch &.{};
}

const Side = enum { left, right, top, bottom };

fn matchExistingSide(a: Arrangement, display: []const u8) ?Side {
    if (a.left) |v| if (std.mem.eql(u8, v, display)) return .left;
    if (a.right) |v| if (std.mem.eql(u8, v, display)) return .right;
    if (a.top) |v| if (std.mem.eql(u8, v, display)) return .top;
    if (a.bottom) |v| if (std.mem.eql(u8, v, display)) return .bottom;
    return null;
}

/// Pick the first client edge not yet occupied by a snapped neighbour.
fn freeSide(m: *Model) ?Side {
    const order = [_]Side{ .right, .left, .top, .bottom };
    for (order) |side| {
        var taken = false;
        for (1..m.n) |i| {
            if (!m.nodes[i].screen.snapped) continue;
            if (sideOf(m.nodes[0].screen, m.nodes[i].screen) == side) {
                taken = true;
                break;
            }
        }
        if (!taken) return side;
    }
    return null; // all sides used: leave floating
}

fn sidePlacement(side: ?Side, cw: i32, ch: i32, sw: i32, sh: i32) struct { x: i32, y: i32 } {
    return switch (side orelse .right) {
        .right => .{ .x = cw, .y = 0 },
        .left => .{ .x = -sw, .y = 0 },
        .top => .{ .x = 0, .y = -sh },
        .bottom => .{ .x = 0, .y = ch },
    };
}

fn rangesOverlap(a0: i32, alen: i32, b0: i32, blen: i32) bool {
    return a0 < b0 + blen and b0 < a0 + alen;
}

/// Which side of `client` is `s` directly adjacent to (edges touching), if any.
fn sideOf(client: canvas.Screen, s: canvas.Screen) ?Side {
    if (s.x == client.x + client.w and rangesOverlap(client.y, client.h, s.y, s.h)) return .right;
    if (s.x + s.w == client.x and rangesOverlap(client.y, client.h, s.y, s.h)) return .left;
    if (s.y == client.y + client.h and rangesOverlap(client.x, client.w, s.x, s.w)) return .bottom;
    if (s.y + s.h == client.y and rangesOverlap(client.x, client.w, s.x, s.w)) return .top;
    return null;
}

/// Derive the edge assignments from the arrangement: each neighbour directly
/// touching the client claims that side (first one wins per side).
fn deriveEdges(m: *const Model) Arrangement {
    var a = Arrangement{
        .screen_width = m.nodes[0].screen.w,
        .screen_height = m.nodes[0].screen.h,
    };
    for (1..m.n) |i| {
        const nd = m.nodes[i];
        if (!nd.screen.snapped) continue;
        const side = sideOf(m.nodes[0].screen, nd.screen) orelse continue;
        switch (side) {
            .left => if (a.left == null) {
                a.left = nd.display;
            },
            .right => if (a.right == null) {
                a.right = nd.display;
            },
            .top => if (a.top == null) {
                a.top = nd.display;
            },
            .bottom => if (a.bottom == null) {
                a.bottom = nd.display;
            },
        }
    }
    return a;
}

// --------------------------------------------------------------------------
// Viewport: virtual-desktop pixels <-> canvas well pixels (fit + centre).
// --------------------------------------------------------------------------

const Viewport = struct {
    scale: f32,
    off_x: f32,
    off_y: f32,

    fn compute(m: *Model, well: Rect) Viewport {
        // Anchor on the client (node 0): it stays at the centre of the well and
        // the other screens are arranged around it. Scale to fit the screen
        // farthest from the client centre in each direction.
        const c = m.nodes[0].screen;
        const cx: f32 = @floatFromInt(c.x + @divTrunc(c.w, 2));
        const cy: f32 = @floatFromInt(c.y + @divTrunc(c.h, 2));

        var half_x: f32 = 1;
        var half_y: f32 = 1;
        for (0..m.n) |i| {
            const s = m.nodes[i].screen;
            half_x = @max(half_x, @max(cx - @as(f32, @floatFromInt(s.x)), @as(f32, @floatFromInt(s.x + s.w)) - cx));
            half_y = @max(half_y, @max(cy - @as(f32, @floatFromInt(s.y)), @as(f32, @floatFromInt(s.y + s.h)) - cy));
        }
        // Headroom so screens (and their monitor furniture — bezel above, base
        // below) don't hug the well border and there's room to drag.
        half_x *= 1.35;
        half_y *= 1.7;

        const pad: f32 = 20;
        const avail_hx = (@as(f32, @floatFromInt(well.w)) - 2 * pad) / 2;
        const avail_hy = (@as(f32, @floatFromInt(well.h)) - 2 * pad) / 2;
        var scale = @min(avail_hx / half_x, avail_hy / half_y);
        if (scale > 1.0) scale = 1.0; // never magnify beyond 1:1

        const off_x = @as(f32, @floatFromInt(well.x)) + @as(f32, @floatFromInt(well.w)) / 2 - cx * scale;
        const off_y = @as(f32, @floatFromInt(well.y)) + @as(f32, @floatFromInt(well.h)) / 2 - cy * scale;
        return .{ .scale = scale, .off_x = off_x, .off_y = off_y };
    }

    fn rect(self: Viewport, s: canvas.Screen) Rect {
        const x: f32 = @as(f32, @floatFromInt(s.x)) * self.scale + self.off_x;
        const y: f32 = @as(f32, @floatFromInt(s.y)) * self.scale + self.off_y;
        return .{
            .x = @intFromFloat(x),
            .y = @intFromFloat(y),
            .w = @max(@as(i32, @intFromFloat(@as(f32, @floatFromInt(s.w)) * self.scale)), 8),
            .h = @max(@as(i32, @intFromFloat(@as(f32, @floatFromInt(s.h)) * self.scale)), 8),
        };
    }

    /// Convert a canvas-pixel delta back into world pixels.
    fn toWorld(self: Viewport, d: i32) i32 {
        if (self.scale == 0) return d;
        return @intFromFloat(@as(f32, @floatFromInt(d)) / self.scale);
    }
};

// --------------------------------------------------------------------------
// Rendering
// --------------------------------------------------------------------------

fn render(f: *fb.Framebuffer, m: *Model, vp: Viewport, pressed_btn: ?usize, pressed_close: bool) void {
    f.clear(fb.face);
    classic.bevel(f, 0, 0, f.w, f.h, false);
    classic.captionBar(f, caption_rect.x, caption_rect.y, caption_rect.w, caption_rect.h);
    font.draw(f, 8, 8, "telemouse - configure screens", fb.cap_text);

    // Caption close button with a small black X, classic Win2k style.
    classic.button(f, close_rect.x, close_rect.y, close_rect.w, close_rect.h, "", pressed_close, false);
    drawCloseGlyph(f, close_rect, pressed_close);

    classic.well(f, well_rect.x, well_rect.y, well_rect.w, well_rect.h, fb.rgb(88, 88, 88));

    for (0..m.n) |i| {
        const nd = m.nodes[i];
        const r = vp.rect(nd.screen);
        canvas.drawScreenCell(f, r.x, r.y, r.w, r.h, nd.label, nd.screen.state, i == m.selected);
    }

    // Status bar (sunken strip above the buttons).
    classic.well(f, status_rect.x, status_rect.y, status_rect.w, status_rect.h, fb.face);
    font.draw(f, status_rect.x + 4, status_rect.y + 3, m.status, fb.black);

    for (buttons, 0..) |b, i| {
        classic.button(f, b.rect.x, b.rect.y, b.rect.w, b.rect.h, b.label, pressed_btn == i, b.default);
    }
}

/// Draw the caption close button's "X" using the real embedded Marlett close
/// glyph, centred in `r`.
fn drawCloseGlyph(f: *fb.Framebuffer, r: Rect, pressed: bool) void {
    const off: i32 = if (pressed) 1 else 0;
    const size: i32 = r.h - 3;
    const ox = r.x + @divTrunc(r.w - size, 2) + off;
    const oy = r.y + @divTrunc(r.h - size, 2) + off;
    marlett.draw(f, marlett.close, ox, oy, size, fb.black);
}

// --------------------------------------------------------------------------
// Entry point
// --------------------------------------------------------------------------

pub fn run(
    io: Io,
    arena: std.mem.Allocator,
    logger: *log.Logger,
    initial: Arrangement,
) Outcome {
    const servers = mdns.discover(io, arena, logger, 700) catch &[_]mdns.Server{};
    logger.info("configuration UI: {d} server(s) discovered", .{servers.len});

    var model = buildModel(arena, initial.screen_width, initial.screen_height, initial, servers);

    var win = window.Window.open(win_w, win_h, "telemouse") catch |e| switch (e) {
        error.NoDisplay => return .no_display,
    };
    defer win.close();

    var f = fb.Framebuffer.init(arena, win_w, win_h) catch return .cancelled;
    defer f.deinit(arena);

    // The viewport (zoom + pan) is computed once to fit the whole arrangement
    // and then held fixed, so dragging a screen never changes the zoom. It is
    // only recomputed when the set of screens changes (Rescan).
    var vp = Viewport.compute(&model, well_rect);

    // Drag state. To keep snapping stable we track the pointer's true world
    // position separately from the snapped screen position, so snapping never
    // accumulates drift.
    var dragging: ?usize = null;
    var grab_mouse_x: i32 = 0; // pointer position (screen px) when the drag began
    var grab_mouse_y: i32 = 0;
    var grab_node_x: i32 = 0; // node position (world px) when the drag began
    var grab_node_y: i32 = 0;
    var pressed_btn: ?usize = null;
    var pressed_close = false;

    // Window-move state: the borderless window is dragged by its own caption bar.
    var moving_win = false;
    var win_last_root_x: i32 = 0;
    var win_last_root_y: i32 = 0;

    // Snap threshold in screen pixels; converted to world px via the viewport so
    // it feels the same on screen regardless of zoom.
    const snap_screen_px = 14;

    render(&f, &model, vp, null, false);
    win.present(&f);

    while (true) {
        const ev = win.nextEvent();
        switch (ev) {
            .close => return .cancelled,
            .expose => {},
            .mouse_down => |mo| {
                if (close_rect.contains(mo.x, mo.y)) {
                    pressed_close = true;
                } else if (hitButton(mo.x, mo.y)) |bi| {
                    pressed_btn = bi;
                } else if (hitScreen(&model, vp, mo.x, mo.y)) |i| {
                    model.selected = i;
                    dragging = i;
                    grab_mouse_x = mo.x;
                    grab_mouse_y = mo.y;
                    grab_node_x = model.nodes[i].screen.x;
                    grab_node_y = model.nodes[i].screen.y;
                } else if (caption_rect.contains(mo.x, mo.y)) {
                    // Grab the caption to move the whole window.
                    moving_win = true;
                    win_last_root_x = mo.x_root;
                    win_last_root_y = mo.y_root;
                }
            },
            .mouse_move => |mo| {
                if (dragging) |i| {
                    // True (unsnapped) position follows the pointer exactly.
                    const true_x = grab_node_x + vp.toWorld(mo.x - grab_mouse_x);
                    const true_y = grab_node_y + vp.toWorld(mo.y - grab_mouse_y);
                    // Snap live against every other screen (edges align as you
                    // drag near them), keeping the true position for next time.
                    var others: [max_screens]canvas.Screen = undefined;
                    var k: usize = 0;
                    for (0..model.n) |j| {
                        if (j == i) continue;
                        others[k] = model.nodes[j].screen;
                        k += 1;
                    }
                    var moving = model.nodes[i].screen;
                    moving.x = true_x;
                    moving.y = true_y;
                    const snapped = canvas.snapTo(moving, others[0..k], vp.toWorld(snap_screen_px));
                    model.nodes[i].screen.x = snapped.x;
                    model.nodes[i].screen.y = snapped.y;
                    model.recompute(); // live wall/connectivity feedback
                    model.status = if (snapped.snapped) "snapped - release to connect" else "drag to a client edge to connect";
                } else if (moving_win) {
                    win.moveBy(mo.x_root - win_last_root_x, mo.y_root - win_last_root_y);
                    win_last_root_x = mo.x_root;
                    win_last_root_y = mo.y_root;
                }
            },
            .mouse_up => |mo| {
                if (dragging) |_| {
                    model.recompute();
                    dragging = null;
                }
                moving_win = false;
                if (pressed_close) {
                    pressed_close = false;
                    if (close_rect.contains(mo.x, mo.y)) return .cancelled;
                }
                if (pressed_btn) |bi| {
                    defer pressed_btn = null;
                    if (buttons[bi].rect.contains(mo.x, mo.y)) {
                        switch (bi) {
                            btn_ok => return .{ .saved = saveScreens(arena, &model) },
                            btn_cancel => return .cancelled,
                            btn_rescan => {
                                // Re-discover, keeping the current arrangement
                                // (positions preserved, liveness refreshed).
                                const again = mdns.discover(io, arena, logger, 700) catch &[_]mdns.Server{};
                                const cur = Arrangement{
                                    .screen_width = model.nodes[0].screen.w,
                                    .screen_height = model.nodes[0].screen.h,
                                    .screens = saveScreens(arena, &model),
                                };
                                model = buildModel(arena, cur.screen_width, cur.screen_height, cur, again);
                                vp = Viewport.compute(&model, well_rect); // refit for the new set
                                model.status = "rescan complete";
                            },
                            btn_identify => {
                                if (identifyTarget(&model)) |ti| {
                                    // Highlight and wiggle that server's pointer
                                    // (blocks briefly during the shake).
                                    model.selected = ti;
                                    model.status = "identifying - watch the selected screen";
                                    render(&f, &model, vp, null, false);
                                    win.present(&f);
                                    identify(io, logger, model.nodes[ti].label, model.nodes[ti].display);
                                    model.status = "pointer wiggled on the selected screen";
                                } else {
                                    model.status = "no server to identify";
                                }
                            },
                            else => {},
                        }
                    }
                }
            },
            .key => |k| {
                if (k.code == key_escape) return .cancelled; // Esc = Cancel
            },
            .none => {},
        }
        render(&f, &model, vp, pressed_btn, pressed_close);
        win.present(&f);
    }
}

fn hitButton(px: i32, py: i32) ?usize {
    for (buttons, 0..) |b, i| {
        if (b.rect.contains(px, py)) return i;
    }
    return null;
}

fn parseAddr(text: []const u8) ?net.IpAddress {
    const colon = std.mem.lastIndexOfScalar(u8, text, ':') orelse return null;
    const port = std.fmt.parseInt(u16, text[colon + 1 ..], 10) catch return null;
    return net.IpAddress.parse(text[0..colon], port) catch null;
}

/// The screen to identify: the selected server, else the first server in the
/// lattice (so a single click works when there is only one).
fn identifyTarget(m: *const Model) ?usize {
    if (m.selected > 0 and m.nodes[m.selected].display.len > 0) return m.selected;
    for (1..m.n) |i| {
        if (m.nodes[i].display.len > 0) return i;
    }
    return null;
}

/// Wiggle the pointer of the server at `display` so the user can tell which
/// physical machine the selected screen is. Sends a short horizontal shake of
/// relative moves (UDP), which the server applies wherever its cursor is. Note:
/// a server started with `--dry-run` logs but does not move its real pointer.
fn identify(io: Io, logger: *log.Logger, name: []const u8, display: []const u8) void {
    const dest = parseAddr(display) orelse {
        logger.warn("cannot identify '{s}': '{s}' is not an ip:port", .{ name, display });
        return;
    };
    var any = net.IpAddress.parse("0.0.0.0", 0) catch return;
    const sock = any.bind(io, .{ .mode = .dgram }) catch |e| {
        logger.warn("identify: cannot open socket: {s}", .{@errorName(e)});
        return;
    };
    defer sock.close(io);
    logger.info("identifying '{s}' at {s}: wiggling its pointer", .{ name, display });
    var server = dest;
    const step: i32 = 60;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const dx: i32 = if (i % 2 == 0) step else -step;
        var buf: [32]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "move {d} 0", .{dx}) catch return;
        sock.send(io, &server, line) catch {};
        io.sleep(Io.Duration.fromMilliseconds(55), .awake) catch {};
    }
}

/// Topmost (last-drawn) screen under the point, skipping the client (index 0).
fn hitScreen(m: *Model, vp: Viewport, px: i32, py: i32) ?usize {
    var i: usize = m.n;
    while (i > 1) {
        i -= 1;
        if (vp.rect(m.nodes[i].screen).contains(px, py)) return i;
    }
    return null;
}

// --------------------------------------------------------------------------
// Tests (pure logic — the window loop is not exercised here)
// --------------------------------------------------------------------------

test "render the full dialog to a BMP for visual inspection" {
    if (@import("builtin").os.tag != .linux) return;
    const gpa = std.testing.allocator;
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // A realistic arrangement: client centre, an online neighbour snapped to the
    // right, another below, a laptop offline snapped left, and a floating one.
    var m = Model{};
    m.nodes[0] = .{ .screen = .{ .x = 0, .y = 0, .w = 1920, .h = 1080, .state = .client, .snapped = true }, .label = "this pc", .display = "" };
    m.nodes[1] = .{ .screen = .{ .x = 1920, .y = 0, .w = 1920, .h = 1080, .state = .online, .snapped = true }, .label = "htpc", .display = "10.0.0.2:24800" };
    m.nodes[2] = .{ .screen = .{ .x = 0, .y = 1080, .w = 2560, .h = 1440, .state = .online, .snapped = true }, .label = "studio", .display = "10.0.0.3:24800" };
    m.nodes[3] = .{ .screen = .{ .x = -1366, .y = 0, .w = 1366, .h = 768, .state = .offline, .snapped = true }, .label = "laptop", .display = "10.0.0.4:24800" };
    m.nodes[4] = .{ .screen = .{ .x = 4200, .y = 1600, .w = 1280, .h = 1024, .state = .orphaned, .snapped = false }, .label = "nas", .display = "10.0.0.9:24800" };
    m.n = 5;
    m.selected = 1;
    m.status = "snapped - release to connect";

    var f = try fb.Framebuffer.init(arena, win_w, win_h);
    const vp = Viewport.compute(&m, well_rect);
    render(&f, &m, vp, null, false);

    const bmp = try f.encodeBmp(arena);
    writeFileRaw("/tmp/claude-1000/-home-jd-telemouse/a0e08181-344f-4af8-b6cd-7b02c7f04189/scratchpad/ui_configui.bmp", bmp);
    try std.testing.expect(true);
}

fn writeFileRaw(path: [*:0]const u8, bytes: []const u8) void {
    if (@import("builtin").os.tag != .linux) return;
    const linux = std.os.linux;
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
    const rc = linux.open(path, flags, 0o644);
    if (linux.errno(rc) != .SUCCESS) return;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var off: usize = 0;
    while (off < bytes.len) {
        const n = linux.write(fd, bytes.ptr + off, bytes.len - off);
        if (linux.errno(n) != .SUCCESS) return;
        off += n;
    }
}

test "a saved lattice is restored (normalised + liveness-marked) and re-saved" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Saved lattice with the client at a non-zero origin (100,100): htpc to the
    // right, nas below.
    const saved = [_]Screen{
        .{ .name = "this pc", .addr = null, .x = 100, .y = 100, .w = 1920, .h = 1080 },
        .{ .name = "htpc", .addr = "10.0.0.2:24800", .x = 2020, .y = 100, .w = 1920, .h = 1080 },
        .{ .name = "nas", .addr = "10.0.0.9:24800", .x = 100, .y = 1180, .w = 1280, .h = 1024 },
    };
    // Discovery only sees htpc now; nas is offline.
    const servers = [_]mdns.Server{
        .{ .display = "10.0.0.2:24800", .name = "htpc", .width = 1920, .height = 1080 },
    };
    const initial = Arrangement{ .screen_width = 1920, .screen_height = 1080, .screens = &saved };
    var m = buildModel(arena, 1920, 1080, initial, &servers);

    try std.testing.expectEqual(@as(usize, 3), m.n);
    // Client normalised to the origin.
    try std.testing.expectEqual(@as(i32, 0), m.nodes[0].screen.x);
    try std.testing.expectEqual(@as(i32, 0), m.nodes[0].screen.y);
    // htpc restored at its translated position and marked online.
    try std.testing.expectEqual(@as(i32, 1920), m.nodes[1].screen.x); // 2020 - 100
    try std.testing.expectEqual(canvas.State.online, m.nodes[1].screen.state);
    // nas restored and marked offline (discovery didn't see it), but still part
    // of the lattice (touches the client).
    try std.testing.expectEqual(canvas.State.offline, m.nodes[2].screen.state);
    try std.testing.expect(m.nodes[2].screen.snapped);

    // Re-save: client first (addr null), both servers kept with their addrs.
    const out = saveScreens(arena, &m);
    try std.testing.expectEqual(@as(usize, 3), out.len);
    try std.testing.expect(out[0].addr == null);
    try std.testing.expectEqualStrings("10.0.0.2:24800", out[1].addr.?);
    try std.testing.expectEqual(@as(i32, 1920), out[1].x);
}

test "a server that changed IP is matched by name and its address refreshed" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const saved = [_]Screen{
        .{ .name = "this pc", .addr = null, .x = 0, .y = 0, .w = 1920, .h = 1080 },
        .{ .name = "htpc", .addr = "10.0.0.2:24800", .x = 1920, .y = 0, .w = 1920, .h = 1080 },
    };
    // The same machine ("htpc") is back on a new IP after a DHCP lease change.
    const servers = [_]mdns.Server{
        .{ .display = "10.0.0.55:24800", .name = "htpc", .width = 1920, .height = 1080 },
    };
    const initial = Arrangement{ .screen_width = 1920, .screen_height = 1080, .screens = &saved };
    var m = buildModel(arena, 1920, 1080, initial, &servers);

    try std.testing.expectEqual(@as(usize, 2), m.n); // matched, not added again as floating
    try std.testing.expectEqual(canvas.State.online, m.nodes[1].screen.state);

    // Re-saving records the refreshed address.
    const out = saveScreens(arena, &m);
    try std.testing.expectEqualStrings("10.0.0.55:24800", out[1].addr.?);
}

test "buildModel places discovered servers around the client" {
    const servers = [_]mdns.Server{
        .{ .display = "10.0.0.2:24800", .name = "htpc", .width = 1920, .height = 1080 },
        .{ .display = "10.0.0.3:24800", .name = "laptop", .width = 1366, .height = 768 },
    };
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const m = buildModel(arena, 1920, 1080, .{ .screen_width = 1920, .screen_height = 1080 }, &servers);
    try std.testing.expectEqual(@as(usize, 3), m.n);
    try std.testing.expectEqual(canvas.State.client, m.nodes[0].screen.state);
    // First server takes the right edge, second the left (freeSide order).
    try std.testing.expectEqual(@as(i32, 1920), m.nodes[1].screen.x); // right of client
    try std.testing.expectEqual(@as(i32, -1366), m.nodes[2].screen.x); // left of client
}

test "deriveEdges reads the arrangement back into edge assignments" {
    const servers = [_]mdns.Server{
        .{ .display = "10.0.0.2:24800", .name = "htpc", .width = 1920, .height = 1080 },
    };
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const m = buildModel(arena, 1920, 1080, .{ .screen_width = 1920, .screen_height = 1080 }, &servers);
    const a = deriveEdges(&m);
    try std.testing.expectEqual(@as(i32, 1920), a.screen_width);
    try std.testing.expect(a.right != null);
    try std.testing.expectEqualStrings("10.0.0.2:24800", a.right.?);
    try std.testing.expect(a.left == null);
}

test "an existing edge is honoured when rebuilding the model" {
    const servers = [_]mdns.Server{
        .{ .display = "10.0.0.9:24800", .name = "nas", .width = 1280, .height = 1024 },
    };
    const existing = Arrangement{ .screen_width = 1920, .screen_height = 1080, .top = "10.0.0.9:24800" };
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const m = buildModel(arena, 1920, 1080, existing, &servers);
    const side = sideOf(m.nodes[0].screen, m.nodes[1].screen);
    try std.testing.expectEqual(Side.top, side.?);
}

test "snapping uses a screen-space threshold, so it engages at fit-all zoom" {
    // Two 1080p screens span 3840px; at the well's fit-all zoom the scale is
    // tiny, so a fixed 24-world-px snap threshold would be sub-pixel on screen
    // (the reported bug). Converting a screen-space threshold through the
    // viewport keeps snapping usable.
    var m = Model{};
    m.nodes[0] = .{ .screen = .{ .x = 0, .y = 0, .w = 1920, .h = 1080, .state = .client, .snapped = true }, .label = "this pc", .display = "" };
    m.nodes[1] = .{ .screen = .{ .x = 3000, .y = 400, .w = 1920, .h = 1080, .state = .online, .snapped = false }, .label = "htpc", .display = "10.0.0.2:24800" };
    m.n = 2;

    const vp = Viewport.compute(&m, well_rect);
    const thr = vp.toWorld(14);
    try std.testing.expect(thr > 30); // many world px at this zoom, not sub-pixel

    // Neighbour brought near the client's right edge, within the threshold.
    var moving = m.nodes[1].screen;
    moving.x = 1920 + @divTrunc(thr, 2);
    moving.y = 40;
    const snapped = canvas.snapTo(moving, &.{m.nodes[0].screen}, thr);
    try std.testing.expect(snapped.snapped);
    try std.testing.expectEqual(@as(i32, 1920), snapped.x); // aligned to the client's right edge
    try std.testing.expectEqual(@as(i32, 40), snapped.y); // perpendicular offset preserved
}

test "dragging a snapped neighbour off the client makes it a wall (orphaned)" {
    const servers = [_]mdns.Server{
        .{ .display = "10.0.0.2:24800", .name = "htpc", .width = 100, .height = 100 },
    };
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var m = buildModel(arena, 100, 100, .{ .screen_width = 100, .screen_height = 100 }, &servers);
    // Move it far away and recompute connectivity.
    m.nodes[1].screen.x = 5000;
    m.recompute();
    try std.testing.expect(!m.nodes[1].screen.snapped);
    try std.testing.expectEqual(canvas.State.orphaned, m.nodes[1].screen.state);
    const a = deriveEdges(&m);
    try std.testing.expect(a.right == null); // no longer touching -> not an edge
}
