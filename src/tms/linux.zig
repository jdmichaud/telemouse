// The Linux server injection backend: either XTEST (through the X server, needs
// no device permissions) or uinput (kernel virtual device, needs /dev/uinput).
//
// The choice is made once at start-up: on an X11 session XTEST is preferred, so
// the common desktop case needs no udev rule or `input` group. When XTEST is
// unavailable (no libXtst, no X display, or a Wayland/headless session) it falls
// back to uinput, which works everywhere but needs the device permission. Both
// expose the same method surface, so the rest of the server is oblivious to the
// choice.

const std = @import("std");
const uinput = @import("uinput.zig");
const xtest = @import("xtest.zig");

pub const Error = uinput.Error || xtest.Error;

pub const Options = struct {
    device_name: []const u8,
    screen_width: i32,
    screen_height: i32,
    // Prefer XTEST (set by the server when the session is X11, or forced with
    // `--backend xtest`). Falls back to uinput if XTEST cannot start.
    try_xtest: bool = false,
};

pub const Backend = union(enum) {
    uinput: uinput.Backend,
    xtest: xtest.Backend,

    pub fn init(opts: Options) !Backend {
        if (opts.try_xtest) {
            if (xtest.Backend.init()) |b| {
                return .{ .xtest = b };
            } else |_| {
                // XTEST unavailable — fall through to uinput.
            }
        }
        return .{ .uinput = try uinput.Backend.init(.{
            .device_name = opts.device_name,
            .screen_width = opts.screen_width,
            .screen_height = opts.screen_height,
        }) };
    }

    pub fn deinit(self: *Backend) void {
        switch (self.*) {
            .uinput => |*b| b.deinit(),
            .xtest => |*b| b.deinit(),
        }
    }

    /// Human-readable backend name, for logging.
    pub fn name(self: *const Backend) []const u8 {
        return switch (self.*) {
            .uinput => "uinput",
            .xtest => "XTEST",
        };
    }

    pub fn mouseMove(self: *Backend, x: i32, y: i32) Error!void {
        return switch (self.*) {
            .uinput => |*b| b.mouseMove(x, y),
            .xtest => |*b| b.mouseMove(x, y),
        };
    }

    pub fn mouseMoveRelative(self: *Backend, dx: i32, dy: i32) Error!void {
        return switch (self.*) {
            .uinput => |*b| b.mouseMoveRelative(dx, dy),
            .xtest => |*b| b.mouseMoveRelative(dx, dy),
        };
    }

    pub fn mouseClick(self: *Backend, button_name: []const u8) Error!void {
        return switch (self.*) {
            .uinput => |*b| b.mouseClick(button_name),
            .xtest => |*b| b.mouseClick(button_name),
        };
    }

    pub fn keyDown(self: *Backend, key: []const u8) Error!void {
        return switch (self.*) {
            .uinput => |*b| b.keyDown(key),
            .xtest => |*b| b.keyDown(key),
        };
    }

    pub fn keyUp(self: *Backend, key: []const u8) Error!void {
        return switch (self.*) {
            .uinput => |*b| b.keyUp(key),
            .xtest => |*b| b.keyUp(key),
        };
    }

    pub fn buttonDown(self: *Backend, button_name: []const u8) Error!void {
        return switch (self.*) {
            .uinput => |*b| b.buttonDown(button_name),
            .xtest => |*b| b.buttonDown(button_name),
        };
    }

    pub fn buttonUp(self: *Backend, button_name: []const u8) Error!void {
        return switch (self.*) {
            .uinput => |*b| b.buttonUp(button_name),
            .xtest => |*b| b.buttonUp(button_name),
        };
    }

    pub fn scroll(self: *Backend, dx: i32, dy: i32) Error!void {
        return switch (self.*) {
            .uinput => |*b| b.scroll(dx, dy),
            .xtest => |*b| b.scroll(dx, dy),
        };
    }

    pub fn keyCombo(self: *Backend, mods: []const []const u8, key: []const u8) Error!void {
        return switch (self.*) {
            .uinput => |*b| b.keyCombo(mods, key),
            .xtest => |*b| b.keyCombo(mods, key),
        };
    }
};
