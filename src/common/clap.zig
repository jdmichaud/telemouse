// A very simple command line argument parser.
//
// This is a port of the `clap` parser from https://github.com/jdmichaud/zig-utils
// adapted to the reorganized `std` of Zig 0.17-dev. The public surface
// (`ArgDescriptor`, `OptionDescription`, `parser(...).parse(...)`) is kept
// identical so the original usage documentation still applies:
//
// ```zig
// const parsed = clap.parser(clap.ArgDescriptor{
//   .name = "tms",
//   .description = "The telemouse server",
//   .version = "0.1.0",
//   .options = &[_]clap.OptionDescription{ .{
//     .short = "p",
//     .long = "port",
//     .arg = .{ .name = "port", .type = []const u8 },
//     .help = "Port to listen on",
//   } },
// }).parse(args);
//
// const port = try parsed.getOption(u16, "port");
// const verbose = parsed.getSwitch("verbose");
// ```
//
// Differences from the upstream version:
//   * Help / usage / error text is written to stderr via `std.debug.print`
//     (the previous `std.io.getStdOut()` writer no longer exists).
//   * `std.posix.exit` became `std.process.exit`.
//   * `parse` accepts `[]const [:0]const u8` to match `std.process.Init`'s
//     argument slice.
//   * Arguments are always parsed, even when `withHelp` is false.

const std = @import("std");

pub const OptionDescription = struct {
  short: ?[]const u8,
  long: []const u8,
  arg: ?struct { name: []const u8, type: type } = null,
  help: []const u8,
};

pub const ArgDescriptor = struct {
  bufferSize: usize = 4096,
  name: []const u8,
  description: ?[]const u8 = null,
  withHelp: bool = true,
  version: ?[]const u8 = null,
  expectArgs: []const []const u8 = &[_][]const u8{},
  minNbArgs: usize = 0,
  options: []const OptionDescription,
};

pub fn printUsage(allocator: std.mem.Allocator, comptime argsDescriptor: ArgDescriptor) void {
  const args_str = if (argsDescriptor.expectArgs.len > 0) blk: {
    const joined = std.mem.join(allocator, " ", argsDescriptor.expectArgs)
      catch @panic("increase buffer size");
    break :blk std.fmt.allocPrint(allocator, " {s}", .{joined})
      catch @panic("increase buffer size");
  } else "";
  std.debug.print("Usage: {s}{s}{s}\n", .{
    argsDescriptor.name,
    if (argsDescriptor.options.len > 0) " [OPTIONS]" else "",
    args_str,
  });
}

pub fn printHelp(allocator: std.mem.Allocator, comptime argsDescriptor: ArgDescriptor) void {
  std.debug.print("{s}{s} {s}\n\n", .{
    argsDescriptor.name,
    if (argsDescriptor.version) |version| " (" ++ version ++ ")" else "",
    argsDescriptor.description orelse "",
  });
  printUsage(allocator, argsDescriptor);
  std.debug.print("\nOptions:\n", .{});
  inline for (argsDescriptor.options) |option| {
    var buffer: [argsDescriptor.bufferSize]u8 = undefined;
    const printed = std.fmt.bufPrint(&buffer, "    {s}{s}{s}", .{
      if (option.short) |short| "-" ++ short ++ "," else "   ",
      "--" ++ option.long,
      if (option.arg) |arg| " " ++ arg.name else "",
    }) catch @panic("increase buffer size");
    if (printed.len > 23) {
      std.debug.print("{s}\n                         {s}\n", .{ printed, option.help });
    } else {
      std.debug.print("{s: <24} {s}\n", .{ printed, option.help });
    }
  }
}

pub const Args = struct {
  const Self = @This();

  switchMap: std.StringHashMap(bool),
  optionMap: std.StringHashMap([]const u8),
  arguments: std.ArrayList([]const u8),

  pub fn getSwitch(self: Self, name: []const u8) bool {
    return self.switchMap.get(name) orelse false;
  }

  pub fn getOption(self: Self, comptime T: type, name: []const u8) !?T {
    switch (T) {
      []const u8 => return self.optionMap.get(name),
      u8, i8, u16, i16, u32, i32, i64, u64, usize => {
        if (self.optionMap.get(name)) |value| {
          return try std.fmt.parseInt(T, value, 10);
        }
        return null;
      },
      else => @compileError(std.fmt.comptimePrint(
        "getOption: unsupported type {}",
        .{T},
      )),
    }
  }
};

pub fn parser(argsDescriptor: ArgDescriptor) type {
  return struct {
    var buffer: [argsDescriptor.bufferSize]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = fba.allocator();
    var argsStore = Args{
      .switchMap = std.StringHashMap(bool).init(allocator),
      .optionMap = std.StringHashMap([]const u8).init(allocator),
      .arguments = .empty,
    };

    pub fn parse(args: []const [:0]const u8) Args {
      if (argsDescriptor.withHelp) {
        for (args) |arg| {
          if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printHelp(allocator, argsDescriptor);
            std.process.exit(0);
          }
        }
      }
      if (argsDescriptor.version) |version| {
        for (args) |arg| {
          if (std.mem.eql(u8, arg, "--version")) {
            std.debug.print("{s} {s}\n", .{ argsDescriptor.name, version });
            std.process.exit(0);
          }
        }
      }

      var i: usize = 1;
      while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (arg.len > 0 and arg[0] == '-') {
          // Handle option. `i` may be incremented further if the option
          // expects an argument.
          inline for (argsDescriptor.options) |option| {
            if ((option.short != null and std.mem.eql(u8, arg[1..], option.short.?)) or
              (arg.len >= 2 and std.mem.eql(u8, arg[2..], option.long)))
            {
              argsStore.switchMap.put(option.long, true)
                catch @panic("increase buffer size");
              if (option.arg != null) {
                // The option expects an argument.
                if (i >= args.len - 1 or (args[i + 1].len > 0 and args[i + 1][0] == '-')) {
                  std.debug.print("error: option {s} expected an argument\n", .{arg});
                  printUsage(allocator, argsDescriptor);
                  std.process.exit(1);
                }
                argsStore.optionMap.put(option.long, args[i + 1])
                  catch @panic("increase buffer size");
                i += 1;
              }
              break;
            }
          } else {
            std.debug.print("error: unknown option {s}\n", .{arg});
            printUsage(allocator, argsDescriptor);
            std.process.exit(1);
          }
        } else {
          argsStore.arguments.append(allocator, args[i]) catch @panic("increase buffer size");
        }
      }

      if ((argsDescriptor.minNbArgs != 0 and argsStore.arguments.items.len < argsDescriptor.minNbArgs) or
        (argsDescriptor.minNbArgs == 0 and argsStore.arguments.items.len != argsDescriptor.expectArgs.len))
      {
        std.debug.print("error: incorrect number of arguments. Expected {d}, got {d}.\n", .{
          argsDescriptor.expectArgs.len, argsStore.arguments.items.len,
        });
        printUsage(allocator, argsDescriptor);
        std.process.exit(1);
      }
      return argsStore;
    }
  };
}
