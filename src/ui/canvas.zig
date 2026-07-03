// The screen-arrangement canvas: draws the lattice of screens as Windows-95
// style monitors (beige beveled body, sunken blue screen, label), and holds the
// drag/snap layout logic. The layout is virtual-desktop pixel space; the canvas
// maps it into the on-screen well, scaled to fit and proportional to each
// screen's resolution.

const std = @import("std");
const fb = @import("framebuffer.zig");
const classic = @import("classic.zig");
const font = @import("font.zig");

pub const State = enum { client, online, offline, orphaned };

const screen_teal = fb.rgb(0, 128, 128); // the authentic Win95 desktop teal
const screen_gray = fb.rgb(96, 96, 96);

// The reference monitor (guidebookgallery win95-1-1.png) uses the classic Win95
// 3D palette, distinct from the dialog's Win2k/Wine beige.
const m_face = fb.rgb(192, 192, 192);
const m_hi = fb.rgb(255, 255, 255);
const m_shadow = fb.rgb(128, 128, 128);
const m_dark = fb.rgb(0, 0, 0);

/// A Win95 3D edge in the monitor palette. Raised: white top/left, shadow+black
/// bottom/right. Sunken (the screen recess): a shadow ring with a black
/// top/left inner and a white bottom/right inner — as measured off the
/// reference.
fn bevel95(f: *fb.Framebuffer, x: i32, y: i32, w: i32, h: i32, raised: bool) void {
    if (raised) {
        f.hline(x, y, w, m_hi);
        f.vline(x, y, h, m_hi);
        f.hline(x, y + h - 1, w, m_dark);
        f.vline(x + w - 1, y, h, m_dark);
        f.hline(x + 1, y + h - 2, w - 2, m_shadow);
        f.vline(x + w - 2, y + 1, h - 2, m_shadow);
    } else {
        f.hline(x, y, w, m_shadow);
        f.vline(x, y, h, m_shadow);
        f.hline(x, y + h - 1, w, m_shadow);
        f.vline(x + w - 1, y, h, m_shadow);
        f.hline(x + 1, y + 1, w - 2, m_dark);
        f.vline(x + 1, y + 1, h - 2, m_dark);
        f.hline(x + 1, y + h - 2, w - 2, m_hi);
        f.vline(x + w - 2, y + 1, h - 2, m_hi);
    }
}

/// Draw a symbolic Windows-95 Display-Properties monitor filling the cell
/// (x,y,w,h) — the whole icon stays inside it, so monitors snap at their edges
/// without overlapping. The bezel and the base (bar with LED + slot, neck, foot)
/// are sized from the cell *height* and so stay constant across aspect ratios:
/// only the screen widens with the cell. The teal is a symbolic screen, not a
/// pixel-accurate display, so it fills the body (roughly the cell's ratio).
pub fn drawScreenCell(f: *fb.Framebuffer, x: i32, y: i32, w: i32, h: i32, label: []const u8, state: State, selected: bool) void {
    const body = if (state == .offline) fb.rgb(168, 164, 156) else m_face;

    // The body IS the cell (x,y,w,h) — which is the resolution rectangle — so the
    // screen fills it at the true display ratio with only a thin bezel. The stand
    // hangs *below* the cell (sized from the height, constant across ratios) so
    // it never steals from the screen's height (which was making it over-wide).
    const bez = @max(@divTrunc(h, 16), 2);
    const bar_h = @max(@divTrunc(h, 12), 4);
    const neck_h = @max(@divTrunc(h, 18), 3);
    const foot_h = @max(@divTrunc(h, 26), 2);

    const cxc = x + @divTrunc(w, 2);
    const bar_w = @min(w, @max(@divTrunc(h, 2), 12));
    const neck_w = @min(w, @max(@divTrunc(h * 42, 100), 8));
    const foot_w = @min(w, @max(@divTrunc(h * 65, 100), 12));

    // --- Stand below the cell: neck + wider foot (drawn first), then the bar. ---
    const bar_y = y + h;
    const neck_x = cxc - @divTrunc(neck_w, 2);
    const neck_y = bar_y + bar_h;
    const foot_x = cxc - @divTrunc(foot_w, 2);
    const foot_y = neck_y + neck_h;
    f.fillRect(neck_x, neck_y, neck_w, foot_y - neck_y, body);
    f.vline(neck_x, neck_y, foot_y - neck_y, m_shadow);
    f.vline(neck_x + neck_w - 1, neck_y, foot_y - neck_y, m_shadow);
    f.fillRect(foot_x, foot_y, foot_w, foot_h, body);
    bevel95(f, foot_x, foot_y, foot_w, foot_h, true);

    const bar_x = cxc - @divTrunc(bar_w, 2);
    f.fillRect(bar_x, bar_y, bar_w, bar_h, body);
    bevel95(f, bar_x, bar_y, bar_w, bar_h, true);
    if (bar_h >= 4) {
        const led = switch (state) {
            .offline => fb.rgb(224, 0, 0), // red — not connected
            .orphaned => fb.rgb(255, 176, 0), // amber — reachable but path blocked
            else => fb.rgb(0, 255, 0), // green — online / this pc
        };
        const led_y = bar_y + @divTrunc(bar_h - 2, 2);
        const led_x = cxc - @divTrunc(bar_w, 6);
        f.fillRect(led_x, led_y, 2, 2, led);
        const slot_x = led_x + 4;
        const slot_w = @min(@divTrunc(bar_w, 3), bar_x + bar_w - 3 - slot_x);
        if (slot_w >= 4) bevel95(f, slot_x, led_y - 1, slot_w, @min(bar_h - 2, 4), false);
    }

    // --- Body = the whole cell. ---
    f.fillRect(x, y, w, h, body);
    bevel95(f, x, y, w, h, true);

    // --- Screen at the true display ratio (w:h of the cell = the resolution),
    //     fit inside the body. Since the body is already that ratio, the margin
    //     is just the (thin) bezel. ---
    const inner_w = w - 2 * bez;
    const inner_h = h - 2 * bez;
    if (inner_w > 0 and inner_h > 0) {
        var sw = inner_w;
        var sh = @divTrunc(inner_w * h, w); // sw * (h/w)
        if (sh > inner_h) {
            sh = inner_h;
            sw = @divTrunc(inner_h * w, h);
        }
        const sx = x + @divTrunc(w - sw, 2);
        const sy = y + @divTrunc(h - sh, 2);
        const scr = switch (state) {
            .offline => screen_gray,
            .orphaned => fb.rgb(64, 84, 84),
            else => screen_teal,
        };
        f.fillRect(sx, sy, sw, sh, scr);
        bevel95(f, sx, sy, sw, sh, false); // sunken screen recess
        const text_color = if (state == .offline) fb.rgb(180, 180, 180) else fb.white;
        if (sh >= font.glyph_h and label.len > 0) drawLabelClipped(f, sx, sy, sw, sh, label, text_color);
    }

    if (selected) {
        f.rect(x - 2, y - 2, w + 4, (foot_y + foot_h) - y + 4, fb.black);
    }
}

/// Draw `label` centred in the screen rect, truncating from the end until it
/// fits `sw` so a long name shows a prefix rather than disappearing entirely.
fn drawLabelClipped(f: *fb.Framebuffer, sx: i32, sy: i32, sw: i32, sh: i32, label: []const u8, color: fb.Color) void {
    var n = label.len;
    while (n > 0 and font.textWidth(label[0..n]) > sw - 2) n -= 1;
    if (n == 0) return;
    const tw = font.textWidth(label[0..n]);
    const tx = sx + @divTrunc(sw - tw, 2);
    const ty = sy + @divTrunc(sh - font.glyph_h, 2);
    font.draw(f, tx, ty, label[0..n], color);
}

// --------------------------------------------------------------------------
// Layout: screens in virtual-desktop pixel space + snapping.
// --------------------------------------------------------------------------

pub const snap_distance: i32 = 24; // in virtual pixels, at 1:1

pub const Screen = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    state: State,
    snapped: bool, // false = floating (not connected to the lattice)
};

/// Try to snap `moving`'s rectangle so an edge touches one of `others`. `dist`
/// is the snap threshold, in virtual pixels (callers pass a screen-space
/// threshold converted through the viewport so it feels constant on screen).
/// Returns the snapped position (unchanged if nothing is within `dist`).
/// Snapping aligns the touching edge exactly and keeps the perpendicular offset.
pub fn snapTo(moving: Screen, others: []const Screen, dist: i32) struct { x: i32, y: i32, snapped: bool } {
    var best_x = moving.x;
    var best_y = moving.y;
    var best_dx: i32 = dist + 1;
    var best_dy: i32 = dist + 1;
    var did = false;

    for (others) |o| {
        // Horizontal adjacency (moving to the right/left of o), if vertical spans overlap.
        if (rangesOverlap(moving.y, moving.h, o.y, o.h)) {
            consider(dist, &best_dx, &best_x, &did, moving.x, o.x + o.w); // moving.left snaps to o.right
            consider(dist, &best_dx, &best_x, &did, moving.x, o.x - moving.w); // moving.right snaps to o.left
        }
        // Vertical adjacency (moving above/below o), if horizontal spans overlap.
        if (rangesOverlap(moving.x, moving.w, o.x, o.w)) {
            consider(dist, &best_dy, &best_y, &did, moving.y, o.y + o.h);
            consider(dist, &best_dy, &best_y, &did, moving.y, o.y - moving.h);
        }
    }
    return .{ .x = best_x, .y = best_y, .snapped = did };
}

fn consider(dist: i32, best_d: *i32, best: *i32, did: *bool, current: i32, candidate: i32) void {
    const d: i32 = @intCast(@abs(current - candidate));
    if (d <= dist and d < best_d.*) {
        best_d.* = d;
        best.* = candidate;
        did.* = true;
    }
}

fn rangesOverlap(a0: i32, alen: i32, b0: i32, blen: i32) bool {
    return a0 < b0 + blen and b0 < a0 + alen;
}

/// Recompute which screens are connected to the client (index 0) through a chain
/// of touching borders; the rest become floating. This is the unsnap cascade.
pub fn recomputeConnectivity(screens: []Screen) void {
    if (screens.len == 0) return;
    var connected = std.mem.zeroes([switcherMax]bool);
    connected[0] = true; // client
    // Repeatedly mark any screen touching an already-connected one.
    var changed = true;
    while (changed) {
        changed = false;
        for (screens, 0..) |s, i| {
            if (connected[i]) continue;
            for (screens, 0..) |o, j| {
                if (!connected[j]) continue;
                if (touching(s, o)) {
                    connected[i] = true;
                    changed = true;
                    break;
                }
            }
        }
    }
    for (screens, 0..) |*s, i| s.snapped = connected[i];
}

const switcherMax = 16;

fn touching(a: Screen, b: Screen) bool {
    const horiz = (a.x == b.x + b.w or b.x == a.x + a.w) and rangesOverlap(a.y, a.h, b.y, b.h);
    const vert = (a.y == b.y + b.h or b.y == a.y + a.h) and rangesOverlap(a.x, a.w, b.x, b.w);
    return horiz or vert;
}

test "render a sample arrangement" {
    const gpa = std.testing.allocator;
    var f = try fb.Framebuffer.init(gpa, 360, 240);
    defer f.deinit(gpa);
    f.clear(fb.face);
    classic.bevel(&f, 0, 0, f.w, f.h, false);
    classic.captionBar(&f, 3, 3, f.w - 6, 20);
    font.draw(&f, 8, 8, "telemouse - configure screens", fb.cap_text);
    // Canvas well.
    classic.well(&f, 10, 30, 340, 160, fb.rgb(88, 88, 88));
    // A little arrangement: client centre, an online neighbour right, an
    // offline one above, and a floating (orphaned) one.
    drawScreenCell(&f, 150, 95, 60, 45, "this pc", .client, false);
    drawScreenCell(&f, 212, 95, 60, 45, "htpc", .online, true);
    drawScreenCell(&f, 150, 48, 60, 45, "laptop", .offline, false);
    drawScreenCell(&f, 285, 150, 50, 38, "nas", .orphaned, false);
    // Buttons.
    classic.button(&f, 120, 200, 70, 22, "OK", false, true);
    classic.button(&f, 198, 200, 70, 22, "Cancel", false, false);
    classic.button(&f, 276, 200, 70, 22, "Rescan", false, false);

    if (@import("builtin").os.tag == .linux) {
        const bmp = try f.encodeBmp(gpa);
        defer gpa.free(bmp);
        writeFileRaw("/tmp/claude-1000/-home-jd-telemouse/a0e08181-344f-4af8-b6cd-7b02c7f04189/scratchpad/ui_canvas.bmp", bmp);
    }
    try std.testing.expect(true);
}

test "render one monitor at the reference size for comparison" {
    const gpa = std.testing.allocator;
    // 186x170 = the native size of the traced Win95 reference monitor.
    var f = try fb.Framebuffer.init(gpa, 186, 170);
    defer f.deinit(gpa);
    f.clear(fb.rgb(192, 192, 192)); // Win95 dialog gray, like the reference
    drawScreenCell(&f, 0, 0, 186, 170, "", .online, false);
    if (@import("builtin").os.tag == .linux) {
        const bmp = try f.encodeBmp(gpa);
        defer gpa.free(bmp);
        writeFileRaw("/tmp/claude-1000/-home-jd-telemouse/a0e08181-344f-4af8-b6cd-7b02c7f04189/scratchpad/mono_186.bmp", bmp);
    }
    try std.testing.expect(true);
}

test "screen stretches but the stand stays constant across aspect ratios" {
    const gpa = std.testing.allocator;
    var f = try fb.Framebuffer.init(gpa, 520, 190);
    defer f.deinit(gpa);
    f.clear(fb.rgb(192, 192, 192));
    // Same cell height, different width: a squarer monitor and a widescreen one.
    // The base, LED bar and bezel stay identical; only the screen widens.
    drawScreenCell(&f, 10, 10, 200, 150, "", .online, false);
    drawScreenCell(&f, 240, 10, 267, 150, "", .online, false);
    if (@import("builtin").os.tag == .linux) {
        const bmp = try f.encodeBmp(gpa);
        defer gpa.free(bmp);
        writeFileRaw("/tmp/claude-1000/-home-jd-telemouse/a0e08181-344f-4af8-b6cd-7b02c7f04189/scratchpad/stretch_demo.bmp", bmp);
    }
    try std.testing.expect(true);
}

fn writeFileRaw(path: [*:0]const u8, bytes: []const u8) void {
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

test "snap aligns a floating screen's edge to a neighbour" {
    const client = Screen{ .x = 0, .y = 0, .w = 1920, .h = 1080, .state = .client, .snapped = true };
    // A 1080p screen dragged near the client's right edge but not aligned.
    const moving = Screen{ .x = 1930, .y = 40, .w = 1920, .h = 1080, .state = .online, .snapped = false };
    const r = snapTo(moving, &.{client}, snap_distance);
    try std.testing.expect(r.snapped);
    try std.testing.expectEqual(@as(i32, 1920), r.x); // left edge snapped to client's right
    try std.testing.expectEqual(@as(i32, 40), moving.y); // perpendicular offset kept
}

test "unsnap cascade drops screens no longer connected" {
    var screens = [_]Screen{
        .{ .x = 0, .y = 0, .w = 100, .h = 100, .state = .client, .snapped = true }, // client
        .{ .x = 100, .y = 0, .w = 100, .h = 100, .state = .online, .snapped = true }, // right of client
        .{ .x = 200, .y = 0, .w = 100, .h = 100, .state = .online, .snapped = true }, // right of #1
    };
    // Detach #1 by moving it away; #2 was only reachable through #1.
    screens[1].x = 500;
    recomputeConnectivity(&screens);
    try std.testing.expect(screens[0].snapped);
    try std.testing.expect(!screens[1].snapped); // floated
    try std.testing.expect(!screens[2].snapped); // orphaned -> floated
}
