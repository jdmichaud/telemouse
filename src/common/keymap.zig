// Linux input event codes (from <linux/input-event-codes.h>) and a mapping
// from human friendly key names to key codes.
//
// This is used by the server to synthesise keyboard and mouse events through
// the uinput subsystem, and by both ends to validate key names.

const std = @import("std");

// Event types.
pub const EV_SYN: u16 = 0x00;
pub const EV_KEY: u16 = 0x01;
pub const EV_REL: u16 = 0x02;
pub const EV_ABS: u16 = 0x03;

// Synchronisation codes.
pub const SYN_REPORT: u16 = 0;

// Absolute axes.
pub const ABS_X: u16 = 0x00;
pub const ABS_Y: u16 = 0x01;

// Relative axes.
pub const REL_X: u16 = 0x00;
pub const REL_Y: u16 = 0x01;
pub const REL_HWHEEL: u16 = 0x06;
pub const REL_WHEEL: u16 = 0x08;

// Mouse buttons.
pub const BTN_LEFT: u16 = 0x110;
pub const BTN_RIGHT: u16 = 0x111;
pub const BTN_MIDDLE: u16 = 0x112;

/// Map a mouse button name to its event code.
pub fn button(name: []const u8) ?u16 {
    const map = std.StaticStringMap(u16).initComptime(.{
        .{ "left", BTN_LEFT },
        .{ "right", BTN_RIGHT },
        .{ "middle", BTN_MIDDLE },
    });
    return map.get(name);
}

/// Return true if `name` denotes a modifier key. Covers every alias the capture
/// backends may produce — the bare names, `keymap.keyName` aliases, and the
/// left/right forms from the X keysym table (see tmc/keysyms.zig).
pub fn isModifier(name: []const u8) bool {
    const map = std.StaticStringMap(void).initComptime(.{
        .{ "ctrl", {} },      .{ "control", {} },   .{ "leftctrl", {} },  .{ "rightctrl", {} },
        .{ "alt", {} },       .{ "leftalt", {} },   .{ "altgr", {} },     .{ "rightalt", {} },
        .{ "shift", {} },     .{ "leftshift", {} }, .{ "rightshift", {} },
        .{ "super", {} },     .{ "meta", {} },      .{ "win", {} },       .{ "leftmeta", {} },
        .{ "rightmeta", {} },
    });
    return map.has(name);
}

/// Map a key name (case-insensitive, already lowercased by the caller) to its
/// Linux key code. Covers modifiers, letters, digits, punctuation, function
/// keys and the common navigation/editing keys.
pub fn keycode(name: []const u8) ?u16 {
    return key_map.get(name);
}

/// Reverse of `keycode`: map a Linux key code to a canonical name (used to
/// translate captured evdev events into protocol commands). Returns the first
/// matching alias, which is sufficient since the server resolves any alias.
pub fn keyName(code: u16) ?[]const u8 {
    const values = key_map.values();
    const keys = key_map.keys();
    for (values, 0..) |v, i| {
        if (v == code) return keys[i];
    }
    return null;
}

/// Reverse of `button`: map a mouse button event code to its name.
pub fn buttonName(code: u16) ?[]const u8 {
    return switch (code) {
        BTN_LEFT => "left",
        BTN_RIGHT => "right",
        BTN_MIDDLE => "middle",
        else => null,
    };
}

const key_map = std.StaticStringMap(u16).initComptime(.{
    // Modifiers.
    .{ "ctrl", 29 },      .{ "control", 29 },   .{ "leftctrl", 29 },  .{ "rightctrl", 97 },
    .{ "shift", 42 },     .{ "leftshift", 42 }, .{ "rightshift", 54 },
    .{ "alt", 56 },       .{ "leftalt", 56 },   .{ "altgr", 100 },    .{ "rightalt", 100 },
    .{ "super", 125 },    .{ "meta", 125 },     .{ "win", 125 },      .{ "leftmeta", 125 },

    // Letters.
    .{ "a", 30 }, .{ "b", 48 }, .{ "c", 46 }, .{ "d", 32 }, .{ "e", 18 },
    .{ "f", 33 }, .{ "g", 34 }, .{ "h", 35 }, .{ "i", 23 }, .{ "j", 36 },
    .{ "k", 37 }, .{ "l", 38 }, .{ "m", 50 }, .{ "n", 49 }, .{ "o", 24 },
    .{ "p", 25 }, .{ "q", 16 }, .{ "r", 19 }, .{ "s", 31 }, .{ "t", 20 },
    .{ "u", 22 }, .{ "v", 47 }, .{ "w", 17 }, .{ "x", 45 }, .{ "y", 21 },
    .{ "z", 44 },

    // Digit row.
    .{ "1", 2 }, .{ "2", 3 }, .{ "3", 4 }, .{ "4", 5 }, .{ "5", 6 },
    .{ "6", 7 }, .{ "7", 8 }, .{ "8", 9 }, .{ "9", 10 }, .{ "0", 11 },

    // Punctuation.
    .{ "minus", 12 },      .{ "equal", 13 },      .{ "leftbrace", 26 },  .{ "rightbrace", 27 },
    .{ "semicolon", 39 },  .{ "apostrophe", 40 }, .{ "grave", 41 },      .{ "backslash", 43 },
    .{ "comma", 51 },      .{ "dot", 52 },        .{ "period", 52 },     .{ "slash", 53 },

    // Whitespace & editing.
    .{ "space", 57 },      .{ "tab", 15 },        .{ "enter", 28 },      .{ "return", 28 },
    .{ "esc", 1 },         .{ "escape", 1 },      .{ "backspace", 14 },  .{ "delete", 111 },
    .{ "del", 111 },       .{ "insert", 110 },    .{ "capslock", 58 },

    // Navigation.
    .{ "home", 102 },      .{ "end", 107 },       .{ "pageup", 104 },    .{ "pagedown", 109 },
    .{ "up", 103 },        .{ "down", 108 },      .{ "left", 105 },      .{ "right", 106 },

    // Function keys.
    .{ "f1", 59 },  .{ "f2", 60 },  .{ "f3", 61 },  .{ "f4", 62 },
    .{ "f5", 63 },  .{ "f6", 64 },  .{ "f7", 65 },  .{ "f8", 66 },
    .{ "f9", 67 },  .{ "f10", 68 }, .{ "f11", 87 }, .{ "f12", 88 },
});
