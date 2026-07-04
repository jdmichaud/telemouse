// Input backend abstraction.
//
// The concrete backend is selected at compile time from the host platform:
// uinput on Linux, SendInput on Windows. A `dry_run` backend performs no real
// input and only logs what it would do, which is handy for testing on a
// machine without the required permissions or display.

const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("../common/protocol.zig");
const log = @import("../common/log.zig");

const native = switch (builtin.os.tag) {
    .linux => @import("linux.zig"),
    .windows => @import("winput.zig"),
    else => @compileError("the telemouse server supports Linux and Windows only"),
};

pub const Options = struct {
    device_name: []const u8,
    screen_width: i32,
    screen_height: i32,
    dry_run: bool,
    // Linux only: prefer the XTEST backend (no /dev/uinput needed). Ignored on
    // Windows. The server sets this when the session is X11.
    try_xtest: bool = false,
};

pub const Size = struct { w: i32, h: i32 };

/// The resolution the server operates in and advertises. On Windows this is the
/// real primary screen (SetCursorPos is pixel-native); elsewhere it is the
/// configured coordinate space (the uinput absolute range).
pub fn screenSize(cfg_w: i32, cfg_h: i32) Size {
    return switch (builtin.os.tag) {
        .windows => blk: {
            const s = native.screenSize(cfg_w, cfg_h);
            break :blk .{ .w = s.w, .h = s.h };
        },
        else => .{ .w = cfg_w, .h = cfg_h },
    };
}

pub const Backend = union(enum) {
    dry,
    native: native.Backend,

    pub fn init(opts: Options) !Backend {
        if (opts.dry_run) return .dry;
        // Linux takes an extra field (XTEST vs uinput); Windows does not.
        switch (builtin.os.tag) {
            .linux => return .{ .native = try native.Backend.init(.{
                .device_name = opts.device_name,
                .screen_width = opts.screen_width,
                .screen_height = opts.screen_height,
                .try_xtest = opts.try_xtest,
            }) },
            else => return .{ .native = try native.Backend.init(.{
                .device_name = opts.device_name,
                .screen_width = opts.screen_width,
                .screen_height = opts.screen_height,
            }) },
        }
    }

    pub fn deinit(self: *Backend) void {
        switch (self.*) {
            .dry => {},
            .native => |*b| b.deinit(),
        }
    }

    /// Release every key and button — a blanket "unstick" emitted when control
    /// ends abruptly (client disconnect, shutdown, or a crash signal), so a held
    /// modifier like Ctrl is never left pressed on this machine. A key-up for a
    /// key that isn't down is a harmless no-op, so no per-key bookkeeping is
    /// needed. Best-effort: errors are swallowed (it may run from a signal
    /// handler).
    pub fn releaseAll(self: *Backend) void {
        switch (self.*) {
            .dry => {},
            .native => |*b| b.releaseAll(),
        }
    }

    /// A human-readable name for the active backend, for logging.
    pub fn describe(self: *const Backend) []const u8 {
        switch (self.*) {
            .dry => return "dry-run",
            .native => |*b| {
                if (builtin.os.tag == .linux) return b.name();
                return "SendInput";
            },
        }
    }

    /// Carry out a parsed command. Returns an error if the backend rejects it
    /// (unknown key/button) or the underlying device fails.
    pub fn execute(self: *Backend, logger: *log.Logger, cmd: protocol.Command) !void {
        switch (cmd) {
            .mouse => |m| {
                logger.debug("mouse move to ({d}, {d})", .{ m.x, m.y });
                switch (self.*) {
                    .dry => {},
                    .native => |*b| try b.mouseMove(m.x, m.y),
                }
            },
            .place => |m| {
                // Same effect as `mouse` (absolute move); the acknowledgement is
                // sent by the server loop, not the backend.
                logger.debug("place pointer at ({d}, {d})", .{ m.x, m.y });
                switch (self.*) {
                    .dry => {},
                    .native => |*b| try b.mouseMove(m.x, m.y),
                }
            },
            .move => |m| {
                logger.debug("mouse move by ({d}, {d})", .{ m.dx, m.dy });
                switch (self.*) {
                    .dry => {},
                    .native => |*b| try b.mouseMoveRelative(m.dx, m.dy),
                }
            },
            .moveto => |m| {
                // Absolute streamed motion during edge switching (no accel).
                logger.debug("mouse move to ({d}, {d})", .{ m.x, m.y });
                switch (self.*) {
                    .dry => {},
                    .native => |*b| try b.mouseMove(m.x, m.y),
                }
            },
            .click => |c| {
                logger.debug("mouse click {s}", .{c.button});
                switch (self.*) {
                    .dry => {},
                    .native => |*b| try b.mouseClick(c.button),
                }
            },
            .key => |k| {
                logger.debug("key stroke: {d} modifier(s) + {s}", .{ k.mods_len, k.key });
                switch (self.*) {
                    .dry => {},
                    .native => |*b| try b.keyCombo(k.modifiers(), k.key),
                }
            },
            .key_down => |k| {
                logger.debug("key down {s}", .{k.key});
                switch (self.*) {
                    .dry => {},
                    .native => |*b| try b.keyDown(k.key),
                }
            },
            .key_up => |k| {
                logger.debug("key up {s}", .{k.key});
                switch (self.*) {
                    .dry => {},
                    .native => |*b| try b.keyUp(k.key),
                }
            },
            .button_down => |c| {
                logger.debug("button down {s}", .{c.button});
                switch (self.*) {
                    .dry => {},
                    .native => |*b| try b.buttonDown(c.button),
                }
            },
            .button_up => |c| {
                logger.debug("button up {s}", .{c.button});
                switch (self.*) {
                    .dry => {},
                    .native => |*b| try b.buttonUp(c.button),
                }
            },
            .scroll => |s| {
                logger.debug("scroll ({d}, {d})", .{ s.dx, s.dy });
                switch (self.*) {
                    .dry => {},
                    .native => |*b| try b.scroll(s.dx, s.dy),
                }
            },
            // Cursor visibility and the shared clipboard are handled by the
            // server, not the input backend (see Server.apply / eventLoop).
            .hide => {},
            .clipboard => {},
        }
    }
};
