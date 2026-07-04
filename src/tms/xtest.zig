// XTEST injection backend: synthesise input through the X server (the XTest
// extension), so on an X11 session the telemouse server needs no /dev/uinput
// access at all — no udev rule, no `input` group, no root. This is the same
// mechanism Synergy uses on X11.
//
// libXtst is loaded at runtime with dlopen rather than linked, so it is an
// *optional* dependency: if the library or an X display is missing, `init`
// fails and the caller (src/tms/linux.zig) falls back to the uinput backend.
//
// Key codes: the client forwards Linux key *names*, which `keymap` maps to
// evdev key codes. An X keycode is the evdev code plus 8 (the fixed offset the
// Xorg evdev driver uses), so that is the only translation needed.

const std = @import("std");
const keymap = @import("../common/keymap.zig");

pub const Error = error{ Unavailable, UnknownKey, UnknownButton };

const XDisplay = opaque {};

// From libX11 (already linked by the server for cursor tracking).
extern "X11" fn XOpenDisplay(?[*:0]const u8) callconv(.c) ?*XDisplay;
extern "X11" fn XCloseDisplay(*XDisplay) callconv(.c) c_int;
extern "X11" fn XFlush(*XDisplay) callconv(.c) c_int;

// libdl (part of libc here) — used to load libXtst without a link dependency.
extern "c" fn dlopen(?[*:0]const u8, c_int) callconv(.c) ?*anyopaque;
extern "c" fn dlsym(?*anyopaque, [*:0]const u8) callconv(.c) ?*anyopaque;

const RTLD_NOW: c_int = 2;

// XTest entry points (see <X11/extensions/XTest.h>).
const FakeKeyFn = *const fn (*XDisplay, c_uint, c_int, c_ulong) callconv(.c) c_int;
const FakeButtonFn = *const fn (*XDisplay, c_uint, c_int, c_ulong) callconv(.c) c_int;
const FakeRelMotionFn = *const fn (*XDisplay, c_int, c_int, c_ulong) callconv(.c) c_int;
const FakeMotionFn = *const fn (*XDisplay, c_int, c_int, c_int, c_ulong) callconv(.c) c_int;

pub const Backend = struct {
    dpy: *XDisplay,
    fake_key: FakeKeyFn,
    fake_button: FakeButtonFn,
    fake_rel: FakeRelMotionFn,
    fake_motion: FakeMotionFn,

    pub fn init() Error!Backend {
        const lib = dlopen("libXtst.so.6", RTLD_NOW) orelse return error.Unavailable;
        const key = dlsym(lib, "XTestFakeKeyEvent") orelse return error.Unavailable;
        const btn = dlsym(lib, "XTestFakeButtonEvent") orelse return error.Unavailable;
        const rel = dlsym(lib, "XTestFakeRelativeMotionEvent") orelse return error.Unavailable;
        const mot = dlsym(lib, "XTestFakeMotionEvent") orelse return error.Unavailable;
        const dpy = XOpenDisplay(null) orelse return error.Unavailable;
        return .{
            .dpy = dpy,
            .fake_key = @ptrCast(key),
            .fake_button = @ptrCast(btn),
            .fake_rel = @ptrCast(rel),
            .fake_motion = @ptrCast(mot),
        };
    }

    pub fn deinit(self: *Backend) void {
        _ = XCloseDisplay(self.dpy);
    }

    /// Release every key and button (blanket unstick). X keycodes 8..255 cover
    /// all evdev codes (evdev = X keycode - 8); a release of a key that isn't
    /// pressed is a no-op. Best-effort — safe to call before we exit.
    pub fn releaseAll(self: *Backend) void {
        var kc: c_uint = 8;
        while (kc < 256) : (kc += 1) _ = self.fake_key(self.dpy, kc, 0, 0);
        _ = self.fake_button(self.dpy, 1, 0, 0);
        _ = self.fake_button(self.dpy, 2, 0, 0);
        _ = self.fake_button(self.dpy, 3, 0, 0);
        self.flush();
    }

    fn flush(self: *Backend) void {
        _ = XFlush(self.dpy);
    }

    /// Absolute placement. The server normally places via XWarpPointer, but keep
    /// this correct for completeness (screen 0, no delay).
    pub fn mouseMove(self: *Backend, x: i32, y: i32) Error!void {
        _ = self.fake_motion(self.dpy, 0, x, y, 0);
        self.flush();
    }

    pub fn mouseMoveRelative(self: *Backend, dx: i32, dy: i32) Error!void {
        _ = self.fake_rel(self.dpy, dx, dy, 0);
        self.flush();
    }

    pub fn mouseClick(self: *Backend, button_name: []const u8) Error!void {
        const b = try xButton(button_name);
        _ = self.fake_button(self.dpy, b, 1, 0);
        _ = self.fake_button(self.dpy, b, 0, 0);
        self.flush();
    }

    pub fn keyDown(self: *Backend, key: []const u8) Error!void {
        _ = self.fake_key(self.dpy, try xKeycode(key), 1, 0);
        self.flush();
    }

    pub fn keyUp(self: *Backend, key: []const u8) Error!void {
        _ = self.fake_key(self.dpy, try xKeycode(key), 0, 0);
        self.flush();
    }

    pub fn buttonDown(self: *Backend, button_name: []const u8) Error!void {
        _ = self.fake_button(self.dpy, try xButton(button_name), 1, 0);
        self.flush();
    }

    pub fn buttonUp(self: *Backend, button_name: []const u8) Error!void {
        _ = self.fake_button(self.dpy, try xButton(button_name), 0, 0);
        self.flush();
    }

    pub fn scroll(self: *Backend, dx: i32, dy: i32) Error!void {
        // XTest models the wheel as buttons: 4 up / 5 down, 6 left / 7 right.
        if (dy != 0) {
            const b: c_uint = if (dy > 0) 4 else 5;
            var n = @abs(dy);
            while (n > 0) : (n -= 1) {
                _ = self.fake_button(self.dpy, b, 1, 0);
                _ = self.fake_button(self.dpy, b, 0, 0);
            }
        }
        if (dx != 0) {
            const b: c_uint = if (dx > 0) 7 else 6;
            var n = @abs(dx);
            while (n > 0) : (n -= 1) {
                _ = self.fake_button(self.dpy, b, 1, 0);
                _ = self.fake_button(self.dpy, b, 0, 0);
            }
        }
        self.flush();
    }

    pub fn keyCombo(self: *Backend, mods: []const []const u8, key: []const u8) Error!void {
        var mod_codes: [8]c_uint = undefined;
        if (mods.len > mod_codes.len) return error.UnknownKey;
        for (mods, 0..) |m, i| mod_codes[i] = try xKeycode(m);
        const key_code = try xKeycode(key);

        for (mod_codes[0..mods.len]) |c| _ = self.fake_key(self.dpy, c, 1, 0);
        _ = self.fake_key(self.dpy, key_code, 1, 0);
        _ = self.fake_key(self.dpy, key_code, 0, 0);
        var i: usize = mods.len;
        while (i > 0) {
            i -= 1;
            _ = self.fake_key(self.dpy, mod_codes[i], 0, 0);
        }
        self.flush();
    }
};

/// The X keycode for a telemouse key name: its evdev code plus the fixed +8
/// offset the Xorg evdev driver applies.
fn xKeycode(name: []const u8) Error!c_uint {
    var buf: [24]u8 = undefined;
    const lowered = lower(&buf, name) orelse return error.UnknownKey;
    const evcode = keymap.keycode(lowered) orelse return error.UnknownKey;
    return @as(c_uint, evcode) + 8;
}

/// X core button number for a button name (1 left, 2 middle, 3 right).
fn xButton(name: []const u8) Error!c_uint {
    var buf: [16]u8 = undefined;
    const lowered = lower(&buf, name) orelse return error.UnknownButton;
    const map = std.StaticStringMap(c_uint).initComptime(.{
        .{ "left", 1 }, .{ "middle", 2 }, .{ "right", 3 },
    });
    return map.get(lowered) orelse error.UnknownButton;
}

fn lower(buf: []u8, name: []const u8) ?[]const u8 {
    if (name.len > buf.len) return null;
    for (name, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf[0..name.len];
}

test "key name -> X keycode is evdev + 8" {
    try std.testing.expectEqual(@as(c_uint, 58 + 8), try xKeycode("capslock"));
    try std.testing.expectEqual(@as(c_uint, 125 + 8), try xKeycode("meta"));
    try std.testing.expectError(error.UnknownKey, xKeycode("nope"));
}

test "button name -> X button number" {
    try std.testing.expectEqual(@as(c_uint, 1), try xButton("left"));
    try std.testing.expectEqual(@as(c_uint, 3), try xButton("Right"));
    try std.testing.expectError(error.UnknownButton, xButton("scroll"));
}
