// Linux input capture via evdev.
//
// Opens the mouse and keyboard event devices under /dev/input, reads their
// events, and translates them into transport-neutral `Event`s. When the client
// hands control to a neighbour it `grab`s the devices (EVIOCGRAB) so the local
// compositor stops seeing them -- that is what makes the local pointer freeze
// and "disappear"; `ungrab` restores local control.
//
// Accessing /dev/input requires read permission on the device nodes, normally
// via membership of the `input` group (the same requirement as the server's
// /dev/uinput access).

const std = @import("std");
const linux = std.os.linux;
const keymap = @import("../common/keymap.zig");

const max_devices = 32;

// ioctl request numbers (generic _IOC encoding), type 'E' (0x45):
//   EVIOCGRAB      = _IOW('E', 0x90, int)
//   EVIOCGBIT(ev)  = _IOC(_IOC_READ, 'E', 0x20 + ev, len)
const EVIOCGRAB: u32 = 0x40044590;

fn eviocgbit(ev: u32, len: u32) u32 {
    return (2 << 30) | (len << 16) | (0x45 << 8) | (0x20 + ev);
}

const input_event = extern struct {
    sec: isize,
    usec: isize,
    type: u16,
    code: u16,
    value: i32,
};

pub const Event = union(enum) {
    motion: struct { dx: i32, dy: i32 },
    scroll: struct { dx: i32, dy: i32 },
    button: struct { name: []const u8, down: bool },
    key: struct { name: []const u8, down: bool },
};

pub const Error = error{NoDevices};

pub const Devices = struct {
    fds: [max_devices]i32 = undefined,
    n: usize = 0,
    grabbed: bool = false,

    // Optional per-scancode name override, indexed by evdev key code, so the
    // client can forward keys through the user's local layout / xmodmap remaps
    // (a captured scancode is otherwise upstream of the X server and carries
    // none of the remapping). A null entry falls back to the default name.
    key_names: ?*const [256]?[]const u8 = null,

    // Relative motion / scroll accumulated within the current event frame.
    acc_dx: i32 = 0,
    acc_dy: i32 = 0,
    acc_sx: i32 = 0,
    acc_sy: i32 = 0,

    /// Open every mouse/keyboard event device under /dev/input.
    pub fn open() Error!Devices {
        var self = Devices{};
        var i: u32 = 0;
        while (i < 64) : (i += 1) {
            var path_buf: [32]u8 = undefined;
            const printed = std.fmt.bufPrint(&path_buf, "/dev/input/event{d}", .{i}) catch continue;
            path_buf[printed.len] = 0;
            const path: [*:0]const u8 = @ptrCast(&path_buf);
            const rc = linux.open(path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0);
            if (linux.errno(rc) != .SUCCESS) continue;
            const fd: i32 = @intCast(rc);
            if (isInputDevice(fd) and self.n < max_devices) {
                self.fds[self.n] = fd;
                self.n += 1;
            } else {
                _ = linux.close(fd);
            }
        }
        if (self.n == 0) return error.NoDevices;
        return self;
    }

    pub fn deinit(self: *Devices) void {
        if (self.grabbed) self.ungrab();
        for (self.fds[0..self.n]) |fd| _ = linux.close(fd);
        self.n = 0;
    }

    pub fn grab(self: *Devices) void {
        if (self.grabbed) return;
        for (self.fds[0..self.n]) |fd| _ = linux.ioctl(fd, EVIOCGRAB, 1);
        self.grabbed = true;
    }

    pub fn ungrab(self: *Devices) void {
        if (!self.grabbed) return;
        for (self.fds[0..self.n]) |fd| _ = linux.ioctl(fd, EVIOCGRAB, 0);
        self.grabbed = false;
    }

    /// Block until the next translated event is available.
    pub fn next(self: *Devices) ?Event {
        while (true) {
            var pfds: [max_devices]linux.pollfd = undefined;
            for (self.fds[0..self.n], 0..) |fd, i| {
                pfds[i] = .{ .fd = fd, .events = linux.POLL.IN, .revents = 0 };
            }
            const prc = linux.poll(&pfds, self.n, -1);
            switch (linux.errno(prc)) {
                .SUCCESS => {},
                .INTR => continue,
                else => return null,
            }
            for (pfds[0..self.n]) |pfd| {
                if (pfd.revents & linux.POLL.IN == 0) continue;
                while (true) {
                    var ev: input_event = undefined;
                    const rc = linux.read(pfd.fd, std.mem.asBytes(&ev), @sizeOf(input_event));
                    switch (linux.errno(rc)) {
                        .SUCCESS => {},
                        .AGAIN => break, // device drained
                        .INTR => continue,
                        else => break,
                    }
                    if (rc != @sizeOf(input_event)) break;
                    if (self.translate(ev)) |out| return out;
                }
            }
        }
    }

    fn translate(self: *Devices, ev: input_event) ?Event {
        switch (ev.type) {
            keymap.EV_SYN => {
                if (ev.code != keymap.SYN_REPORT) return null;
                if (self.acc_dx != 0 or self.acc_dy != 0) {
                    const out = Event{ .motion = .{ .dx = self.acc_dx, .dy = self.acc_dy } };
                    self.acc_dx = 0;
                    self.acc_dy = 0;
                    self.acc_sx = 0;
                    self.acc_sy = 0;
                    return out;
                }
                if (self.acc_sx != 0 or self.acc_sy != 0) {
                    const out = Event{ .scroll = .{ .dx = self.acc_sx, .dy = self.acc_sy } };
                    self.acc_sx = 0;
                    self.acc_sy = 0;
                    return out;
                }
            },
            keymap.EV_REL => switch (ev.code) {
                keymap.REL_X => self.acc_dx += ev.value,
                keymap.REL_Y => self.acc_dy += ev.value,
                keymap.REL_WHEEL => self.acc_sy += ev.value,
                keymap.REL_HWHEEL => self.acc_sx += ev.value,
                else => {},
            },
            keymap.EV_KEY => {
                if (ev.value == 2) return null; // autorepeat
                const down = ev.value == 1;
                if (keymap.buttonName(ev.code)) |name| return .{ .button = .{ .name = name, .down = down } };
                if (self.keyName(ev.code)) |name| return .{ .key = .{ .name = name, .down = down } };
            },
            else => {},
        }
        return null;
    }

    /// The forwarded name for an evdev key code: the local-layout override when
    /// one exists (honouring xmodmap remaps), otherwise the default name.
    fn keyName(self: *Devices, code: u16) ?[]const u8 {
        if (self.key_names) |tbl| {
            if (code < tbl.len) {
                if (tbl[code]) |n| return n;
            }
        }
        return keymap.keyName(code);
    }
};

/// True if the device supports relative motion with a left button (a pointer)
/// or ordinary keyboard keys.
fn isInputDevice(fd: i32) bool {
    var ev_bits: [4]u8 = .{ 0, 0, 0, 0 };
    if (linux.errno(linux.ioctl(fd, eviocgbit(0, ev_bits.len), @intFromPtr(&ev_bits))) != .SUCCESS) return false;
    const has_rel = testBit(&ev_bits, keymap.EV_REL);
    const has_key = testBit(&ev_bits, keymap.EV_KEY);
    if (!has_key) return false;

    var key_bits: [96]u8 = std.mem.zeroes([96]u8);
    _ = linux.ioctl(fd, eviocgbit(keymap.EV_KEY, key_bits.len), @intFromPtr(&key_bits));
    const has_btn_left = testBit(&key_bits, keymap.BTN_LEFT);
    const has_key_a = testBit(&key_bits, keymap.keycode("a").?);

    return (has_rel and has_btn_left) or has_key_a;
}

fn testBit(bits: []const u8, bit: u16) bool {
    const byte = bit / 8;
    if (byte >= bits.len) return false;
    return (bits[byte] & (@as(u8, 1) << @intCast(bit % 8))) != 0;
}
