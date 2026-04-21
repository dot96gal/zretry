const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zretry", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const example = b.addExecutable(.{
        .name = "basic_usage",
        .root_module = b.createModule(.{
            .root_source_file = b.path("example/basic.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zretry", .module = mod },
            },
        }),
    });
    const run_example = b.addRunArtifact(example);
    const example_step = b.step("run-example", "Run the basic usage example");
    example_step.dependOn(&run_example.step);

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    const docs_obj = b.addObject(.{
        .name = "zretry",
        .root_module = mod,
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_obj.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate API documentation");
    docs_step.dependOn(&install_docs.step);
}
