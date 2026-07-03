const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ---- tms: the server -------------------------------------------------
    const tms = b.addExecutable(.{
        .name = "tms",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tms.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // The Windows input backend calls SendInput / SetCursorPos from user32;
    // the mDNS responder uses ws2_32 for its raw multicast socket.
    if (target.result.os.tag == .windows) {
        tms.root_module.linkSystemLibrary("user32", .{});
        tms.root_module.linkSystemLibrary("ws2_32", .{});
    }
    // On Linux the server uses Xlib + XFixes to place the cursor (XWarpPointer)
    // and watch it reach an edge.
    if (target.result.os.tag == .linux) {
        tms.root_module.link_libc = true;
        tms.root_module.linkSystemLibrary("X11", .{});
        tms.root_module.linkSystemLibrary("Xfixes", .{});
    }
    b.installArtifact(tms);

    // ---- tmc: the client -------------------------------------------------
    const tmc = b.addExecutable(.{
        .name = "tmc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tmc.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // The Windows edge-switch capture installs low-level hooks from user32;
    // the config UI window blits via gdi32/StretchDIBits.
    if (target.result.os.tag == .windows) {
        tmc.root_module.linkSystemLibrary("user32", .{});
        tmc.root_module.linkSystemLibrary("gdi32", .{});
    }
    // The Linux config UI window uses Xlib (XPutImage) to blit the framebuffer;
    // the edge-switch client uses Xlib + XFixes to track/hide the cursor and
    // Xi (XInput2) for the no-permissions capture backend on X11.
    if (target.result.os.tag == .linux) {
        tmc.root_module.link_libc = true;
        tmc.root_module.linkSystemLibrary("X11", .{});
        tmc.root_module.linkSystemLibrary("Xfixes", .{});
        tmc.root_module.linkSystemLibrary("Xi", .{});
    }
    b.installArtifact(tmc);

    // ---- run steps -------------------------------------------------------
    const run_tms = b.addRunArtifact(tms);
    run_tms.step.dependOn(b.getInstallStep());
    run_tms.addPassthruArgs();
    b.step("run-tms", "Run the server (pass args after --)").dependOn(&run_tms.step);

    const run_tmc = b.addRunArtifact(tmc);
    run_tmc.step.dependOn(b.getInstallStep());
    run_tmc.addPassthruArgs();
    b.step("run-tmc", "Run the client (pass args after --)").dependOn(&run_tmc.step);

    // ---- tests -----------------------------------------------------------
    const test_step = b.step("test", "Run unit tests");
    const test_files = [_][]const u8{
        "src/common/protocol.zig",
        "src/common/keymap.zig",
        "src/common/log.zig",
        "src/common/dns.zig",
        "src/common/mdns.zig",
        "src/common/clipboard.zig",
        "src/tmc/switcher.zig",
        "src/tmc/keysyms.zig",
        "src/tms_test.zig",
        "src/session_test.zig",
        "src/ui/font.zig",
        "src/ui/classic.zig",
        "src/ui/canvas.zig",
        "src/ui/marlett.zig",
        "src/configui_test.zig",
    };
    for (test_files) |path| {
        const mod = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        });
        // configui pulls in the platform window layer (Xlib on Linux).
        if (std.mem.eql(u8, path, "src/configui_test.zig") and target.result.os.tag == .linux) {
            mod.link_libc = true;
            mod.linkSystemLibrary("X11", .{});
        }
        const t = b.addTest(.{ .root_module = mod });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
