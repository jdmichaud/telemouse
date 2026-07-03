// Translate an X11 KeySym into a telemouse key name (one the server's keymap
// resolves). This is how the client honours the user's local keyboard layout
// and `xmodmap` remaps: capture happens at the evdev layer, which is *upstream*
// of the X server, so a raw scancode carries none of the remapping. By looking
// up each captured key's keysym in the live X keymap and translating it here,
// a Caps Lock remapped to Hyper_L (added to mod4) is forwarded as `meta`,
// exactly as it behaves locally.
//
// Only keys we can name are translated; an unknown keysym returns null and the
// caller falls back to the raw scancode name, so this can only ever *add*
// fidelity, never break a key that already works.
//
// KeySym constants are the stable values from <X11/keysymdef.h>.

const std = @import("std");

const letters = [26][]const u8{
    "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m",
    "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z",
};
const digits = [10][]const u8{ "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" };
const fkeys = [12][]const u8{ "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12" };

/// Map an X11 KeySym to a canonical telemouse key name, or null when we have no
/// name for it (the caller then keeps the raw scancode name).
pub fn name(ks: u64) ?[]const u8 {
    return switch (ks) {
        // Modifiers. Super/Meta/Hyper (either side) all collapse to `meta`,
        // which the server maps to KEY_LEFTMETA — matching a mod4 remap.
        0xffe1 => "leftshift",
        0xffe2 => "rightshift",
        0xffe3 => "leftctrl",
        0xffe4 => "rightctrl",
        0xffe5 => "capslock",
        0xffe7, 0xffe8, 0xffeb, 0xffec, 0xffed, 0xffee => "meta",
        0xffe9 => "leftalt",
        0xffea, 0xfe03 => "altgr", // Alt_R / ISO_Level3_Shift

        // Whitespace, editing and navigation.
        0xff08 => "backspace",
        0xff09 => "tab",
        0xff0d => "enter",
        0xff1b => "escape",
        0x0020 => "space",
        0xffff => "delete",
        0xff63 => "insert",
        0xff50 => "home",
        0xff57 => "end",
        0xff55 => "pageup",
        0xff56 => "pagedown",
        0xff51 => "left",
        0xff52 => "up",
        0xff53 => "right",
        0xff54 => "down",

        // Function keys F1..F12.
        0xffbe...0xffc9 => fkeys[ks - 0xffbe],

        // Letters (level 0 is lowercase; accept uppercase for safety).
        'a'...'z' => letters[ks - 'a'],
        'A'...'Z' => letters[ks - 'A'],

        // Digit row.
        '0'...'9' => digits[ks - '0'],

        // Punctuation, mapped to the keymap's names.
        '-' => "minus",
        '=' => "equal",
        '[' => "leftbrace",
        ']' => "rightbrace",
        ';' => "semicolon",
        '\'' => "apostrophe",
        '`' => "grave",
        '\\' => "backslash",
        ',' => "comma",
        '.' => "period",
        '/' => "slash",

        else => null,
    };
}

test "modifier remaps collapse as expected" {
    // The motivating case: Caps Lock remapped to Hyper_L must forward as meta.
    try std.testing.expectEqualStrings("meta", name(0xffed).?); // Hyper_L
    try std.testing.expectEqualStrings("meta", name(0xffeb).?); // Super_L
    try std.testing.expectEqualStrings("meta", name(0xffe7).?); // Meta_L
    try std.testing.expectEqualStrings("capslock", name(0xffe5).?); // unchanged Caps Lock
    try std.testing.expectEqualStrings("leftctrl", name(0xffe3).?);
    try std.testing.expectEqualStrings("altgr", name(0xfe03).?); // ISO_Level3_Shift
}

test "letters, digits and function keys" {
    try std.testing.expectEqualStrings("a", name('a').?);
    try std.testing.expectEqualStrings("z", name('Z').?); // uppercase keysym -> lower name
    try std.testing.expectEqualStrings("7", name('7').?);
    try std.testing.expectEqualStrings("f1", name(0xffbe).?);
    try std.testing.expectEqualStrings("f12", name(0xffc9).?);
    try std.testing.expectEqualStrings("minus", name('-').?);
}

test "unknown keysyms fall through to null" {
    try std.testing.expect(name(0) == null);
    try std.testing.expect(name(0xff20) == null); // Multi_key, no name
    try std.testing.expect(name(0x1008ff11) == null); // XF86AudioLowerVolume
}
