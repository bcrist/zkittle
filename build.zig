const std = @import("std");

pub fn build(b: *std.Build) void {
    const module = b.addModule("zkittle", .{
        .root_source_file = .{ .path = "src/Template.zig" },
    });
    module.addImport("console", b.dependency("Zig-ConsoleHelper", .{}).module("console"));

    const tests = b.addTest(.{
        .root_source_file = .{ .path = "tests.zig"},
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    });
    tests.root_module.addImport("console", b.dependency("Zig-ConsoleHelper", .{}).module("console"));
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_tests.step);
}
