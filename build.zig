const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ---- Executable ---------------------------------------------------------
    const exe = b.addExecutable(.{
        .name = "qr",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            // Strip debug info in release builds (keeps it for Debug); this is
            // what drops a release binary from multi-MB to a few hundred KB.
            .strip = optimize != .Debug,
        }),
    });
    b.installArtifact(exe);

    // ---- `zig build run -- ...` ---------------------------------------------
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the qr CLI");
    run_step.dependOn(&run_cmd.step);

    // ---- `zig build test` ---------------------------------------------------
    // main.zig pulls every module into the test graph (see its `test` block),
    // so a single test artifact rooted there discovers all inline tests.
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
