// Minimal X11 access shared by the client (track/hide the local cursor) and the
// server (place the cursor and watch when it reaches a screen edge).
//
// Why the server needs this: it applies the client's *relative* motion through
// uinput, and the compositor moves the cursor with pointer acceleration — so the
// server cannot predict the cursor position, it must ask the display server
// (XQueryPointer). When the cursor reaches an edge, the server tells the client,
// which then decides to cross. Absolute placement uses XWarpPointer, which (un-
// like a REL/ABS-mixed uinput device) actually moves the pointer.
//
// All of this degrades to a no-op with no X display (Wayland w/o XWayland, or
// headless): `open()` returns null and callers fall back.

const std = @import("std");
const builtin = @import("builtin");

pub const Point = struct { x: i32, y: i32 };
pub const Size = struct { w: i32, h: i32 };

pub const Display = switch (builtin.os.tag) {
    .linux => LinuxDisplay,
    else => StubDisplay,
};

const StubDisplay = struct {
    pub fn open() ?StubDisplay {
        return null;
    }
    pub fn queryPointer(_: *StubDisplay) ?Point {
        return null;
    }
    pub fn warp(_: *StubDisplay, _: i32, _: i32) void {}
    pub fn size(_: *StubDisplay) Size {
        return .{ .w = 1920, .h = 1080 };
    }
    pub fn hideCursor(_: *StubDisplay) void {}
    pub fn showCursor(_: *StubDisplay) void {}
    pub fn close(_: *StubDisplay) void {}
};

const LinuxDisplay = struct {
    dpy: *x.XDisplay,
    root: x.Window,
    screen: c_int,
    hidden: bool = false,

    pub fn open() ?LinuxDisplay {
        const dpy = x.XOpenDisplay(null) orelse return null;
        const scr = x.XDefaultScreen(dpy);
        return .{ .dpy = dpy, .root = x.XDefaultRootWindow(dpy), .screen = scr };
    }

    /// The real cursor position on the root window (screen pixels).
    pub fn queryPointer(self: *LinuxDisplay) ?Point {
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

    /// Move the cursor to an absolute screen position (no acceleration).
    pub fn warp(self: *LinuxDisplay, px: i32, py: i32) void {
        _ = x.XWarpPointer(self.dpy, 0, self.root, 0, 0, 0, 0, px, py);
        _ = x.XFlush(self.dpy);
    }

    pub fn size(self: *LinuxDisplay) Size {
        const w = x.XDisplayWidth(self.dpy, self.screen);
        const h = x.XDisplayHeight(self.dpy, self.screen);
        if (w <= 0 or h <= 0) return .{ .w = 1920, .h = 1080 };
        return .{ .w = w, .h = h };
    }

    pub fn hideCursor(self: *LinuxDisplay) void {
        if (self.hidden) return;
        x.XFixesHideCursor(self.dpy, self.root);
        _ = x.XFlush(self.dpy);
        self.hidden = true;
    }

    pub fn showCursor(self: *LinuxDisplay) void {
        if (!self.hidden) return;
        x.XFixesShowCursor(self.dpy, self.root);
        _ = x.XFlush(self.dpy);
        self.hidden = false;
    }

    pub fn close(self: *LinuxDisplay) void {
        self.showCursor();
        _ = x.XCloseDisplay(self.dpy);
    }

    const x = struct {
        const XDisplay = opaque {};
        const Window = c_ulong;
        extern "X11" fn XOpenDisplay(?[*:0]const u8) callconv(.c) ?*XDisplay;
        extern "X11" fn XCloseDisplay(*XDisplay) callconv(.c) c_int;
        extern "X11" fn XDefaultRootWindow(*XDisplay) callconv(.c) Window;
        extern "X11" fn XDefaultScreen(*XDisplay) callconv(.c) c_int;
        extern "X11" fn XDisplayWidth(*XDisplay, c_int) callconv(.c) c_int;
        extern "X11" fn XDisplayHeight(*XDisplay, c_int) callconv(.c) c_int;
        extern "X11" fn XQueryPointer(*XDisplay, Window, *Window, *Window, *c_int, *c_int, *c_int, *c_int, *c_uint) callconv(.c) c_int;
        extern "X11" fn XWarpPointer(*XDisplay, Window, Window, c_int, c_int, c_uint, c_uint, c_int, c_int) callconv(.c) c_int;
        extern "X11" fn XFlush(*XDisplay) callconv(.c) c_int;
        extern "Xfixes" fn XFixesHideCursor(*XDisplay, Window) callconv(.c) void;
        extern "Xfixes" fn XFixesShowCursor(*XDisplay, Window) callconv(.c) void;
    };
};

/// The primary display's pixel size (one-shot), for auto-detecting a resolution
/// without holding a connection. Falls back to 1920x1080 with no X.
pub fn displaySize() Size {
    var d = Display.open() orelse return .{ .w = 1920, .h = 1080 };
    defer d.close();
    return d.size();
}
