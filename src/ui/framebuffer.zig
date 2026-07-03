// A software framebuffer and 2D primitives. The whole configuration UI is drawn
// into one of these, then blitted to a native window (Win32 GDI / X11 XPutImage).
// Rendering here means the UI is pixel-identical on every platform.
//
// Colours are 0x00RRGGBB. Pixels are stored one u32 per pixel.

const std = @import("std");

pub const Color = u32;

pub fn rgb(r: u8, g: u8, b: u8) Color {
    return (@as(u32, r) << 16) | (@as(u32, g) << 8) | b;
}

// Authentic Wine GetSysColor defaults (dlls/win32u/sysparams.c), as used by
// win2k_popup_wine.c. Note 3D light == face colour in the Win2000 scheme.
pub const face = rgb(212, 208, 200); // COLOR_BTNFACE  #D4D0C8
pub const white = rgb(255, 255, 255); // COLOR_BTNHIGHLIGHT (raised outer top-left)
pub const light = rgb(212, 208, 200); // COLOR_3DLIGHT (raised inner top-left)
pub const shadow = rgb(128, 128, 128); // COLOR_BTNSHADOW (raised inner bottom-right)
pub const dkshadow = rgb(64, 64, 64); // COLOR_3DDKSHADOW (raised outer bottom-right)
pub const black = rgb(0, 0, 0); // COLOR_BTNTEXT / WINDOWTEXT
pub const window = rgb(255, 255, 255); // COLOR_WINDOW
pub const cap_left = rgb(10, 36, 106); // COLOR_ACTIVECAPTION #0A246A gradient start
pub const cap_right = rgb(166, 202, 240); // COLOR_GRADIENTACTIVECAPTION #A6CAF0 end
pub const cap_text = rgb(255, 255, 255); // COLOR_CAPTIONTEXT

pub const Framebuffer = struct {
    pixels: []Color,
    w: i32,
    h: i32,

    pub fn init(gpa: std.mem.Allocator, w: i32, h: i32) !Framebuffer {
        const pixels = try gpa.alloc(Color, @intCast(w * h));
        return .{ .pixels = pixels, .w = w, .h = h };
    }

    pub fn deinit(self: *Framebuffer, gpa: std.mem.Allocator) void {
        gpa.free(self.pixels);
    }

    pub fn clear(self: *Framebuffer, c: Color) void {
        @memset(self.pixels, c);
    }

    pub fn putPixel(self: *Framebuffer, x: i32, y: i32, c: Color) void {
        if (x < 0 or y < 0 or x >= self.w or y >= self.h) return;
        self.pixels[@intCast(y * self.w + x)] = c;
    }

    pub fn fillRect(self: *Framebuffer, x: i32, y: i32, w: i32, h: i32, c: Color) void {
        const x0 = @max(x, 0);
        const y0 = @max(y, 0);
        const x1 = @min(x + w, self.w);
        const y1 = @min(y + h, self.h);
        var yy = y0;
        while (yy < y1) : (yy += 1) {
            const row = yy * self.w;
            var xx = x0;
            while (xx < x1) : (xx += 1) self.pixels[@intCast(row + xx)] = c;
        }
    }

    pub fn hline(self: *Framebuffer, x: i32, y: i32, w: i32, c: Color) void {
        self.fillRect(x, y, w, 1, c);
    }

    pub fn vline(self: *Framebuffer, x: i32, y: i32, h: i32, c: Color) void {
        self.fillRect(x, y, 1, h, c);
    }

    /// 1px rectangle outline.
    pub fn rect(self: *Framebuffer, x: i32, y: i32, w: i32, h: i32, c: Color) void {
        self.hline(x, y, w, c);
        self.hline(x, y + h - 1, w, c);
        self.vline(x, y, h, c);
        self.vline(x + w - 1, y, h, c);
    }

    /// Encode as a 24-bit uncompressed BMP (for headless render verification).
    pub fn encodeBmp(self: *const Framebuffer, gpa: std.mem.Allocator) ![]u8 {
        const w: usize = @intCast(self.w);
        const h: usize = @intCast(self.h);
        const row_stride = (w * 3 + 3) & ~@as(usize, 3);
        const pixels_size = row_stride * h;
        const total = 54 + pixels_size;

        var out = try gpa.alloc(u8, total);
        @memset(out, 0);
        // BITMAPFILEHEADER
        out[0] = 'B';
        out[1] = 'M';
        std.mem.writeInt(u32, out[2..6], @intCast(total), .little);
        std.mem.writeInt(u32, out[10..14], 54, .little); // pixel data offset
        // BITMAPINFOHEADER
        std.mem.writeInt(u32, out[14..18], 40, .little);
        std.mem.writeInt(i32, out[18..22], self.w, .little);
        std.mem.writeInt(i32, out[22..26], self.h, .little);
        std.mem.writeInt(u16, out[26..28], 1, .little); // planes
        std.mem.writeInt(u16, out[28..30], 24, .little); // bpp
        std.mem.writeInt(u32, out[34..38], @intCast(pixels_size), .little);

        // Pixel data: bottom-up rows, BGR.
        var yy: usize = 0;
        while (yy < h) : (yy += 1) {
            const src_row = (h - 1 - yy) * w;
            const dst_row = 54 + yy * row_stride;
            var xx: usize = 0;
            while (xx < w) : (xx += 1) {
                const px = self.pixels[src_row + xx];
                const d = dst_row + xx * 3;
                out[d] = @truncate(px); // B
                out[d + 1] = @truncate(px >> 8); // G
                out[d + 2] = @truncate(px >> 16); // R
            }
        }
        return out;
    }
};
