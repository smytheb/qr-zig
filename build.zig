const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ---- Library module -----------------------------------------------------
    // The reusable `qr` library (encode + render + decode). Downstream projects
    // consume it via `b.dependency("qr", .{...}).module("qr")`;
    const qr_mod = b.addModule("qr", .{
        .root_source_file = b.path("src/root.zig"),
    });

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
            .imports = &.{.{ .name = "qr", .module = qr_mod }},
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
    // Two artifacts mirror the module boundary: the library (rooted at the
    // public module surface) and the CLI (rooted at main.zig, which imports the
    // library as `qr`). The library root pulls every qr/render/decode module
    // into its test graph; main.zig carries only its own integration tests.
    const test_step = b.step("test", "Run unit tests");

    const lib_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);

    const cli_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "qr", .module = qr_mod }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(cli_tests).step);

    // ---- `zig build bench` --------------------------------------------------
    // Encode/decode micro-benchmarks. Always built ReleaseFast so the numbers
    // mean something regardless of the optimize flag passed to `zig build`.
    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "qr", .module = qr_mod }},
        }),
    });
    const bench_run = b.addRunArtifact(bench_exe);
    if (b.args) |args| bench_run.addArgs(args);
    const bench_step = b.step("bench", "Run encode/decode micro-benchmarks (ReleaseFast)");
    bench_step.dependOn(&bench_run.step);

    // ---- `zig build examples` ----------------------------------------------
    // Build and run each example as a standalone consumer of the `qr` module,
    // so the README snippets cannot rot.
    const examples_step = b.step("examples", "Build and run the library examples");
    for ([_][]const u8{
        "encode_svg",
        "decode_roundtrip",
    }) |name| {
        const ex = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "qr", .module = qr_mod }},
            }),
        });
        examples_step.dependOn(&b.addRunArtifact(ex).step);
    }
}
