// Linux input backend built on the uinput subsystem.
//
// At start-up we open /dev/uinput, describe a virtual device that can emit key
// presses (keyboard keys and mouse buttons) and absolute pointer coordinates,
// and ask the kernel to create it. Commands are then translated into
// `input_event` structures written to the device.
//
// Absolute positioning: the device declares an ABS_X/ABS_Y range of
// 0..(screen dimension - 1). A compositor stretches that range across the
// screen, so sending a device coordinate equal to a pixel coordinate lands the
// pointer on that pixel -- provided the configured screen size matches the
// real display.
//
// Accessing /dev/uinput requires write permission on the device node (root, or
// membership of the group that owns it via a udev rule).

const std = @import("std");
const linux = std.os.linux;
const keymap = @import("../common/keymap.zig");

// ioctl request numbers, using the asm-generic _IOC encoding shared by x86,
// arm, aarch64, riscv and loongarch:
//   _IOC(dir, type, nr, size) = (dir << 30) | (size << 16) | (type << 8) | nr
// with type = 'U' (0x55) and size = sizeof(c_int) = 4 for the setter ioctls.
const UI_DEV_CREATE: u32 = 0x5501; //  _IO('U', 1)
const UI_DEV_DESTROY: u32 = 0x5502; // _IO('U', 2)
const UI_SET_EVBIT: u32 = 0x40045564; // _IOW('U', 100, int)
const UI_SET_KEYBIT: u32 = 0x40045565; // _IOW('U', 101, int)
const UI_SET_RELBIT: u32 = 0x40045566; // _IOW('U', 102, int)
const UI_SET_ABSBIT: u32 = 0x40045567; // _IOW('U', 103, int)

const ABS_CNT = 64;
const BUS_USB: u16 = 0x03;

const input_id = extern struct {
    bustype: u16,
    vendor: u16,
    product: u16,
    version: u16,
};

const input_event = extern struct {
    sec: isize = 0,
    usec: isize = 0,
    type: u16,
    code: u16,
    value: i32,
};

const uinput_user_dev = extern struct {
    name: [80]u8,
    id: input_id,
    ff_effects_max: u32,
    absmax: [ABS_CNT]i32,
    absmin: [ABS_CNT]i32,
    absfuzz: [ABS_CNT]i32,
    absflat: [ABS_CNT]i32,
};

pub const Error = error{
    DeviceUnavailable,
    DeviceError,
    UnknownKey,
    UnknownButton,
};

pub const Options = struct {
    device_name: []const u8,
    screen_width: i32,
    screen_height: i32,
};

pub const Backend = struct {
    fd: i32,
    max_x: i32,
    max_y: i32,

    pub fn init(opts: Options) Error!Backend {
        const flags: linux.O = .{ .ACCMODE = .WRONLY };
        const rc = linux.open("/dev/uinput", flags, 0);
        if (linux.errno(rc) != .SUCCESS) return error.DeviceUnavailable;
        const fd: i32 = @intCast(rc);
        errdefer _ = linux.close(fd);

        try ioctl(fd, UI_SET_EVBIT, keymap.EV_KEY);
        try ioctl(fd, UI_SET_EVBIT, keymap.EV_ABS);
        try ioctl(fd, UI_SET_EVBIT, keymap.EV_REL);
        try ioctl(fd, UI_SET_EVBIT, keymap.EV_SYN);

        // Enable every keyboard key code and the mouse buttons we may emit.
        var code: u32 = 0;
        while (code < 256) : (code += 1) try ioctl(fd, UI_SET_KEYBIT, code);
        try ioctl(fd, UI_SET_KEYBIT, keymap.BTN_LEFT);
        try ioctl(fd, UI_SET_KEYBIT, keymap.BTN_RIGHT);
        try ioctl(fd, UI_SET_KEYBIT, keymap.BTN_MIDDLE);

        try ioctl(fd, UI_SET_ABSBIT, keymap.ABS_X);
        try ioctl(fd, UI_SET_ABSBIT, keymap.ABS_Y);

        // Relative pointer motion (edge-switch streaming) and scroll wheels.
        try ioctl(fd, UI_SET_RELBIT, keymap.REL_X);
        try ioctl(fd, UI_SET_RELBIT, keymap.REL_Y);
        try ioctl(fd, UI_SET_RELBIT, keymap.REL_WHEEL);
        try ioctl(fd, UI_SET_RELBIT, keymap.REL_HWHEEL);

        const max_x = @max(opts.screen_width - 1, 1);
        const max_y = @max(opts.screen_height - 1, 1);

        var dev = std.mem.zeroes(uinput_user_dev);
        const name_len = @min(opts.device_name.len, dev.name.len - 1);
        @memcpy(dev.name[0..name_len], opts.device_name[0..name_len]);
        dev.id = .{ .bustype = BUS_USB, .vendor = 0x1234, .product = 0x5678, .version = 1 };
        dev.absmin[keymap.ABS_X] = 0;
        dev.absmax[keymap.ABS_X] = max_x;
        dev.absmin[keymap.ABS_Y] = 0;
        dev.absmax[keymap.ABS_Y] = max_y;

        try writeAll(fd, std.mem.asBytes(&dev));
        try ioctl(fd, UI_DEV_CREATE, 0);

        // Give udev/the compositor a moment to register the new device so the
        // first synthesised event is not dropped.
        var req = linux.timespec{ .sec = 0, .nsec = 80 * 1000 * 1000 };
        _ = linux.nanosleep(&req, null);

        return .{ .fd = fd, .max_x = max_x, .max_y = max_y };
    }

    pub fn deinit(self: *Backend) void {
        _ = ioctl(self.fd, UI_DEV_DESTROY, 0) catch {};
        _ = linux.close(self.fd);
    }

    pub fn mouseMove(self: *Backend, x: i32, y: i32) Error!void {
        const cx = std.math.clamp(x, 0, self.max_x);
        const cy = std.math.clamp(y, 0, self.max_y);
        try self.emit(keymap.EV_ABS, keymap.ABS_X, cx);
        try self.emit(keymap.EV_ABS, keymap.ABS_Y, cy);
        try self.sync();
    }

    pub fn mouseMoveRelative(self: *Backend, dx: i32, dy: i32) Error!void {
        if (dx != 0) try self.emit(keymap.EV_REL, keymap.REL_X, dx);
        if (dy != 0) try self.emit(keymap.EV_REL, keymap.REL_Y, dy);
        try self.sync();
    }

    pub fn mouseClick(self: *Backend, button_name: []const u8) Error!void {
        const code = try resolveButton(button_name);
        try self.emit(keymap.EV_KEY, code, 1);
        try self.sync();
        try self.emit(keymap.EV_KEY, code, 0);
        try self.sync();
    }

    pub fn keyDown(self: *Backend, key: []const u8) Error!void {
        try self.emit(keymap.EV_KEY, try resolve(key), 1);
        try self.sync();
    }

    pub fn keyUp(self: *Backend, key: []const u8) Error!void {
        try self.emit(keymap.EV_KEY, try resolve(key), 0);
        try self.sync();
    }

    pub fn buttonDown(self: *Backend, button_name: []const u8) Error!void {
        try self.emit(keymap.EV_KEY, try resolveButton(button_name), 1);
        try self.sync();
    }

    pub fn buttonUp(self: *Backend, button_name: []const u8) Error!void {
        try self.emit(keymap.EV_KEY, try resolveButton(button_name), 0);
        try self.sync();
    }

    pub fn scroll(self: *Backend, dx: i32, dy: i32) Error!void {
        if (dx != 0) try self.emit(keymap.EV_REL, keymap.REL_HWHEEL, dx);
        if (dy != 0) try self.emit(keymap.EV_REL, keymap.REL_WHEEL, dy);
        try self.sync();
    }

    pub fn keyCombo(self: *Backend, mods: []const []const u8, key: []const u8) Error!void {
        var mod_codes: [8]u16 = undefined;
        if (mods.len > mod_codes.len) return error.UnknownKey;
        for (mods, 0..) |m, i| mod_codes[i] = try resolve(m);
        const key_code = try resolve(key);

        for (mod_codes[0..mods.len]) |code| try self.emit(keymap.EV_KEY, code, 1);
        try self.emit(keymap.EV_KEY, key_code, 1);
        try self.sync();
        try self.emit(keymap.EV_KEY, key_code, 0);
        var i: usize = mods.len;
        while (i > 0) {
            i -= 1;
            try self.emit(keymap.EV_KEY, mod_codes[i], 0);
        }
        try self.sync();
    }

    fn emit(self: *Backend, type_: u16, code: u16, value: i32) Error!void {
        var ev = input_event{ .type = type_, .code = code, .value = value };
        try writeAll(self.fd, std.mem.asBytes(&ev));
    }

    fn sync(self: *Backend) Error!void {
        try self.emit(keymap.EV_SYN, keymap.SYN_REPORT, 0);
    }
};

fn resolve(name: []const u8) Error!u16 {
    var buf: [24]u8 = undefined;
    const lowered = lower(&buf, name) orelse return error.UnknownKey;
    return keymap.keycode(lowered) orelse error.UnknownKey;
}

fn resolveButton(name: []const u8) Error!u16 {
    var buf: [16]u8 = undefined;
    const lowered = lower(&buf, name) orelse return error.UnknownButton;
    return keymap.button(lowered) orelse error.UnknownButton;
}

fn lower(buf: []u8, name: []const u8) ?[]const u8 {
    if (name.len > buf.len) return null;
    for (name, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf[0..name.len];
}

fn ioctl(fd: i32, request: u32, arg: u32) Error!void {
    const rc = linux.ioctl(fd, request, arg);
    if (linux.errno(rc) != .SUCCESS) return error.DeviceError;
}

fn writeAll(fd: i32, bytes: []const u8) Error!void {
    var index: usize = 0;
    while (index < bytes.len) {
        const rc = linux.write(fd, bytes.ptr + index, bytes.len - index);
        switch (linux.errno(rc)) {
            .SUCCESS => index += @intCast(rc),
            .INTR => continue,
            else => return error.DeviceError,
        }
    }
}
