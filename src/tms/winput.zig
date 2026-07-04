// Windows input backend built on the Win32 SendInput / SetCursorPos APIs.
//
// Mouse positioning uses SetCursorPos, which takes absolute screen pixel
// coordinates directly, so the configured screen size is unused here. Button
// clicks and key strokes are synthesised with SendInput. Key names are mapped
// to Win32 virtual key codes.

const std = @import("std");

const LONG = i32;
const DWORD = u32;
const WORD = u16;
const ULONG_PTR = usize;
const BOOL = i32;

const INPUT_MOUSE: DWORD = 0;
const INPUT_KEYBOARD: DWORD = 1;

const KEYEVENTF_KEYUP: DWORD = 0x0002;

const MOUSEEVENTF_MOVE: DWORD = 0x0001; // relative motion (no ABSOLUTE flag)
const MOUSEEVENTF_LEFTDOWN: DWORD = 0x0002;
const MOUSEEVENTF_LEFTUP: DWORD = 0x0004;
const MOUSEEVENTF_RIGHTDOWN: DWORD = 0x0008;
const MOUSEEVENTF_RIGHTUP: DWORD = 0x0010;
const MOUSEEVENTF_MIDDLEDOWN: DWORD = 0x0020;
const MOUSEEVENTF_MIDDLEUP: DWORD = 0x0040;
const MOUSEEVENTF_WHEEL: DWORD = 0x0800;
const MOUSEEVENTF_HWHEEL: DWORD = 0x1000;

const MOUSEINPUT = extern struct {
    dx: LONG = 0,
    dy: LONG = 0,
    mouseData: DWORD = 0,
    dwFlags: DWORD = 0,
    time: DWORD = 0,
    dwExtraInfo: ULONG_PTR = 0,
};

const KEYBDINPUT = extern struct {
    wVk: WORD = 0,
    wScan: WORD = 0,
    dwFlags: DWORD = 0,
    time: DWORD = 0,
    dwExtraInfo: ULONG_PTR = 0,
};

const INPUT = extern struct {
    type: DWORD,
    u: extern union {
        mi: MOUSEINPUT,
        ki: KEYBDINPUT,
    },
};

pub extern "user32" fn SendInput(cInputs: u32, pInputs: [*]INPUT, cbSize: i32) callconv(.winapi) u32;
pub extern "user32" fn SetCursorPos(x: i32, y: i32) callconv(.winapi) BOOL;
pub extern "user32" fn GetSystemMetrics(nIndex: i32) callconv(.winapi) i32;

const SM_CXSCREEN: i32 = 0;
const SM_CYSCREEN: i32 = 1;

/// The real primary-screen resolution, or the fallback if it can't be read.
pub fn screenSize(fallback_w: i32, fallback_h: i32) struct { w: i32, h: i32 } {
    const w = GetSystemMetrics(SM_CXSCREEN);
    const h = GetSystemMetrics(SM_CYSCREEN);
    if (w > 0 and h > 0) return .{ .w = w, .h = h };
    return .{ .w = fallback_w, .h = fallback_h };
}

pub const Error = error{
    SendFailed,
    UnknownKey,
    UnknownButton,
};

pub const Options = struct {
    device_name: []const u8,
    screen_width: i32,
    screen_height: i32,
};

pub const Backend = struct {
    pub fn init(opts: Options) Error!Backend {
        _ = opts;
        return .{};
    }

    pub fn deinit(self: *Backend) void {
        _ = self;
    }

    pub fn mouseMove(self: *Backend, x: i32, y: i32) Error!void {
        _ = self;
        if (SetCursorPos(x, y) == 0) return error.SendFailed;
    }

    pub fn mouseMoveRelative(self: *Backend, dx: i32, dy: i32) Error!void {
        _ = self;
        var input = INPUT{ .type = INPUT_MOUSE, .u = .{ .mi = .{ .dx = dx, .dy = dy, .dwFlags = MOUSEEVENTF_MOVE } } };
        if (SendInput(1, @ptrCast(&input), @sizeOf(INPUT)) != 1) return error.SendFailed;
    }

    pub fn mouseClick(self: *Backend, button_name: []const u8) Error!void {
        _ = self;
        var buf: [16]u8 = undefined;
        const name = lower(&buf, button_name) orelse return error.UnknownButton;
        const flags = buttonFlags(name) orelse return error.UnknownButton;
        try sendMouse(flags.down);
        try sendMouse(flags.up);
    }

    pub fn keyCombo(self: *Backend, mods: []const []const u8, key: []const u8) Error!void {
        _ = self;
        var mod_codes: [8]WORD = undefined;
        if (mods.len > mod_codes.len) return error.UnknownKey;
        for (mods, 0..) |m, i| mod_codes[i] = try resolve(m);
        const key_code = try resolve(key);

        for (mod_codes[0..mods.len]) |code| try sendKey(code, false);
        try sendKey(key_code, false);
        try sendKey(key_code, true);
        var i: usize = mods.len;
        while (i > 0) {
            i -= 1;
            try sendKey(mod_codes[i], true);
        }
    }

    pub fn keyDown(self: *Backend, key: []const u8) Error!void {
        _ = self;
        try sendKey(try resolve(key), false);
    }

    pub fn keyUp(self: *Backend, key: []const u8) Error!void {
        _ = self;
        try sendKey(try resolve(key), true);
    }

    pub fn buttonDown(self: *Backend, button_name: []const u8) Error!void {
        _ = self;
        var buf: [16]u8 = undefined;
        const name = lower(&buf, button_name) orelse return error.UnknownButton;
        const flags = buttonFlags(name) orelse return error.UnknownButton;
        try sendMouse(flags.down);
    }

    pub fn buttonUp(self: *Backend, button_name: []const u8) Error!void {
        _ = self;
        var buf: [16]u8 = undefined;
        const name = lower(&buf, button_name) orelse return error.UnknownButton;
        const flags = buttonFlags(name) orelse return error.UnknownButton;
        try sendMouse(flags.up);
    }

    pub fn scroll(self: *Backend, dx: i32, dy: i32) Error!void {
        _ = self;
        // One wheel notch is WHEEL_DELTA (120).
        if (dy != 0) try sendWheel(MOUSEEVENTF_WHEEL, dy * 120);
        if (dx != 0) try sendWheel(MOUSEEVENTF_HWHEEL, dx * 120);
    }

    /// Release every keyboard key and mouse button (blanket unstick). A key-up
    /// for a key that isn't down is a harmless no-op. VKs 0x01-0x07 are the mouse
    /// buttons, released separately below; 0x08.. are keyboard keys.
    pub fn releaseAll(self: *Backend) void {
        _ = self;
        var vk: WORD = 0x08;
        while (vk <= 0xFE) : (vk += 1) sendKey(vk, true) catch {};
        sendMouse(MOUSEEVENTF_LEFTUP) catch {};
        sendMouse(MOUSEEVENTF_RIGHTUP) catch {};
        sendMouse(MOUSEEVENTF_MIDDLEUP) catch {};
    }
};

fn sendMouse(flags: DWORD) Error!void {
    var input = INPUT{ .type = INPUT_MOUSE, .u = .{ .mi = .{ .dwFlags = flags } } };
    if (SendInput(1, @ptrCast(&input), @sizeOf(INPUT)) != 1) return error.SendFailed;
}

fn sendWheel(flags: DWORD, delta: i32) Error!void {
    var input = INPUT{ .type = INPUT_MOUSE, .u = .{ .mi = .{ .dwFlags = flags, .mouseData = @bitCast(delta) } } };
    if (SendInput(1, @ptrCast(&input), @sizeOf(INPUT)) != 1) return error.SendFailed;
}

fn sendKey(vk: WORD, up: bool) Error!void {
    var input = INPUT{
        .type = INPUT_KEYBOARD,
        .u = .{ .ki = .{ .wVk = vk, .dwFlags = if (up) KEYEVENTF_KEYUP else 0 } },
    };
    if (SendInput(1, @ptrCast(&input), @sizeOf(INPUT)) != 1) return error.SendFailed;
}

const ButtonFlags = struct { down: DWORD, up: DWORD };

fn buttonFlags(name: []const u8) ?ButtonFlags {
    if (std.mem.eql(u8, name, "left")) return .{ .down = MOUSEEVENTF_LEFTDOWN, .up = MOUSEEVENTF_LEFTUP };
    if (std.mem.eql(u8, name, "right")) return .{ .down = MOUSEEVENTF_RIGHTDOWN, .up = MOUSEEVENTF_RIGHTUP };
    if (std.mem.eql(u8, name, "middle")) return .{ .down = MOUSEEVENTF_MIDDLEDOWN, .up = MOUSEEVENTF_MIDDLEUP };
    return null;
}

fn resolve(name: []const u8) Error!WORD {
    var buf: [24]u8 = undefined;
    const lowered = lower(&buf, name) orelse return error.UnknownKey;
    // Single letters and digits map directly to their ASCII virtual key code.
    if (lowered.len == 1) {
        const c = lowered[0];
        if (c >= 'a' and c <= 'z') return @intCast(c - 'a' + 'A');
        if (c >= '0' and c <= '9') return @intCast(c);
    }
    return vk_map.get(lowered) orelse error.UnknownKey;
}

fn lower(buf: []u8, name: []const u8) ?[]const u8 {
    if (name.len > buf.len) return null;
    for (name, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf[0..name.len];
}

const vk_map = std.StaticStringMap(WORD).initComptime(.{
    // Modifiers.
    .{ "ctrl", 0x11 },   .{ "control", 0x11 },
    .{ "shift", 0x10 },  .{ "alt", 0x12 },      .{ "altgr", 0x12 },
    .{ "super", 0x5B },  .{ "meta", 0x5B },     .{ "win", 0x5B },

    // Whitespace & editing.
    .{ "space", 0x20 },  .{ "tab", 0x09 },      .{ "enter", 0x0D },   .{ "return", 0x0D },
    .{ "esc", 0x1B },    .{ "escape", 0x1B },   .{ "backspace", 0x08 }, .{ "delete", 0x2E },
    .{ "del", 0x2E },    .{ "insert", 0x2D },   .{ "capslock", 0x14 },

    // Navigation.
    .{ "home", 0x24 },   .{ "end", 0x23 },      .{ "pageup", 0x21 },  .{ "pagedown", 0x22 },
    .{ "up", 0x26 },     .{ "down", 0x28 },     .{ "left", 0x25 },    .{ "right", 0x27 },

    // Function keys.
    .{ "f1", 0x70 }, .{ "f2", 0x71 }, .{ "f3", 0x72 },  .{ "f4", 0x73 },
    .{ "f5", 0x74 }, .{ "f6", 0x75 }, .{ "f7", 0x76 },  .{ "f8", 0x77 },
    .{ "f9", 0x78 }, .{ "f10", 0x79 }, .{ "f11", 0x7A }, .{ "f12", 0x7B },

    // Punctuation (US layout OEM codes).
    .{ "minus", 0xBD },     .{ "equal", 0xBB },      .{ "leftbrace", 0xDB }, .{ "rightbrace", 0xDD },
    .{ "semicolon", 0xBA }, .{ "apostrophe", 0xDE }, .{ "grave", 0xC0 },     .{ "backslash", 0xDC },
    .{ "comma", 0xBC },     .{ "dot", 0xBE },        .{ "period", 0xBE },    .{ "slash", 0xBF },
});
