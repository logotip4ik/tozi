const std = @import("std");
const build_zig_zon = @import("./build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const tlsDep = b.dependency("tls", .{
        .target = target,
        .optimize = optimize,
    });

    const build_options = b.addOptions();
    build_options.addOption(
        std.SemanticVersion,
        "version",
        std.SemanticVersion.parse(build_zig_zon.version) catch unreachable,
    );

    const build_options_module = build_options.createModule();

    const toziMod = b.addModule("tozi", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "tls", .module = tlsDep.module("tls") },
            .{ .name = "build_options", .module = build_options_module },
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
                .{ .name = "build_options", .module = build_options_module },
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

    const run_exe_tests = b.addRunArtifact(b.addTest(.{ .root_module = exe.root_module }));

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    try addBumpStep(b, target, build_options_module);
}

fn addBumpStep(b: *std.Build, target: std.Build.ResolvedTarget, buildOptions: *std.Build.Module) !void {
    const bump = b.addExecutable(.{
        .name = "bump",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/bump.zig"),
            .target = target,
            .imports = &[_]std.Build.Module.Import{
                .{ .name = "build_options", .module = buildOptions },
            },
        }),
    });

    const runBump = b.addRunArtifact(bump);

    const commits = b.addSystemCommand(&.{
        "git",
        "log",
        "--pretty=format:%s",
        std.fmt.allocPrint(b.allocator, "v{s}..HEAD", .{build_zig_zon.version}) catch unreachable,
    });
    runBump.step.dependOn(&commits.step);

    const generatedBuildZigZon = runBump.addOutputFileArg("build.zig.zon");
    runBump.addFileArg(commits.captureStdOut());
    runBump.addFileArg(b.path("build.zig.zon"));

    const wf = b.addUpdateSourceFiles();
    wf.step.dependOn(&runBump.step);
    wf.addCopyFileToSource(generatedBuildZigZon, "build.zig.zon");

    const gitAdd = b.addSystemCommand(&.{
        "git",
        "add",
        "build.zig.zon",
    });
    gitAdd.step.dependOn(&wf.step);

    const gitCommit = b.addSystemCommand(&.{
        "git",
        "commit",
        "-m chore: bump version",
    });
    gitCommit.step.dependOn(&gitAdd.step);

    const tag = b.addExecutable(.{
        .name = "tag",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/git-tag.zig"),
            .target = target,
        }),
    });
    const runTag = b.addRunArtifact(tag);
    runTag.step.dependOn(&gitCommit.step);
    runTag.addFileArg(runBump.captureStdErr());

    const bumpStep = b.step("bump", "bump package version and commit");
    bumpStep.dependOn(&wf.step);
    bumpStep.dependOn(&runTag.step);
}
