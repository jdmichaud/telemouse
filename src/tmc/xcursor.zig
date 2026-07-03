// Display-server access for the Linux edge-switch client: read the real
// (OS-accelerated) cursor position, warp it, and hide/show it. This is how the
// switcher tracks the true cursor on the local screen (instead of raw device
// motion, which diverges from the accelerated cursor) and hides the pointer
// while control is on a remote screen. XFixesHideCursor is reference-counted by
// the X server, so if this process crashes the cursor is restored automatically.
//
// Everything degrades gracefully to a no-op when there is no X display (e.g.
// Wayland without XWayland, or headless): edge switching still works, just
// without cursor tracking/hiding.

const std = @import("std");
const builtin = @import("builtin");
const keysyms = @import("keysyms.zig");

pub const Point = struct { x: i32, y: i32 };
pub const Size = struct { w: i32, h: i32 };

/// The primary display's pixel size, so the client's own resolution never needs
/// to be configured. Falls back to 1920x1080 when there is no X display.
pub fn displaySize() Size {
    if (builtin.os.tag != .linux) return .{ .w = 1920, .h = 1080 };
    const x = LinuxXCursor.x;
    const dpy = x.XOpenDisplay(null) orelse return .{ .w = 1920, .h = 1080 };
    defer _ = x.XCloseDisplay(dpy);
    const scr = x.XDefaultScreen(dpy);
    const w = x.XDisplayWidth(dpy, scr);
    const h = x.XDisplayHeight(dpy, scr);
    if (w <= 0 or h <= 0) return .{ .w = 1920, .h = 1080 };
    return .{ .w = w, .h = h };
}

pub const XCursor = switch (builtin.os.tag) {
    .linux => LinuxXCursor,
    else => StubXCursor,
};

const StubXCursor = struct {
    pub fn open() ?StubXCursor {
        return null;
    }
    pub fn queryPointer(_: *StubXCursor) ?Point {
        return null;
    }
    pub fn warp(_: *StubXCursor, _: i32, _: i32) void {}
    pub fn hideCursor(_: *StubXCursor) void {}
    pub fn showCursor(_: *StubXCursor) void {}
    pub fn loadKeyNames(_: *StubXCursor, _: *[256]?[]const u8) void {}
    pub fn close(_: *StubXCursor) void {}
};

const LinuxXCursor = struct {
    dpy: *x.Display,
    root: x.Window,
    hidden: bool = false,

    pub fn open() ?LinuxXCursor {
        const dpy = x.XOpenDisplay(null) orelse return null;
        return .{ .dpy = dpy, .root = x.XDefaultRootWindow(dpy) };
    }

    /// The real cursor position on the root window (screen pixels).
    pub fn queryPointer(self: *LinuxXCursor) ?Point {
        var root_ret: x.Window = undefined;
        var child_ret: x.Window = undefined;
        var rx: c_int = 0;
        var ry: c_int = 0;
        var wx: c_int = 0;
        var wy: c_int = 0;
        var mask: c_uint = 0;
        if (x.XQueryPointer(self.dpy, self.root, &root_ret, &child_ret, &rx, &ry, &wx, &wy, &mask) == 0) return null;
        return .{ .x = rx, .y = ry };
    }

    pub fn warp(self: *LinuxXCursor, px: i32, py: i32) void {
        _ = x.XWarpPointer(self.dpy, 0, self.root, 0, 0, 0, 0, px, py);
        _ = x.XFlush(self.dpy);
    }

    pub fn hideCursor(self: *LinuxXCursor) void {
        if (self.hidden) return;
        x.XFixesHideCursor(self.dpy, self.root);
        _ = x.XFlush(self.dpy);
        self.hidden = true;
    }

    pub fn showCursor(self: *LinuxXCursor) void {
        if (!self.hidden) return;
        x.XFixesShowCursor(self.dpy, self.root);
        _ = x.XFlush(self.dpy);
        self.hidden = false;
    }

    /// Snapshot the live X keyboard map into `out`, indexed by evdev key code:
    /// `out[code]` gets the telemouse name the user's layout assigns to that
    /// physical key (honouring `xmodmap`/XKB remaps), or is left untouched when
    /// we have no name for its keysym (caller falls back to the raw scancode).
    /// An X keycode is the evdev code plus 8.
    pub fn loadKeyNames(self: *LinuxXCursor, out: *[256]?[]const u8) void {
        var min_kc: c_int = 0;
        var max_kc: c_int = 0;
        _ = x.XDisplayKeycodes(self.dpy, &min_kc, &max_kc);
        if (min_kc < 8 or max_kc < min_kc) return;
        var per: c_int = 0;
        const syms = x.XGetKeyboardMapping(self.dpy, @intCast(min_kc), max_kc - min_kc + 1, &per) orelse return;
        if (per <= 0) return;
        defer _ = x.XFree(syms);

        var kc: c_int = min_kc;
        while (kc <= max_kc) : (kc += 1) {
            const evcode = kc - 8; // evdev code = X keycode - 8
            if (evcode < 0 or evcode >= @as(c_int, out.len)) continue;
            const ks = syms[@intCast((kc - min_kc) * per)]; // group 1, level 0
            if (ks == 0) continue;
            if (keysyms.name(ks)) |nm| out[@intCast(evcode)] = nm;
        }
    }

    pub fn close(self: *LinuxXCursor) void {
        self.showCursor();
        _ = x.XCloseDisplay(self.dpy);
    }

    const x = struct {
        const Display = opaque {};
        const Window = c_ulong;
        extern "X11" fn XOpenDisplay(?[*:0]const u8) callconv(.c) ?*Display;
        extern "X11" fn XCloseDisplay(*Display) callconv(.c) c_int;
        extern "X11" fn XDefaultRootWindow(*Display) callconv(.c) Window;
        extern "X11" fn XDefaultScreen(*Display) callconv(.c) c_int;
        extern "X11" fn XDisplayWidth(*Display, c_int) callconv(.c) c_int;
        extern "X11" fn XDisplayHeight(*Display, c_int) callconv(.c) c_int;
        extern "X11" fn XQueryPointer(*Display, Window, *Window, *Window, *c_int, *c_int, *c_int, *c_int, *c_uint) callconv(.c) c_int;
        extern "X11" fn XWarpPointer(*Display, Window, Window, c_int, c_int, c_uint, c_uint, c_int, c_int) callconv(.c) c_int;
        extern "X11" fn XFlush(*Display) callconv(.c) c_int;
        extern "X11" fn XDisplayKeycodes(*Display, *c_int, *c_int) callconv(.c) c_int;
        extern "X11" fn XGetKeyboardMapping(*Display, u8, c_int, *c_int) callconv(.c) ?[*]c_ulong;
        extern "X11" fn XFree(?*anyopaque) callconv(.c) c_int;
        extern "Xfixes" fn XFixesHideCursor(*Display, Window) callconv(.c) void;
        extern "Xfixes" fn XFixesShowCursor(*Display, Window) callconv(.c) void;
    };
};
