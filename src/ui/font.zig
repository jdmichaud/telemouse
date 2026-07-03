// Tahoma text, rendered from the font's own embedded bitmap strikes.
//
// win2k_popup_wine.c draws its text with
//   Tahoma:pixelsize=11:embeddedbitmap=true:antialias=false
// which means the glyphs it shows *are* the hand-tuned 11px 1-bit bitmaps that
// Tahoma carries in its EBLC/EBDT tables. We read those same bitmaps straight
// out of the embedded font -- no rasteriser, no FreeType/Xft, no ttf.zig -- so
// the result is pixel-identical to the reference and works the same on every
// platform. tahoma.ttf is Wine's redistributable Tahoma.

const std = @import("std");
const fb = @import("framebuffer.zig");

const ttf = @embedFile("tahoma.ttf");
const target_ppem: u8 = 11;

// Approximate layout metrics for the 11px strike (callers use these for
// spacing/centring; glyph placement uses the real per-glyph metrics).
pub const glyph_h: i32 = 8;
pub const line_height: i32 = 14;

const Info = struct {
    cmap4: usize, // format-4 cmap subtable offset
    ebdt: usize,
    isa: usize, // absolute offset of the strike's indexSubTableArray
    nidx: usize,
    ascent: i32,
};

var g_info: ?Info = null;

fn rd16(o: usize) u16 {
    return std.mem.readInt(u16, ttf[o..][0..2], .big);
}
fn rd32(o: usize) u32 {
    return std.mem.readInt(u32, ttf[o..][0..4], .big);
}
fn rdi8(o: usize) i8 {
    return @bitCast(ttf[o]);
}

fn findTable(tag: *const [4]u8) ?usize {
    const n = rd16(4);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const o = 12 + i * 16;
        if (std.mem.eql(u8, ttf[o..][0..4], tag)) return rd32(o + 8);
    }
    return null;
}

fn info() *const Info {
    if (g_info == null) g_info = build();
    return &g_info.?;
}

fn build() Info {
    const cmap_off = findTable("cmap") orelse 0;
    const eblc = findTable("EBLC") orelse 0;
    const ebdt = findTable("EBDT") orelse 0;

    // Pick a format-4 cmap subtable (prefer platform 3 / encoding 1).
    var cmap4: usize = 0;
    const ntab = rd16(cmap_off + 2);
    var i: usize = 0;
    while (i < ntab) : (i += 1) {
        const e = cmap_off + 4 + i * 8;
        const pid = rd16(e);
        const eid = rd16(e + 2);
        const sub = cmap_off + rd32(e + 4);
        if (rd16(sub) == 4) {
            if (pid == 3 and eid == 1) cmap4 = sub else if (cmap4 == 0) cmap4 = sub;
        }
    }

    // Pick the strike matching target_ppem (nearest otherwise).
    const num_strikes = rd32(eblc + 4);
    var chosen: usize = eblc + 8;
    var best_diff: i32 = 999;
    var s: usize = 0;
    while (s < num_strikes) : (s += 1) {
        const base = eblc + 8 + s * 48;
        const ppem = ttf[base + 44];
        const diff = @as(i32, @intCast(@abs(@as(i32, ppem) - target_ppem)));
        if (diff < best_diff) {
            best_diff = diff;
            chosen = base;
        }
    }
    const isa = eblc + rd32(chosen);
    const nidx = rd32(chosen + 8);
    const ascender = rdi8(chosen + 16);

    return .{ .cmap4 = cmap4, .ebdt = ebdt, .isa = isa, .nidx = nidx, .ascent = ascender };
}

fn glyphIndex(cp: u16) u16 {
    const c = info().cmap4;
    const seg_x2 = rd16(c + 6);
    const segc = seg_x2 / 2;
    const end_o = c + 14;
    const start_o = end_o + seg_x2 + 2;
    const delta_o = start_o + seg_x2;
    const range_o = delta_o + seg_x2;
    var s: usize = 0;
    while (s < segc) : (s += 1) {
        const end = rd16(end_o + s * 2);
        if (cp <= end) {
            const start = rd16(start_o + s * 2);
            if (cp < start) return 0;
            const delta = rd16(delta_o + s * 2);
            const ro = rd16(range_o + s * 2);
            if (ro == 0) return cp +% delta;
            const gi = rd16(range_o + s * 2 + ro + (cp - start) * 2);
            return if (gi == 0) 0 else gi +% delta;
        }
    }
    return 0;
}

const Glyph = struct { w: i32, h: i32, bx: i32, by: i32, adv: i32, data: usize };

fn glyph(g: u16) ?Glyph {
    const in = info();
    var k: usize = 0;
    while (k < in.nidx) : (k += 1) {
        const e = in.isa + k * 8;
        const fg = rd16(e);
        const lg = rd16(e + 2);
        if (g < fg or g > lg) continue;
        const ist = in.isa + rd32(e + 4);
        // indexFormat 1, imageFormat 2 (Tahoma's strikes).
        const image_data_off = rd32(ist + 4);
        const offs = ist + 8;
        const o0 = rd32(offs + (g - fg) * 4);
        const o1 = rd32(offs + (g - fg + 1) * 4);
        if (o0 == o1) return null; // blank (e.g. space)
        const base = in.ebdt + image_data_off + o0;
        return .{
            .h = ttf[base],
            .w = ttf[base + 1],
            .bx = rdi8(base + 2),
            .by = rdi8(base + 3),
            .adv = ttf[base + 4],
            .data = base + 5,
        };
    }
    return null;
}

fn drawChar(f: *fb.Framebuffer, pen_x: i32, baseline: i32, c: u8, color: fb.Color) i32 {
    const g = glyphIndex(c);
    const gl = glyph(g) orelse return blankAdvance(c);
    const top = baseline - gl.by;
    const left = pen_x + gl.bx;
    var row: i32 = 0;
    while (row < gl.h) : (row += 1) {
        var col: i32 = 0;
        while (col < gl.w) : (col += 1) {
            const bi: usize = @intCast(row * gl.w + col);
            if ((ttf[gl.data + bi / 8] >> @intCast(7 - bi % 8)) & 1 == 1) {
                f.putPixel(left + col, top + row, color);
            }
        }
    }
    return gl.adv;
}

fn charAdvance(c: u8) i32 {
    const gl = glyph(glyphIndex(c)) orelse return blankAdvance(c);
    return gl.adv;
}

fn blankAdvance(c: u8) i32 {
    return if (c == ' ') 3 else 3;
}

pub fn textWidth(s: []const u8) i32 {
    var w: i32 = 0;
    for (s) |c| w += charAdvance(c);
    return w;
}

pub fn draw(f: *fb.Framebuffer, x: i32, y: i32, s: []const u8, color: fb.Color) void {
    const baseline = y + info().ascent;
    var pen = x;
    for (s) |c| pen += drawChar(f, pen, baseline, c, color);
}

pub fn drawCentered(f: *fb.Framebuffer, cx: i32, y: i32, s: []const u8, color: fb.Color) void {
    draw(f, cx - @divTrunc(textWidth(s), 2), y, s, color);
}

test "tahoma text renders from embedded strikes" {
    const gpa = std.testing.allocator;
    var f = try fb.Framebuffer.init(gpa, 380, 100);
    defer f.deinit(gpa);
    f.clear(fb.face);
    draw(&f, 6, 6, "ABCDEFGHIJKLMNOPQRSTUVWXYZ", fb.black);
    draw(&f, 6, 22, "abcdefghijklmnopqrstuvwxyz", fb.black);
    draw(&f, 6, 38, "0123456789  OK   Cancel   Identify", fb.black);
    draw(&f, 6, 54, "192.168.1.20:24800   1920x1080", fb.black);
    draw(&f, 6, 70, "living-room htpc  (offline)", fb.black);
    var any = false;
    for (f.pixels) |p| if (p == fb.black) {
        any = true;
        break;
    };
    try std.testing.expect(any);
    if (@import("builtin").os.tag == .linux) {
        const bmp = try f.encodeBmp(gpa);
        defer gpa.free(bmp);
        writeFileRaw("/tmp/claude-1000/-home-jd-telemouse/a0e08181-344f-4af8-b6cd-7b02c7f04189/scratchpad/ui_tahoma.bmp", bmp);
    }
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
