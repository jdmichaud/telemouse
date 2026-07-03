// Server configuration (see src/common/config.zig for the loading mechanism
// and file location). The file is `telemouse/tms.zon` under the XDG config
// directory. Every field is optional; command-line options override the file.
//
// Example `tms.zon`:
//   .{
//       .addr = "0.0.0.0",
//       .port = 24800,
//       .log_level = "info",
//       .log_file = "/var/log/telemouse.log",
//       .syslog = false,
//       .screen_width = 1920,
//       .screen_height = 1080,
//       .device_name = "telemouse virtual input",
//       .dry_run = false,
//   }

const std = @import("std");
const Io = std.Io;
const Environ = std.process.Environ;
const common = @import("../common/config.zig");

pub const Config = struct {
    addr: []const u8 = "0.0.0.0",
    port: u16 = 24800,
    log_level: []const u8 = "info",
    log_file: ?[]const u8 = null,
    syslog: bool = false,
    screen_width: i32 = 1920,
    screen_height: i32 = 1080,
    device_name: []const u8 = "telemouse virtual input",
    dry_run: bool = false,
    // Linux injection backend: "auto" (XTEST on X11, else uinput), "xtest", or
    // "kernel" (force uinput). Ignored on Windows.
    backend: []const u8 = "auto",
};

pub const LoadError = common.LoadError;
pub const Loaded = common.Loaded(Config);

pub fn load(
    io: Io,
    arena: std.mem.Allocator,
    env: *const Environ.Map,
    explicit_path: ?[]const u8,
) LoadError!Loaded {
    return common.load(Config, io, arena, env, "tms.zon", explicit_path);
}
