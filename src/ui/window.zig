// A minimal native window that displays a software framebuffer and delivers
// input events. X11 (XPutImage) on Linux, Win32 (StretchDIBits) on Windows.
// The framebuffer's 0x00RRGGBB pixels match a 24-bit TrueColor visual directly,
// so no per-pixel conversion is needed on little-endian hosts.
//
// This is the one piece of the UI that cannot be exercised headless.

const std = @import("std");
const builtin = @import("builtin");
const fb = @import("framebuffer.zig");

pub const Event = union(enum) {
    none,
    expose,
    mouse_down: Mouse,
    mouse_up: Mouse,
    mouse_move: Mouse,
    key: struct { code: u32 },
    close,
};
pub const Mouse = struct {
    x: i32,
    y: i32,
    // Root-window (desktop) coordinates, used to drag the borderless window.
    x_root: i32 = 0,
    y_root: i32 = 0,
    button: u8 = 0,
};

pub const OpenError = error{NoDisplay};

pub const Window = switch (builtin.os.tag) {
    .linux => X11Window,
    .windows => Win32Window,
    else => struct {
        pub fn open(_: i32, _: i32, _: [*:0]const u8) OpenError!@This() {
            return error.NoDisplay;
        }
        pub fn present(_: *@This(), _: *const fb.Framebuffer) void {}
        pub fn moveBy(_: *@This(), _: i32, _: i32) void {}
        pub fn nextEvent(_: *@This()) Event {
            return .close;
        }
        pub fn close(_: *@This()) void {}
    },
};

// ===========================================================================
// X11
// ===========================================================================

const X11Window = struct {
    dpy: *x.Display,
    win: x.XWindow,
    gc: *x.GC,
    img: *x.XImage,
    wm_delete: x.Atom,
    pos_x: i32,
    pos_y: i32,

    pub fn open(w: i32, h: i32, title: [*:0]const u8) OpenError!X11Window {
        const dpy = x.XOpenDisplay(null) orelse return error.NoDisplay;
        const scr = x.XDefaultScreen(dpy);
        const root = x.XDefaultRootWindow(dpy);
        const vis = x.XDefaultVisual(dpy, scr);
        const depth = x.XDefaultDepth(dpy, scr);

        // Open roughly centred on the primary screen.
        const sw = x.XDisplayWidth(dpy, scr);
        const sh = x.XDisplayHeight(dpy, scr);
        const px = @divTrunc(sw - w, 2);
        const py = @divTrunc(sh - h, 2);

        const win = x.XCreateSimpleWindow(dpy, root, px, py, @intCast(w), @intCast(h), 0, 0, 0x00c0c0c0);
        _ = x.XStoreName(dpy, win, title);

        // Fix the size: equal min/max so the WM offers no resize handles or
        // maximise, making this a non-resizable dialog/popup.
        var hints = std.mem.zeroes(x.XSizeHints);
        hints.flags = x.PPosition | x.PSize | x.PMinSize | x.PMaxSize;
        hints.x = px;
        hints.y = py;
        hints.width = w;
        hints.height = h;
        hints.min_width = w;
        hints.min_height = h;
        hints.max_width = w;
        hints.max_height = h;
        x.XSetWMNormalHints(dpy, win, &hints);

        // Remove the window-manager decorations (title bar / border): this is a
        // WS_POPUP-style window that draws its own Win2k caption. Motif hints are
        // the widely-honoured way to ask for a borderless top-level window.
        const motif = [5]c_long{ 2, 0, 0, 0, 0 }; // flags=MWM_HINTS_DECORATIONS, decorations=0
        const motif_atom = x.XInternAtom(dpy, "_MOTIF_WM_HINTS", 0);
        _ = x.XChangeProperty(dpy, win, motif_atom, motif_atom, 32, 0, @ptrCast(&motif), 5);

        _ = x.XSelectInput(dpy, win, x.ExposureMask | x.ButtonPressMask | x.ButtonReleaseMask |
            x.PointerMotionMask | x.KeyPressMask | x.StructureNotifyMask);
        var wm_delete = x.XInternAtom(dpy, "WM_DELETE_WINDOW", 0);
        _ = x.XSetWMProtocols(dpy, win, &wm_delete, 1);
        _ = x.XMapWindow(dpy, win);
        _ = x.XMoveWindow(dpy, win, px, py); // some WMs ignore the create position
        const gc = x.XCreateGC(dpy, win, 0, null) orelse return error.NoDisplay;
        // The image shares the framebuffer's storage via present().
        const img = x.XCreateImage(dpy, vis, @intCast(depth), x.ZPixmap, 0, null, @intCast(w), @intCast(h), 32, @intCast(w * 4)) orelse return error.NoDisplay;
        return .{ .dpy = dpy, .win = win, .gc = gc, .img = img, .wm_delete = wm_delete, .pos_x = px, .pos_y = py };
    }

    pub fn present(self: *X11Window, f: *const fb.Framebuffer) void {
        self.img.data = @ptrCast(f.pixels.ptr);
        _ = x.XPutImage(self.dpy, self.win, self.gc, self.img, 0, 0, 0, 0, @intCast(f.w), @intCast(f.h));
        _ = x.XFlush(self.dpy);
    }

    /// Move the (borderless) window by a desktop-pixel delta — used to drag it
    /// by its own caption bar.
    pub fn moveBy(self: *X11Window, dx: i32, dy: i32) void {
        self.pos_x += dx;
        self.pos_y += dy;
        _ = x.XMoveWindow(self.dpy, self.win, self.pos_x, self.pos_y);
    }

    pub fn nextEvent(self: *X11Window) Event {
        var ev: x.XEvent = undefined;
        _ = x.XNextEvent(self.dpy, &ev);
        const b = &ev.xbutton;
        return switch (ev.type) {
            x.Expose => .expose,
            x.ButtonPress => .{ .mouse_down = .{ .x = b.x, .y = b.y, .x_root = b.x_root, .y_root = b.y_root, .button = @intCast(b.button) } },
            x.ButtonRelease => .{ .mouse_up = .{ .x = b.x, .y = b.y, .x_root = b.x_root, .y_root = b.y_root, .button = @intCast(b.button) } },
            x.MotionNotify => .{ .mouse_move = .{ .x = b.x, .y = b.y, .x_root = b.x_root, .y_root = b.y_root, .button = 0 } },
            // Report the keysym (portable) rather than the raw hardware keycode.
            // XLookupKeysym reads keycode+state, both present in XButtonEvent.
            x.KeyPress => .{ .key = .{ .code = @intCast(x.XLookupKeysym(b, 0)) } },
            x.ClientMessage => if (ev.xclient.data[0] == @as(c_long, @intCast(self.wm_delete))) Event.close else Event.none,
            else => .none,
        };
    }

    pub fn close(self: *X11Window) void {
        _ = x.XCloseDisplay(self.dpy);
    }
};

const x = struct {
    const Display = opaque {};
    const Visual = opaque {};
    const GC = opaque {};
    const XWindow = c_ulong;
    const Atom = c_ulong;

    const ExposureMask: c_long = 1 << 15;
    const ButtonPressMask: c_long = 1 << 2;
    const ButtonReleaseMask: c_long = 1 << 3;
    const PointerMotionMask: c_long = 1 << 6;
    const KeyPressMask: c_long = 1 << 0;
    const StructureNotifyMask: c_long = 1 << 17;
    const ZPixmap: c_int = 2;

    // XSizeHints.flags bits.
    const PPosition: c_long = 1 << 2;
    const PSize: c_long = 1 << 3;
    const PMinSize: c_long = 1 << 4;
    const PMaxSize: c_long = 1 << 5;

    const KeyPress: c_int = 2;
    const ButtonPress: c_int = 4;
    const ButtonRelease: c_int = 5;
    const MotionNotify: c_int = 6;
    const Expose: c_int = 12;
    const ClientMessage: c_int = 33;

    const XButtonEvent = extern struct {
        type: c_int,
        serial: c_ulong,
        send_event: c_int,
        display: ?*Display,
        window: XWindow,
        root: XWindow,
        subwindow: XWindow,
        time: c_ulong,
        x: c_int,
        y: c_int,
        x_root: c_int,
        y_root: c_int,
        state: c_uint,
        button: c_uint,
        same_screen: c_int,
    };
    const XClientMessageEvent = extern struct {
        type: c_int,
        serial: c_ulong,
        send_event: c_int,
        display: ?*Display,
        window: XWindow,
        message_type: Atom,
        format: c_int,
        data: [5]c_long,
    };
    const XEvent = extern union {
        type: c_int,
        xbutton: XButtonEvent,
        xclient: XClientMessageEvent,
        pad: [24]c_long,
    };
    const XImage = extern struct {
        width: c_int,
        height: c_int,
        xoffset: c_int,
        format: c_int,
        data: ?[*]u8,
        // remaining fields unused by us.
        rest: [200]u8,
    };
    const XSizeHints = extern struct {
        flags: c_long,
        x: c_int,
        y: c_int,
        width: c_int,
        height: c_int,
        min_width: c_int,
        min_height: c_int,
        max_width: c_int,
        max_height: c_int,
        width_inc: c_int,
        height_inc: c_int,
        min_aspect_x: c_int,
        min_aspect_y: c_int,
        max_aspect_x: c_int,
        max_aspect_y: c_int,
        base_width: c_int,
        base_height: c_int,
        win_gravity: c_int,
    };

    extern "X11" fn XOpenDisplay(?[*:0]const u8) callconv(.c) ?*Display;
    extern "X11" fn XCloseDisplay(*Display) callconv(.c) c_int;
    extern "X11" fn XDefaultScreen(*Display) callconv(.c) c_int;
    extern "X11" fn XDefaultVisual(*Display, c_int) callconv(.c) ?*Visual;
    extern "X11" fn XDefaultDepth(*Display, c_int) callconv(.c) c_int;
    extern "X11" fn XDefaultRootWindow(*Display) callconv(.c) XWindow;
    extern "X11" fn XCreateSimpleWindow(*Display, XWindow, c_int, c_int, c_uint, c_uint, c_uint, c_ulong, c_ulong) callconv(.c) XWindow;
    extern "X11" fn XStoreName(*Display, XWindow, [*:0]const u8) callconv(.c) c_int;
    extern "X11" fn XSelectInput(*Display, XWindow, c_long) callconv(.c) c_int;
    extern "X11" fn XMapWindow(*Display, XWindow) callconv(.c) c_int;
    extern "X11" fn XCreateGC(*Display, XWindow, c_ulong, ?*anyopaque) callconv(.c) ?*GC;
    extern "X11" fn XCreateImage(*Display, ?*Visual, c_uint, c_int, c_int, ?[*]u8, c_uint, c_uint, c_int, c_int) callconv(.c) ?*XImage;
    extern "X11" fn XPutImage(*Display, XWindow, *GC, *XImage, c_int, c_int, c_int, c_int, c_uint, c_uint) callconv(.c) c_int;
    extern "X11" fn XNextEvent(*Display, *XEvent) callconv(.c) c_int;
    extern "X11" fn XFlush(*Display) callconv(.c) c_int;
    extern "X11" fn XInternAtom(*Display, [*:0]const u8, c_int) callconv(.c) Atom;
    extern "X11" fn XSetWMProtocols(*Display, XWindow, *Atom, c_int) callconv(.c) c_int;
    extern "X11" fn XSetWMNormalHints(*Display, XWindow, *XSizeHints) callconv(.c) void;
    extern "X11" fn XMoveWindow(*Display, XWindow, c_int, c_int) callconv(.c) c_int;
    extern "X11" fn XChangeProperty(*Display, XWindow, Atom, Atom, c_int, c_int, *const anyopaque, c_int) callconv(.c) c_int;
    extern "X11" fn XDisplayWidth(*Display, c_int) callconv(.c) c_int;
    extern "X11" fn XDisplayHeight(*Display, c_int) callconv(.c) c_int;
    extern "X11" fn XLookupKeysym(*XButtonEvent, c_int) callconv(.c) c_ulong;
};

// ===========================================================================
// Win32
// ===========================================================================

const Win32Window = struct {
    // Minimal stub: a full Win32 window (RegisterClass/CreateWindow/StretchDIBits
    // + a message pump feeding the Event queue) mirrors the X11 backend. Left as
    // a build-time placeholder until it can be exercised on Windows.
    pub fn open(_: i32, _: i32, _: [*:0]const u8) OpenError!Win32Window {
        return error.NoDisplay;
    }
    pub fn present(_: *Win32Window, _: *const fb.Framebuffer) void {}
    pub fn moveBy(_: *Win32Window, _: i32, _: i32) void {}
    pub fn nextEvent(_: *Win32Window) Event {
        return .close;
    }
    pub fn close(_: *Win32Window) void {}
};
