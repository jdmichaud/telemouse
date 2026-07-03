// Generic ZON configuration loading shared by tms and tmc.
//
// The configuration lives under the XDG config directory in a per-program
// file: `$XDG_CONFIG_HOME/telemouse/<basename>` when `XDG_CONFIG_HOME` is set,
// otherwise `~/.config/telemouse/<basename>` (`%APPDATA%\telemouse\<basename>`
// on Windows). A different path can be supplied explicitly.
//
// `load` parses the file into the caller-provided struct type `T`; every field
// of `T` should have a default so that a missing file yields the defaults.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Environ = std.process.Environ;

pub const LoadError = error{
    InvalidConfig,
    ReadFailed,
    OutOfMemory,
};

pub fn Loaded(comptime T: type) type {
    return struct {
        config: T,
        /// Path the configuration was (or would have been) read from.
        path: []const u8,
        /// True when the file existed and was parsed.
        loaded: bool,
    };
}

/// Resolve the config path, read it if present and parse it into `T`.
/// `explicit_path`, when non-null, overrides the default XDG location.
/// Allocations use `arena` (never freed individually).
pub fn load(
    comptime T: type,
    io: Io,
    arena: std.mem.Allocator,
    env: *const Environ.Map,
    basename: []const u8,
    explicit_path: ?[]const u8,
) LoadError!Loaded(T) {
    const path = if (explicit_path) |p|
        p
    else
        defaultPath(arena, env, basename) catch return error.OutOfMemory;

    const source = Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        arena,
        .limited(1 << 20),
        .of(u8),
        0,
    ) catch |e| switch (e) {
        error.FileNotFound => {
            if (explicit_path != null) {
                std.debug.print("error: config file not found: {s}\n", .{path});
                return error.ReadFailed;
            }
            return .{ .config = .{}, .path = path, .loaded = false };
        },
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            std.debug.print("error: cannot read config file {s}: {s}\n", .{ path, @errorName(e) });
            return error.ReadFailed;
        },
    };

    var diag: std.zon.parse.Diagnostics = .{};
    const config = std.zon.parse.fromSliceAlloc(T, arena, source, &diag, .{
        .ignore_unknown_fields = true,
    }) catch {
        std.debug.print("error: invalid config file {s}:\n{f}\n", .{ path, diag });
        return error.InvalidConfig;
    };

    return .{ .config = config, .path = path, .loaded = true };
}

fn defaultPath(arena: std.mem.Allocator, env: *const Environ.Map, basename: []const u8) ![]const u8 {
    if (env.get("XDG_CONFIG_HOME")) |xdg| {
        if (xdg.len > 0) return std.fs.path.join(arena, &.{ xdg, "telemouse", basename });
    }
    if (builtin.os.tag == .windows) {
        if (env.get("APPDATA")) |appdata| {
            return std.fs.path.join(arena, &.{ appdata, "telemouse", basename });
        }
    }
    const home = env.get("HOME") orelse ".";
    return std.fs.path.join(arena, &.{ home, ".config", "telemouse", basename });
}
