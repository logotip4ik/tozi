const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const tlsDep = b.dependency("tls", .{
        .target = target,
        .optimize = optimize,
    });

    const hasherMod = b.addModule("hasher", .{
        .root_source_file = b.path("src/hasher.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .single_threaded = true,
        .strip = true,
    });

    const utilsMod = b.addModule("utils", .{
        .root_source_file = b.path("src/utils.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });

    const toziMod = b.addModule("tozi", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "hasher", .module = hasherMod },
            .{ .name = "utils", .module = utilsMod },
            .{ .name = "tls", .module = tlsDep.module("tls") },
        },
    });

    const exeOpts = std.Build.ExecutableOptions{
        .name = "tozi",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "tozi", .module = toziMod },
            },
        }),
    };

    const exe = b.addExecutable(exeOpts);
    b.installArtifact(exe);

    const checkExe = b.addExecutable(exeOpts);
    const checkMod = b.addLibrary(.{
        .name = "libtozi",
        .root_module = toziMod,
    });
    const checkStep = b.step("check", "Run check on exe");
    checkStep.dependOn(&checkExe.step);
    checkStep.dependOn(&checkMod.step);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_mod_tests = b.addRunArtifact(b.addTest(.{ .root_module = toziMod }));

    const utils_tests = b.addRunArtifact(b.addTest(.{ .root_module = utilsMod }));
    run_mod_tests.step.dependOn(&utils_tests.step);

    const run_exe_tests = b.addRunArtifact(b.addTest(.{ .root_module = exe.root_module }));

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
