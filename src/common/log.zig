// Logging facility shared by `tms` and `tmc`.
//
// A `Logger` filters messages by `Level` and writes them to one of three
// destinations: standard output (the default), a file (opened in append mode)
// or the system logger. Syslog is only available on platforms that provide a
// `/dev/log` datagram socket (Linux); requesting it elsewhere fails at
// startup with `error.Unsupported`.
//
// By design the tools are quiet: the default level is `.info`, which is
// reserved for major announcements (e.g. "server listening"). Per-command
// activity is logged at `.debug`. Levels are ordered by decreasing severity;
// a message is emitted when its level is at least as severe as the configured
// level. The `.silent` level suppresses everything.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const File = std.Io.File;

pub const Level = enum(u8) {
    silent = 0,
    err = 1,
    warn = 2,
    info = 3,
    debug = 4,

    pub fn parse(s: []const u8) ?Level {
        const map = std.StaticStringMap(Level).initComptime(.{
            .{ "silent", .silent },
            .{ "error", .err },
            .{ "err", .err },
            .{ "warn", .warn },
            .{ "warning", .warn },
            .{ "info", .info },
            .{ "debug", .debug },
        });
        return map.get(s);
    }

    fn tag(self: Level) []const u8 {
        return switch (self) {
            .silent => "SILENT",
            .err => "ERROR",
            .warn => "WARN",
            .info => "INFO",
            .debug => "DEBUG",
        };
    }

    // RFC 5424 severity code, used to build the syslog priority value.
    fn syslogSeverity(self: Level) u8 {
        return switch (self) {
            .silent => 5,
            .err => 3,
            .warn => 4,
            .info => 6,
            .debug => 7,
        };
    }
};

const Destination = union(enum) {
    stream: File,
    file: File,
    syslog: i32,
};

pub const InitError = error{
    OpenFailed,
    Unsupported,
    SyslogUnavailable,
};

pub const Logger = struct {
    io: Io,
    level: Level,
    dest: Destination,
    name: []const u8,
    file_offset: u64 = 0,

    pub fn initStdout(io: Io, level: Level, name: []const u8) Logger {
        return .{ .io = io, .level = level, .dest = .{ .stream = File.stdout() }, .name = name };
    }

    pub fn initFile(io: Io, level: Level, name: []const u8, path: []const u8) InitError!Logger {
        const file = Io.Dir.cwd().createFile(io, path, .{ .truncate = false }) catch
            return error.OpenFailed;
        const offset: u64 = if (file.stat(io)) |st| st.size else |_| 0;
        return .{
            .io = io,
            .level = level,
            .dest = .{ .file = file },
            .name = name,
            .file_offset = offset,
        };
    }

    pub fn initSyslog(io: Io, level: Level, name: []const u8) InitError!Logger {
        if (builtin.os.tag != .linux) return error.Unsupported;
        const linux = std.os.linux;
        const sock = linux.socket(linux.AF.UNIX, linux.SOCK.DGRAM, 0);
        if (linux.errno(sock) != .SUCCESS) return error.SyslogUnavailable;
        const fd: i32 = @intCast(sock);

        var addr: linux.sockaddr.un = .{ .path = undefined };
        @memset(&addr.path, 0);
        const dev_log = "/dev/log";
        @memcpy(addr.path[0..dev_log.len], dev_log);

        const crc = linux.connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.un));
        if (linux.errno(crc) != .SUCCESS) {
            _ = linux.close(fd);
            return error.SyslogUnavailable;
        }
        return .{ .io = io, .level = level, .dest = .{ .syslog = fd }, .name = name };
    }

    /// Build a logger for a single destination, falling back to stdout (with a
    /// warning on stderr) if the requested destination cannot be opened.
    /// Precedence when both are requested: syslog over file.
    pub fn fromChoice(
        io: Io,
        level: Level,
        name: []const u8,
        use_syslog: bool,
        log_file: ?[]const u8,
    ) Logger {
        if (use_syslog) {
            return initSyslog(io, level, name) catch |e| {
                std.debug.print("warning: cannot use syslog ({s}); logging to stdout\n", .{@errorName(e)});
                return initStdout(io, level, name);
            };
        }
        if (log_file) |path| {
            return initFile(io, level, name, path) catch |e| {
                std.debug.print("warning: cannot open log file {s} ({s}); logging to stdout\n", .{ path, @errorName(e) });
                return initStdout(io, level, name);
            };
        }
        return initStdout(io, level, name);
    }

    pub fn deinit(self: *Logger) void {
        switch (self.dest) {
            .stream => {},
            .file => |f| f.close(self.io),
            .syslog => |fd| if (builtin.os.tag == .linux) {
                _ = std.os.linux.close(fd);
            },
        }
    }

    pub fn err(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.emit(.err, fmt, args);
    }
    pub fn warn(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.emit(.warn, fmt, args);
    }
    pub fn info(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.emit(.info, fmt, args);
    }
    pub fn debug(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.emit(.debug, fmt, args);
    }

    fn emit(self: *Logger, msg_level: Level, comptime fmt: []const u8, args: anytype) void {
        if (@intFromEnum(msg_level) > @intFromEnum(self.level)) return;

        var buffer: [2048]u8 = undefined;
        switch (self.dest) {
            .stream => |f| {
                const line: []const u8 = std.fmt.bufPrint(
                    &buffer,
                    "{s}: " ++ fmt ++ "\n",
                    .{msg_level.tag()} ++ args,
                ) catch truncated(&buffer);
                f.writeStreamingAll(self.io, line) catch {};
            },
            .file => |f| {
                const line: []const u8 = std.fmt.bufPrint(
                    &buffer,
                    "{s}: " ++ fmt ++ "\n",
                    .{msg_level.tag()} ++ args,
                ) catch truncated(&buffer);
                f.writePositionalAll(self.io, line, self.file_offset) catch return;
                self.file_offset += line.len;
            },
            .syslog => |fd| {
                const pri: u8 = 8 + msg_level.syslogSeverity();
                const line: []const u8 = std.fmt.bufPrint(
                    &buffer,
                    "<{d}>{s}[{d}]: " ++ fmt,
                    .{ pri, self.name, syslogPid() } ++ args,
                ) catch truncated(&buffer);
                writeFd(fd, line);
            },
        }
    }
};

fn truncated(buffer: []u8) []const u8 {
    const suffix = "...[truncated]\n";
    @memcpy(buffer[buffer.len - suffix.len ..], suffix);
    return buffer;
}

fn syslogPid() i32 {
    if (builtin.os.tag == .linux) return std.os.linux.getpid();
    return 0;
}

fn writeFd(fd: i32, bytes: []const u8) void {
    if (builtin.os.tag != .linux) return;
    const linux = std.os.linux;
    var index: usize = 0;
    while (index < bytes.len) {
        const rc = linux.write(fd, bytes.ptr + index, bytes.len - index);
        switch (linux.errno(rc)) {
            .SUCCESS => index += @intCast(rc),
            .INTR => continue,
            else => return, // logging must never crash the program
        }
    }
}
