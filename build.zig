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
        .root_source_file = b.path("src/bin/tui_runtime.zig"),
        .target = target,
        .optimize = optimize,
    });
    tui_runtime_mod.addImport("tui", tui_mod);

    const tui_runtime = b.addExecutable(.{
        .name = "tui_runtime",
        .root_module = tui_runtime_mod,
    });

    const backend_demo_mod = b.createModule(.{
        .root_source_file = b.path("src/bin/backend_demo.zig"),
        .target = target,
        .optimize = optimize,
    });
    backend_demo_mod.addImport("tui", tui_mod);

    const backend_demo = b.addExecutable(.{
        .name = "backend_demo",
        .root_module = backend_demo_mod,
    });

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

    const tests = b.addTest(.{ .root_module = tests_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
