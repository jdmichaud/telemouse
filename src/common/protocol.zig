// The telemouse wire protocol.
//
// A command is a single text line: a verb followed by arguments. The transport
// depends on the command, chosen for the trade-off it needs:
//
//   mouse <x> <y>   Move the pointer to absolute screen pixel (x, y).
//                   Sent over UDP (one command per datagram): pointer motion is
//                   high frequency and loss tolerant -- a dropped update is
//                   simply superseded by the next one -- so it favours low
//                   latency over reliability.
//   click <button>  Click a mouse button: left | right | middle.
//   key <combo>     Generate a key stroke. <combo> is a '+' separated list of
//                   keys where every element but the last is a modifier, e.g.
//                   "a", "ctrl+c", "ctrl+alt+t".
//
//                   Clicks and key strokes are discrete events where a lost or
//                   reordered event is unacceptable, so they are sent over TCP
//                   (one command per line, '\n' terminated; a leading '\r' is
//                   tolerated).
//
// Commands are fire-and-forget: the server does not acknowledge them (it logs
// failures instead). Clients validate syntax locally before sending.
//
// Command names are matched case-insensitively; key and button names are
// resolved to platform key codes by the server's input backend, so this module
// stays platform neutral and only performs syntactic parsing.
//
// `classify` reports which transport a parsed command belongs to.

const std = @import("std");

pub const max_modifiers = 8;

pub const KeyCombo = struct {
    mods: [max_modifiers][]const u8 = undefined,
    mods_len: usize = 0,
    key: []const u8 = "",

    pub fn modifiers(self: *const KeyCombo) []const []const u8 {
        return self.mods[0..self.mods_len];
    }
};

pub const Command = union(enum) {
    /// Move the pointer to an absolute screen pixel. Discrete/reliable,
    /// fire-and-forget (used by `-e` and the stdin stream).
    mouse: struct { x: i32, y: i32 },
    /// Absolute placement at an edge crossing, which the server acknowledges
    /// (writes "placed\n" back on the TCP channel). The client waits for that ack
    /// before it starts streaming relative `move` on UDP, so the placement can
    /// never be overtaken by the first motion deltas on the other channel.
    place: struct { x: i32, y: i32 },
    /// Move the pointer by a relative delta (UDP). Kept for completeness / future
    /// chaining, but edge-switch streaming uses `moveto` instead.
    move: struct { dx: i32, dy: i32 },
    /// Move the pointer to an absolute screen pixel, streamed over UDP during
    /// edge switching. Unlike `mouse`/`place` this is fire-and-forget (no ack)
    /// and applied without pointer acceleration, so the remote cursor tracks the
    /// client's virtual cursor exactly — the crossing point then matches the edge
    /// regardless of speed. Idempotent, so a dropped/reordered datagram self-heals.
    moveto: struct { x: i32, y: i32 },
    click: struct { button: []const u8 },
    key: KeyCombo,
    // Separate press/release events, used when forwarding captured input so
    // held keys, modifiers and drags behave correctly.
    key_down: struct { key: []const u8 },
    key_up: struct { key: []const u8 },
    button_down: struct { button: []const u8 },
    button_up: struct { button: []const u8 },
    scroll: struct { dx: i32, dy: i32 },
    /// Hide the server's own pointer: sent when the edge-switch client takes
    /// control away from this server (returns home or hops to another), so the
    /// server screen doesn't show a stray cursor while it isn't being driven. A
    /// `place` reveals it again. Display-only; the input backend ignores it.
    hide,
    /// Shared-clipboard update: `data` is the copied text, base64-encoded so it
    /// travels as one safe line regardless of newlines/binary. Handled by the
    /// clipboard subsystem, not the input backend.
    clipboard: struct { data: []const u8 },

    /// Which transport this command should be sent over: only the relative
    /// motion stream goes over UDP; every discrete event -- including absolute
    /// placement -- goes over TCP so it is reliable and ordered.
    pub fn transport(self: Command) Transport {
        return switch (self) {
            .move, .moveto => .udp,
            .mouse, .place, .click, .key, .key_down, .key_up, .button_down, .button_up, .scroll, .hide, .clipboard => .tcp,
        };
    }
};

pub const Transport = enum { udp, tcp };

pub const ParseError = error{
    EmptyCommand,
    UnknownCommand,
    MissingArgument,
    TooManyArguments,
    InvalidCoordinate,
    TooManyModifiers,
};

/// Parse a single command line. Returned slices (button / key names) borrow
/// from `line`, so the result is only valid while `line` lives.
pub fn parse(line: []const u8) ParseError!Command {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyCommand;

    var it = std.mem.tokenizeAny(u8, trimmed, " \t");
    const verb = it.next() orelse return error.EmptyCommand;

    if (eqlIgnoreCase(verb, "mouse")) {
        const xs = it.next() orelse return error.MissingArgument;
        const ys = it.next() orelse return error.MissingArgument;
        if (it.next() != null) return error.TooManyArguments;
        const x = std.fmt.parseInt(i32, xs, 10) catch return error.InvalidCoordinate;
        const y = std.fmt.parseInt(i32, ys, 10) catch return error.InvalidCoordinate;
        return .{ .mouse = .{ .x = x, .y = y } };
    } else if (eqlIgnoreCase(verb, "place")) {
        const xs = it.next() orelse return error.MissingArgument;
        const ys = it.next() orelse return error.MissingArgument;
        if (it.next() != null) return error.TooManyArguments;
        const x = std.fmt.parseInt(i32, xs, 10) catch return error.InvalidCoordinate;
        const y = std.fmt.parseInt(i32, ys, 10) catch return error.InvalidCoordinate;
        return .{ .place = .{ .x = x, .y = y } };
    } else if (eqlIgnoreCase(verb, "move")) {
        const dxs = it.next() orelse return error.MissingArgument;
        const dys = it.next() orelse return error.MissingArgument;
        if (it.next() != null) return error.TooManyArguments;
        const dx = std.fmt.parseInt(i32, dxs, 10) catch return error.InvalidCoordinate;
        const dy = std.fmt.parseInt(i32, dys, 10) catch return error.InvalidCoordinate;
        return .{ .move = .{ .dx = dx, .dy = dy } };
    } else if (eqlIgnoreCase(verb, "moveto")) {
        const xs = it.next() orelse return error.MissingArgument;
        const ys = it.next() orelse return error.MissingArgument;
        if (it.next() != null) return error.TooManyArguments;
        const x = std.fmt.parseInt(i32, xs, 10) catch return error.InvalidCoordinate;
        const y = std.fmt.parseInt(i32, ys, 10) catch return error.InvalidCoordinate;
        return .{ .moveto = .{ .x = x, .y = y } };
    } else if (eqlIgnoreCase(verb, "click")) {
        const button = it.next() orelse return error.MissingArgument;
        if (it.next() != null) return error.TooManyArguments;
        return .{ .click = .{ .button = button } };
    } else if (eqlIgnoreCase(verb, "key")) {
        const combo = it.next() orelse return error.MissingArgument;
        if (it.next() != null) return error.TooManyArguments;
        return .{ .key = try parseCombo(combo) };
    } else if (eqlIgnoreCase(verb, "keydown")) {
        return .{ .key_down = .{ .key = try single(&it) } };
    } else if (eqlIgnoreCase(verb, "keyup")) {
        return .{ .key_up = .{ .key = try single(&it) } };
    } else if (eqlIgnoreCase(verb, "buttondown")) {
        return .{ .button_down = .{ .button = try single(&it) } };
    } else if (eqlIgnoreCase(verb, "buttonup")) {
        return .{ .button_up = .{ .button = try single(&it) } };
    } else if (eqlIgnoreCase(verb, "scroll")) {
        const dxs = it.next() orelse return error.MissingArgument;
        const dys = it.next() orelse return error.MissingArgument;
        if (it.next() != null) return error.TooManyArguments;
        const dx = std.fmt.parseInt(i32, dxs, 10) catch return error.InvalidCoordinate;
        const dy = std.fmt.parseInt(i32, dys, 10) catch return error.InvalidCoordinate;
        return .{ .scroll = .{ .dx = dx, .dy = dy } };
    } else if (eqlIgnoreCase(verb, "hide")) {
        if (it.next() != null) return error.TooManyArguments;
        return .hide;
    } else if (eqlIgnoreCase(verb, "clipboard")) {
        // The single argument is base64 (no whitespace); empty means "cleared".
        const data = it.next() orelse "";
        if (it.next() != null) return error.TooManyArguments;
        return .{ .clipboard = .{ .data = data } };
    }
    return error.UnknownCommand;
}

fn single(it: *std.mem.TokenIterator(u8, .any)) ParseError![]const u8 {
    const arg = it.next() orelse return error.MissingArgument;
    if (it.next() != null) return error.TooManyArguments;
    return arg;
}

fn parseCombo(combo: []const u8) ParseError!KeyCombo {
    var result = KeyCombo{};
    var parts = std.mem.splitScalar(u8, combo, '+');
    // Collect the tokens; the last one is the key, the rest are modifiers.
    var tokens: [max_modifiers + 1][]const u8 = undefined;
    var count: usize = 0;
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        if (count >= tokens.len) return error.TooManyModifiers;
        tokens[count] = part;
        count += 1;
    }
    if (count == 0) return error.MissingArgument;
    result.key = tokens[count - 1];
    result.mods_len = count - 1;
    if (result.mods_len > max_modifiers) return error.TooManyModifiers;
    var i: usize = 0;
    while (i < result.mods_len) : (i += 1) result.mods[i] = tokens[i];
    return result;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

test "place parses like mouse but is its own acked command over TCP" {
    const p = try parse("place 1919 300");
    try std.testing.expect(p == .place);
    try std.testing.expectEqual(@as(i32, 1919), p.place.x);
    try std.testing.expectEqual(@as(i32, 300), p.place.y);
    try std.testing.expectEqual(Transport.tcp, p.transport());

    // mouse stays a distinct, fire-and-forget absolute move.
    const m = try parse("mouse 10 20");
    try std.testing.expect(m == .mouse);
    try std.testing.expectEqual(Transport.tcp, m.transport());

    // move is the only UDP command.
    try std.testing.expectEqual(Transport.udp, (try parse("move -3 0")).transport());
}

test "hide is a bare TCP command" {
    const h = try parse("hide");
    try std.testing.expect(h == .hide);
    try std.testing.expectEqual(Transport.tcp, h.transport());
    try std.testing.expectError(error.TooManyArguments, parse("hide now"));
}

test "clipboard carries a base64 payload over TCP" {
    const c = try parse("clipboard aGVsbG8=");
    try std.testing.expect(c == .clipboard);
    try std.testing.expectEqualStrings("aGVsbG8=", c.clipboard.data);
    try std.testing.expectEqual(Transport.tcp, c.transport());
    // An empty clipboard (cleared) is allowed.
    try std.testing.expectEqualStrings("", (try parse("clipboard")).clipboard.data);
}
