const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const tui_runtime = b.addExecutable(.{
        .name = "tui_runtime",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tui_runtime.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const backend_demo = b.addExecutable(.{
        .name = "backend_demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/backend_demo.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(tui_runtime);
    b.installArtifact(backend_demo);

    const demo_step = b.step("demo", "Run tracer demo: patch -> render -> key -> patch");
    const demo_cmd = b.addRunArtifact(tui_runtime);
    demo_cmd.step.dependOn(b.getInstallStep());
    demo_cmd.addArgs(&.{ "--cmd", "backend_demo" });
    demo_step.dependOn(&demo_cmd.step);
}
