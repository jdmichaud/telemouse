// Classic Windows control drawing on a software framebuffer.
//
// The 2px 3D edge, the face colour, the caption gradient and the button/panel
// chrome reproduce the classic Win32 look. The bevel algorithm and palette are
// the authentic ones (see /home/jd/wine-test/win2k_popup_x11.c, itself derived
// from Wine's DrawEdge). Backed by the same framebuffer on Windows and Linux,
// so the UI is byte-identical across platforms.

const std = @import("std");
const fb = @import("framebuffer.zig");
const font = @import("font.zig");
const Framebuffer = fb.Framebuffer;

/// A 2-pixel Windows 3D edge. `pressed` false = raised, true = sunken.
pub fn bevel(f: *Framebuffer, x: i32, y: i32, w: i32, h: i32, pressed: bool) void {
    const tlo = if (pressed) fb.dkshadow else fb.white; // top-left outer
    const tli = if (pressed) fb.shadow else fb.light; // top-left inner
    const bri = if (pressed) fb.light else fb.shadow; // bottom-right inner
    const bro = if (pressed) fb.white else fb.dkshadow; // bottom-right outer

    f.hline(x, y, w, tlo);
    f.vline(x, y, h, tlo);
    f.hline(x, y + h - 1, w, bro);
    f.vline(x + w - 1, y, h, bro);

    f.hline(x + 1, y + 1, w - 2, tli);
    f.vline(x + 1, y + 1, h - 2, tli);
    f.hline(x + 1, y + h - 2, w - 2, bri);
    f.vline(x + w - 2, y + 1, h - 2, bri);
}

/// A raised face panel (dialog body, group box face, button up-state).
pub fn panel(f: *Framebuffer, x: i32, y: i32, w: i32, h: i32) void {
    f.fillRect(x, y, w, h, fb.face);
    bevel(f, x, y, w, h, false);
}

/// A sunken well (e.g. the lattice canvas, a text field).
pub fn well(f: *Framebuffer, x: i32, y: i32, w: i32, h: i32, fill: fb.Color) void {
    f.fillRect(x, y, w, h, fill);
    bevel(f, x, y, w, h, true);
}

/// A push button with a centred label. Draws the default ring for the default
/// action; the label shifts down-right by 1px when pressed.
pub fn button(f: *Framebuffer, x: i32, y: i32, w: i32, h: i32, label: []const u8, pressed: bool, is_default: bool) void {
    var bx = x;
    var by = y;
    var bw = w;
    var bh = h;
    if (is_default) {
        f.rect(bx, by, bw, bh, fb.black);
        bx += 1;
        by += 1;
        bw -= 2;
        bh -= 2;
    }
    f.fillRect(bx, by, bw, bh, fb.face);
    bevel(f, bx, by, bw, bh, pressed);
    const off: i32 = if (pressed) 1 else 0;
    font.drawCentered(f, bx + @divTrunc(bw, 2) + off, by + @divTrunc(bh - font.glyph_h, 2) + off, label, fb.black);
}

/// A caption/title bar with the classic navy -> light-blue horizontal gradient.
pub fn captionBar(f: *Framebuffer, x: i32, y: i32, w: i32, h: i32) void {
    if (w <= 0) return;
    var i: i32 = 0;
    while (i < w) : (i += 1) {
        const t: u32 = if (w == 1) 0 else @intCast(@divTrunc(i * 255, w - 1));
        f.vline(x + i, y, h, lerp(fb.cap_left, fb.cap_right, t));
    }
}

fn lerp(a: fb.Color, b: fb.Color, t: u32) fb.Color {
    const ar = (a >> 16) & 0xff;
    const ag = (a >> 8) & 0xff;
    const ab = a & 0xff;
    const br = (b >> 16) & 0xff;
    const bg = (b >> 8) & 0xff;
    const bb = b & 0xff;
    const r = ar + (br - ar) * t / 255;
    const g = ag + (bg - ag) * t / 255;
    const bl = ab + (bb - ab) * t / 255;
    return (r << 16) | (g << 8) | bl;
}

test "demo dialog renders with correct 3D edges" {
    const gpa = std.testing.allocator;
    var f = try Framebuffer.init(gpa, 320, 180);
    defer f.deinit(gpa);

    // Dialog body + outer raised frame.
    f.clear(fb.face);
    bevel(&f, 0, 0, f.w, f.h, false);
    // Caption bar + title.
    captionBar(&f, 3, 3, f.w - 6, 20);
    font.draw(&f, 8, 8, "telemouse - configure screens", fb.cap_text);
    // A sunken canvas well.
    well(&f, 10, 30, 300, 110, fb.rgb(58, 110, 165));
    // OK (default) + Cancel buttons.
    button(&f, 150, 150, 75, 23, "OK", false, true);
    button(&f, 233, 150, 75, 23, "Cancel", false, false);

    // Verify the authentic raised-edge corners of the dialog frame.
    try std.testing.expectEqual(fb.white, f.pixels[0]); // top-left outer = white
    const br: usize = @intCast((f.h - 1) * f.w + (f.w - 1));
    try std.testing.expectEqual(fb.dkshadow, f.pixels[br]); // bottom-right outer = dk shadow
    // Caption first column is the navy gradient start.
    try std.testing.expectEqual(fb.cap_left, f.pixels[@intCast(4 * f.w + 3)]);

    // Dump for visual inspection.
    const bmp = try f.encodeBmp(gpa);
    defer gpa.free(bmp);
    writeFileRaw("/tmp/claude-1000/-home-jd-telemouse/a0e08181-344f-4af8-b6cd-7b02c7f04189/scratchpad/ui_demo.bmp", bmp);
}

// Raw file write (Linux) so the render dump needs no Io context in a test.
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
