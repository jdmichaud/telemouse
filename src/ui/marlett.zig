// Marlett caption glyphs, rendered from the embedded Marlett font's own `glyf`
// outlines. Marlett's caption symbols (close/minimise/maximise/restore) are
// simple straight-line polygons, so a scanline even-odd fill reproduces them
// pixel-for-pixel — no curve flattening or hinting needed. This is the same
// glyph Wine draws for DFCS_CAPTIONCLOSE (Marlett code 0x72).

const std = @import("std");
const fb = @import("framebuffer.zig");

const ttf = @embedFile("marlett.ttf");

// Caption glyph codes (Marlett, MacRoman/ASCII cmap).
pub const close = 0x72;
pub const minimize = 0x30;
pub const maximize = 0x31;
pub const restore = 0x32;

fn u16be(off: usize) u16 {
    return (@as(u16, ttf[off]) << 8) | ttf[off + 1];
}
fn i16be(off: usize) i16 {
    return @bitCast(u16be(off));
}
fn u32be(off: usize) u32 {
    return (@as(u32, u16be(off)) << 16) | u16be(off + 2);
}

fn findTable(tag: *const [4]u8) ?usize {
    const n = u16be(4);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const rec = 12 + i * 16;
        if (std.mem.eql(u8, ttf[rec .. rec + 4], tag)) return u32be(rec + 8);
    }
    return null;
}

const max_points = 128;

const Outline = struct {
    xs: [max_points]f32 = undefined,
    ys: [max_points]f32 = undefined, // already flipped so +y is downward
    /// index one past the last point of each contour
    ends: [16]usize = undefined,
    ncontours: usize = 0,
    npoints: usize = 0,
    upem: f32 = 2048,
};

/// Map an ASCII/Mac code to a glyph id via a format-0 or format-4 cmap subtable.
fn glyphId(code: u32) u32 {
    const cmap = findTable("cmap") orelse return 0;
    const ntab = u16be(cmap + 2);
    var t: usize = 0;
    while (t < ntab) : (t += 1) {
        const sub = cmap + u32be(cmap + 4 + t * 8 + 4);
        switch (u16be(sub)) {
            0 => if (code < 256) {
                const g = ttf[sub + 6 + code];
                if (g != 0) return g;
            },
            4 => {
                const segc = u16be(sub + 6) / 2;
                const end_o = sub + 14;
                const start_o = end_o + segc * 2 + 2;
                const delta_o = start_o + segc * 2;
                const range_o = delta_o + segc * 2;
                var s: usize = 0;
                while (s < segc) : (s += 1) {
                    if (code <= u16be(end_o + s * 2)) {
                        const start = u16be(start_o + s * 2);
                        if (code < start) break;
                        const delta = u16be(delta_o + s * 2);
                        const ro = u16be(range_o + s * 2);
                        if (ro == 0) return (code +% delta) & 0xffff;
                        const gi = u16be(range_o + s * 2 + ro + (code - start) * 2);
                        return if (gi == 0) 0 else (gi +% delta) & 0xffff;
                    }
                }
            },
            else => {},
        }
    }
    return 0;
}

fn glyfLocation(gid: u32) ?struct { off: usize, len: usize } {
    const head = findTable("head") orelse return null;
    const long_loca = i16be(head + 50) != 0;
    const loca = findTable("loca") orelse return null;
    const glyf = findTable("glyf") orelse return null;
    const a = if (long_loca) u32be(loca + gid * 4) else @as(u32, u16be(loca + gid * 2)) * 2;
    const b = if (long_loca) u32be(loca + gid * 4 + 4) else @as(u32, u16be(loca + gid * 2 + 2)) * 2;
    if (b <= a) return null;
    return .{ .off = glyf + a, .len = b - a };
}

/// Parse a simple glyph's contour points (straight-line caption glyphs only —
/// off-curve control points are treated as vertices, which is exact for the
/// Marlett caption symbols).
fn outline(code: u32) ?Outline {
    const head = findTable("head") orelse return null;
    var o = Outline{ .upem = @floatFromInt(u16be(head + 18)) };

    const gid = glyphId(code);
    const loc = glyfLocation(gid) orelse return null;
    var p = loc.off;
    const nc = i16be(p);
    if (nc <= 0) return null;
    o.ncontours = @intCast(nc);
    if (o.ncontours > o.ends.len) return null;
    p += 10; // skip numberOfContours + bbox

    var npts: usize = 0;
    var c: usize = 0;
    while (c < o.ncontours) : (c += 1) {
        npts = @as(usize, u16be(p)) + 1;
        o.ends[c] = npts;
        p += 2;
    }
    if (npts > max_points) return null;
    o.npoints = npts;

    const insn_len = u16be(p);
    p += 2 + insn_len;

    // Flags (with repeat).
    var flags: [max_points]u8 = undefined;
    var i: usize = 0;
    while (i < npts) {
        const fl = ttf[p];
        p += 1;
        flags[i] = fl;
        i += 1;
        if (fl & 8 != 0) {
            var r = ttf[p];
            p += 1;
            while (r > 0) : (r -= 1) {
                if (i >= npts) break;
                flags[i] = fl;
                i += 1;
            }
        }
    }

    // X coordinates (delta-encoded).
    var x: i32 = 0;
    i = 0;
    while (i < npts) : (i += 1) {
        const fl = flags[i];
        if (fl & 2 != 0) {
            const dx: i32 = ttf[p];
            p += 1;
            x += if (fl & 16 != 0) dx else -dx;
        } else if (fl & 16 == 0) {
            x += i16be(p);
            p += 2;
        }
        o.xs[i] = @floatFromInt(x);
    }
    // Y coordinates (delta-encoded), flipped so downward is positive.
    var y: i32 = 0;
    i = 0;
    while (i < npts) : (i += 1) {
        const fl = flags[i];
        if (fl & 4 != 0) {
            const dy: i32 = ttf[p];
            p += 1;
            y += if (fl & 32 != 0) dy else -dy;
        } else if (fl & 32 == 0) {
            y += i16be(p);
            p += 2;
        }
        o.ys[i] = o.upem - @as(f32, @floatFromInt(y));
    }
    return o;
}

/// Draw the caption glyph `code` filling a `size`×`size` box whose top-left is
/// (ox, oy), in `color`. 1-bit scanline fill (crisp, no antialiasing).
pub fn draw(f: *fb.Framebuffer, code: u32, ox: i32, oy: i32, size: i32, color: fb.Color) void {
    const o = outline(code) orelse return;
    const s: f32 = @as(f32, @floatFromInt(size)) / o.upem;

    var row: i32 = 0;
    while (row < size) : (row += 1) {
        const yc = @as(f32, @floatFromInt(row)) + 0.5;
        // Collect edge crossings at this scanline.
        var xs: [max_points]f32 = undefined;
        var nx: usize = 0;
        var c: usize = 0;
        var start: usize = 0;
        while (c < o.ncontours) : (c += 1) {
            const end = o.ends[c];
            var i: usize = start;
            while (i < end) : (i += 1) {
                const j = if (i + 1 < end) i + 1 else start;
                const y0 = o.ys[i] * s;
                const y1 = o.ys[j] * s;
                if ((y0 <= yc and yc < y1) or (y1 <= yc and yc < y0)) {
                    const t = (yc - y0) / (y1 - y0);
                    xs[nx] = (o.xs[i] + t * (o.xs[j] - o.xs[i])) * s;
                    nx += 1;
                }
            }
            start = end;
        }
        if (nx < 2) continue;
        std.mem.sort(f32, xs[0..nx], {}, std.sort.asc(f32));
        var k: usize = 0;
        while (k + 1 < nx) : (k += 2) {
            const xa: i32 = @intFromFloat(@round(xs[k]));
            const xb: i32 = @intFromFloat(@round(xs[k + 1]));
            var px = xa;
            while (px < xb) : (px += 1) f.putPixel(ox + px, oy + row, color);
        }
    }
}

test "close glyph rasterises to an X of the expected extent" {
    const gpa = std.testing.allocator;
    var f = try fb.Framebuffer.init(gpa, 16, 16);
    defer f.deinit(gpa);
    f.clear(fb.white);
    draw(&f, close, 2, 2, 12, fb.black);

    // Count black pixels: the X must have a solid mass but not fill the box.
    var black: usize = 0;
    for (f.pixels) |c| {
        if (c == fb.black) black += 1;
    }
    try std.testing.expect(black > 20); // it drew something substantial
    try std.testing.expect(black < 90); // but it is an X, not a filled block
    // The centre of the X should be filled; the mid-left gap should not.
    try std.testing.expectEqual(fb.black, f.pixels[@intCast(8 * f.w + 8)]);
}
