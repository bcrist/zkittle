const std = @import("std");

pub fn build(b: *std.Build) void {
    const module = b.addModule("zkittle", .{
        .root_source_file = .{ .path = "src/Template.zig" },
    });
    module.addImport("console", b.dependency("Zig-ConsoleHelper", .{}).module("console"));

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const tests = b.addTest(.{
        .root_source_file = .{ .path = "tests.zig"},
        .target = target,
        .optimize = optimize,
    });
    tests.root_module.addImport("console", b.dependency("Zig-ConsoleHelper", .{}).module("console"));
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_tests.step);


    const test_exe = b.addExecutable(.{
        .name = "testexe",
        .root_source_file = .{ .path = "tests.zig"},
        .target = target,
        .optimize = optimize,
    });
    test_exe.root_module.addImport("console", b.dependency("Zig-ConsoleHelper", .{}).module("console"));
    const run_test_exe = b.addRunArtifact(test_exe);
    const test_exe_step = b.step("testexe", "Run test executable");
    test_exe_step.dependOn(&run_test_exe.step);
}
