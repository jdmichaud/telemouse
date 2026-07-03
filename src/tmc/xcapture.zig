// X11 input capture via the XInput2 extension — the no-permissions counterpart
// to evdev on an X11 session (the same mechanism Synergy uses). No /dev/input
// access, so no `input` group, no root.
//
// It works in two modes, because a single mechanism can't do both jobs:
//
//   * LOCAL (control on this machine): select XInput2 *raw* events on the root
//     window. These report device activity globally without a grab, so we can
//     watch the pointer approach a screen edge without stealing input from the
//     apps the user is actually using.
//
//   * REMOTE (control on a neighbour): grab the pointer and keyboard
//     (XGrabPointer / XGrabKeyboard) so local apps stop seeing input, and drive
//     off the grab's *cooked* events (MotionNotify / ButtonPress / KeyPress).
//     Raw events are suppressed while we hold the grab, so we must not rely on
//     them here — this is the bug that made an earlier raw-only version stream
//     nothing after handover. Pointer motion is recovered by warping the pointer
//     to the screen centre and reading each MotionNotify's offset from it, the
//     classic relative-from-absolute technique.
//
// The grab is released by `ungrab`, and unconditionally when the X connection
// closes (process exit), so a crash cannot wedge the machine.
//
// libXi is linked for the raw-event selection; everything else (grabs, the event
// loop, warping) is libX11, already linked for cursor tracking. Key codes are X
// keycodes; the evdev code is the X keycode minus 8, translated to a name
// through the same layout snapshot evdev uses (so xmodmap remaps carry over).

const std = @import("std");
const keymap = @import("../common/keymap.zig");
const evdev = @import("evdev.zig");

pub const Event = evdev.Event;
pub const Error = error{Unavailable};

// Core X event types (X.h).
const KeyPress: c_int = 2;
const KeyRelease: c_int = 3;
const ButtonPress: c_int = 4;
const ButtonRelease: c_int = 5;
const MotionNotify: c_int = 6;
const GenericEvent: c_int = 35;

// Event mask bits (X.h) for the pointer grab.
const ButtonPressMask: c_uint = 1 << 2;
const ButtonReleaseMask: c_uint = 1 << 3;
const PointerMotionMask: c_uint = 1 << 6;

const XIAllMasterDevices: c_int = 1;
const GrabModeAsync: c_int = 1;
const CurrentTime: c_ulong = 0;
const None: c_ulong = 0;

// XInput2 raw event types.
const XI_RawKeyPress: c_int = 13;
const XI_RawKeyRelease: c_int = 14;
const XI_RawButtonPress: c_int = 15;
const XI_RawButtonRelease: c_int = 16;
const XI_RawMotion: c_int = 17;
const XIKeyRepeat: c_int = 1 << 16;

pub const XCapture = struct {
    dpy: *x.Display,
    root: x.Window,
    xi_opcode: c_int,
    cx: c_int, // screen centre, the parking point for relative motion while grabbed
    cy: c_int,
    grabbed: bool = false,
    key_names: ?*const [256]?[]const u8 = null,

    pub fn open() Error!XCapture {
        const dpy = x.XOpenDisplay(null) orelse return error.Unavailable;
        errdefer _ = x.XCloseDisplay(dpy);

        var opcode: c_int = 0;
        var ev: c_int = 0;
        var err: c_int = 0;
        if (x.XQueryExtension(dpy, "XInputExtension", &opcode, &ev, &err) == 0)
            return error.Unavailable;

        var major: c_int = 2;
        var minor: c_int = 0;
        if (x.XIQueryVersion(dpy, &major, &minor) != 0) return error.Unavailable; // Status != Success

        const root = x.XDefaultRootWindow(dpy);
        const scr = x.XDefaultScreen(dpy);
        const w = x.XDisplayWidth(dpy, scr);
        const h = x.XDisplayHeight(dpy, scr);

        // Select raw motion/button/key events for all master devices (long enough
        // mask to hold the highest type, RawMotion = 17 → 3 bytes).
        var mask_bits = [_]u8{ 0, 0, 0 };
        setMask(&mask_bits, XI_RawKeyPress);
        setMask(&mask_bits, XI_RawKeyRelease);
        setMask(&mask_bits, XI_RawButtonPress);
        setMask(&mask_bits, XI_RawButtonRelease);
        setMask(&mask_bits, XI_RawMotion);
        var em = x.XIEventMask{ .deviceid = XIAllMasterDevices, .mask_len = mask_bits.len, .mask = &mask_bits };
        _ = x.XISelectEvents(dpy, root, &em, 1);
        _ = x.XFlush(dpy);

        return .{ .dpy = dpy, .root = root, .xi_opcode = opcode, .cx = @divTrunc(w, 2), .cy = @divTrunc(h, 2) };
    }

    pub fn deinit(self: *XCapture) void {
        if (self.grabbed) self.ungrab();
        _ = x.XCloseDisplay(self.dpy);
    }

    /// Take control: grab the pointer and keyboard so local apps stop seeing
    /// input, and park the pointer at the screen centre. While grabbed we read
    /// the grab's cooked events (motion relative to the centre), not raw events.
    pub fn grab(self: *XCapture) void {
        if (self.grabbed) return;
        const mask = ButtonPressMask | ButtonReleaseMask | PointerMotionMask;
        _ = x.XGrabPointer(self.dpy, self.root, 0, mask, GrabModeAsync, GrabModeAsync, self.root, None, CurrentTime);
        _ = x.XGrabKeyboard(self.dpy, self.root, 0, GrabModeAsync, GrabModeAsync, CurrentTime);
        self.grabbed = true;
        self.warpToCentre(); // its MotionNotify reads back as a (0,0) delta and is skipped
    }

    pub fn ungrab(self: *XCapture) void {
        if (!self.grabbed) return;
        _ = x.XUngrabPointer(self.dpy, CurrentTime);
        _ = x.XUngrabKeyboard(self.dpy, CurrentTime);
        _ = x.XFlush(self.dpy);
        self.grabbed = false;
    }

    fn warpToCentre(self: *XCapture) void {
        _ = x.XWarpPointer(self.dpy, None, self.root, 0, 0, 0, 0, self.cx, self.cy);
        _ = x.XFlush(self.dpy);
    }

    /// Block until the next translated event is available.
    pub fn next(self: *XCapture) ?Event {
        while (true) {
            var buf: x.XEvent = undefined;
            _ = x.XNextEvent(self.dpy, &buf);
            const etype = @as(*const c_int, @ptrCast(@alignCast(&buf))).*;
            if (self.grabbed) {
                // Remote: drive off the grab's cooked events.
                if (self.translateCore(etype, &buf)) |out| return out;
            } else {
                // Local: monitor via XInput2 raw events.
                const cookie: *x.XGenericEventCookie = @ptrCast(@alignCast(&buf));
                if (etype != GenericEvent or cookie.extension != self.xi_opcode) continue;
                if (x.XGetEventData(self.dpy, cookie) == 0) continue;
                const result = self.translateRaw(cookie);
                x.XFreeEventData(self.dpy, cookie);
                if (result) |out| return out;
            }
        }
    }

    /// A cooked grab event (used while control is remote).
    fn translateCore(self: *XCapture, etype: c_int, buf: *const x.XEvent) ?Event {
        const e: *const x.XPositionEvent = @ptrCast(@alignCast(buf));
        switch (etype) {
            MotionNotify => {
                const dx = e.x_root - self.cx;
                const dy = e.y_root - self.cy;
                if (dx == 0 and dy == 0) return null; // our own re-centre warp
                self.warpToCentre();
                return .{ .motion = .{ .dx = dx, .dy = dy } };
            },
            ButtonPress, ButtonRelease => {
                const down = etype == ButtonPress;
                return switch (e.code) {
                    1 => .{ .button = .{ .name = "left", .down = down } },
                    2 => .{ .button = .{ .name = "middle", .down = down } },
                    3 => .{ .button = .{ .name = "right", .down = down } },
                    // Wheel: buttons 4/5 vertical, 6/7 horizontal (on press).
                    4 => if (down) .{ .scroll = .{ .dx = 0, .dy = 1 } } else null,
                    5 => if (down) .{ .scroll = .{ .dx = 0, .dy = -1 } } else null,
                    6 => if (down) .{ .scroll = .{ .dx = -1, .dy = 0 } } else null,
                    7 => if (down) .{ .scroll = .{ .dx = 1, .dy = 0 } } else null,
                    else => null,
                };
            },
            KeyPress, KeyRelease => {
                if (e.code < 8) return null;
                const name = self.keyName(@intCast(e.code - 8)) orelse return null;
                return .{ .key = .{ .name = name, .down = etype == KeyPress } };
            },
            else => return null,
        }
    }

    /// A raw XInput2 event (used while control is local).
    fn translateRaw(self: *XCapture, cookie: *x.XGenericEventCookie) ?Event {
        const raw: *const x.XIRawEvent = @ptrCast(@alignCast(cookie.data orelse return null));
        switch (cookie.evtype) {
            XI_RawMotion => {
                const d = rawMotion(raw);
                if (d.dx != 0 or d.dy != 0) return .{ .motion = .{ .dx = d.dx, .dy = d.dy } };
                return null;
            },
            XI_RawButtonPress, XI_RawButtonRelease => {
                const down = cookie.evtype == XI_RawButtonPress;
                return switch (raw.detail) {
                    1 => .{ .button = .{ .name = "left", .down = down } },
                    2 => .{ .button = .{ .name = "middle", .down = down } },
                    3 => .{ .button = .{ .name = "right", .down = down } },
                    else => null,
                };
            },
            XI_RawKeyPress, XI_RawKeyRelease => {
                if (raw.flags & XIKeyRepeat != 0) return null; // autorepeat
                if (raw.detail < 8) return null;
                const name = self.keyName(@intCast(raw.detail - 8)) orelse return null;
                return .{ .key = .{ .name = name, .down = cookie.evtype == XI_RawKeyPress } };
            },
            else => return null,
        }
    }

    fn keyName(self: *XCapture, code: u16) ?[]const u8 {
        if (self.key_names) |tbl| {
            if (code < tbl.len) {
                if (tbl[code]) |n| return n;
            }
        }
        return keymap.keyName(code);
    }
};

/// Extract the relative (dx, dy) from a raw motion event's valuators. Axis 0 is
/// X and axis 1 is Y; `raw_values` holds one double per set mask bit, in order.
fn rawMotion(raw: *const x.XIRawEvent) struct { dx: i32, dy: i32 } {
    const values = raw.raw_values orelse return .{ .dx = 0, .dy = 0 };
    var dx: f64 = 0;
    var dy: f64 = 0;
    var idx: usize = 0;
    var axis: c_int = 0;
    const nbits = raw.valuators.mask_len * 8;
    while (axis < nbits) : (axis += 1) {
        if (maskIsSet(raw.valuators.mask, axis)) {
            const v = values[idx];
            if (axis == 0) dx = v else if (axis == 1) dy = v;
            idx += 1;
        }
    }
    return .{ .dx = @intFromFloat(dx), .dy = @intFromFloat(dy) };
}

fn setMask(mask: []u8, event: c_int) void {
    const e: usize = @intCast(event);
    mask[e >> 3] |= @as(u8, 1) << @intCast(e & 7);
}

fn maskIsSet(mask: [*c]const u8, bit: c_int) bool {
    if (mask == null) return false;
    const b: usize = @intCast(bit);
    return (mask[b >> 3] & (@as(u8, 1) << @intCast(b & 7))) != 0;
}

const x = struct {
    const Display = opaque {};
    const Window = c_ulong;

    // A buffer large enough for any XEvent (the real union is `long pad[24]`).
    const XEvent = extern struct { pad: [24]c_long };

    const XGenericEventCookie = extern struct {
        type: c_int,
        serial: c_ulong,
        send_event: c_int,
        display: ?*Display,
        extension: c_int,
        evtype: c_int,
        cookie: c_uint,
        data: ?*anyopaque,
    };

    // The common prefix of XMotionEvent / XButtonEvent / XKeyEvent: `code` holds
    // the button number or keycode (unused for motion); the position fields line
    // up across all three.
    const XPositionEvent = extern struct {
        type: c_int,
        serial: c_ulong,
        send_event: c_int,
        display: ?*Display,
        window: Window,
        root: Window,
        subwindow: Window,
        time: c_ulong,
        x: c_int,
        y: c_int,
        x_root: c_int,
        y_root: c_int,
        state: c_uint,
        code: c_uint,
        same_screen: c_int,
    };

    const XIEventMask = extern struct {
        deviceid: c_int,
        mask_len: c_int,
        mask: [*c]u8,
    };

    const XIValuatorState = extern struct {
        mask_len: c_int,
        mask: [*c]u8,
        values: [*c]f64,
    };

    const XIRawEvent = extern struct {
        type: c_int,
        serial: c_ulong,
        send_event: c_int,
        display: ?*Display,
        extension: c_int,
        evtype: c_int,
        time: c_ulong,
        deviceid: c_int,
        sourceid: c_int,
        detail: c_int,
        flags: c_int,
        valuators: XIValuatorState,
        raw_values: ?[*]f64,
    };

    extern "X11" fn XOpenDisplay(?[*:0]const u8) callconv(.c) ?*Display;
    extern "X11" fn XCloseDisplay(*Display) callconv(.c) c_int;
    extern "X11" fn XDefaultRootWindow(*Display) callconv(.c) Window;
    extern "X11" fn XDefaultScreen(*Display) callconv(.c) c_int;
    extern "X11" fn XDisplayWidth(*Display, c_int) callconv(.c) c_int;
    extern "X11" fn XDisplayHeight(*Display, c_int) callconv(.c) c_int;
    extern "X11" fn XFlush(*Display) callconv(.c) c_int;
    extern "X11" fn XQueryExtension(*Display, [*:0]const u8, *c_int, *c_int, *c_int) callconv(.c) c_int;
    extern "X11" fn XNextEvent(*Display, *XEvent) callconv(.c) c_int;
    extern "X11" fn XGetEventData(*Display, *XGenericEventCookie) callconv(.c) c_int;
    extern "X11" fn XFreeEventData(*Display, *XGenericEventCookie) callconv(.c) void;
    extern "X11" fn XWarpPointer(*Display, Window, Window, c_int, c_int, c_uint, c_uint, c_int, c_int) callconv(.c) c_int;
    extern "X11" fn XGrabPointer(*Display, Window, c_int, c_uint, c_int, c_int, Window, Window, c_ulong) callconv(.c) c_int;
    extern "X11" fn XGrabKeyboard(*Display, Window, c_int, c_int, c_int, c_ulong) callconv(.c) c_int;
    extern "X11" fn XUngrabPointer(*Display, c_ulong) callconv(.c) c_int;
    extern "X11" fn XUngrabKeyboard(*Display, c_ulong) callconv(.c) c_int;
    extern "Xi" fn XIQueryVersion(*Display, *c_int, *c_int) callconv(.c) c_int;
    extern "Xi" fn XISelectEvents(*Display, Window, *XIEventMask, c_int) callconv(.c) c_int;
};
