const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const tui_mod = b.createModule(.{
        .root_source_file = b.path("src/lib/tui.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tui_runtime_mod = b.createModule(.{
        .root_source_file = b.path("src/bin/runtime/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    tui_runtime_mod.addImport("tui", tui_mod);

    const tui_runtime = b.addExecutable(.{
        .name = "tui_runtime",
        .root_module = tui_runtime_mod,
    });
    if (target.result.os.tag == .windows) {
        tui_runtime.linkSystemLibrary("user32");
    }

    const backend_demo_mod = b.createModule(.{
        .root_source_file = b.path("src/bin/demo/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    backend_demo_mod.addImport("tui", tui_mod);

    const backend_demo = b.addExecutable(.{
        .name = "backend_demo",
        .root_module = backend_demo_mod,
    });
    if (target.result.os.tag == .windows) {
        backend_demo.linkSystemLibrary("user32");
    }

    b.installArtifact(tui_runtime);
    b.installArtifact(backend_demo);

    const demo_step = b.step("demo", "Run tracer demo: patch -> render -> key -> patch");
    const demo_cmd = b.addRunArtifact(tui_runtime);
    demo_cmd.step.dependOn(b.getInstallStep());
    demo_cmd.addArgs(&.{ "--cmd", "backend_demo" });
    demo_step.dependOn(&demo_cmd.step);

    const tests_mod = b.createModule(.{
        .root_source_file = b.path("src/test/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests_mod.addImport("tui", tui_mod);
    const runtime_ui_mod = b.createModule(.{
        .root_source_file = b.path("src/bin/runtime/ui_test_api.zig"),
        .target = target,
        .optimize = optimize,
    });
    runtime_ui_mod.addImport("tui", tui_mod);
    tests_mod.addImport("runtime_ui", runtime_ui_mod);

    const tests = b.addTest(.{ .root_module = tests_mod });
    const run_tests = b.addRunArtifact(tests);
    if (b.args) |args| run_tests.addArgs(args);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/test/bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_mod.addImport("tui", tui_mod);
    const bench_exe = b.addExecutable(.{
        .name = "tui_bench",
        .root_module = bench_mod,
    });
    const run_bench = b.addRunArtifact(bench_exe);
    if (b.args) |args| run_bench.addArgs(args);
    const bench_step = b.step("bench", "Run synthetic performance benchmarks");
    bench_step.dependOn(&run_bench.step);
}
