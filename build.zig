const std = @import("std");

pub fn build(b: *std.Build) void {
    const ext = .{
        .console = b.dependency("console_helper", .{}).module("console"),
        .percent_encoding = b.dependency("percent_encoding", .{}).module("percent_encoding"),
    };


    const module = b.addModule("zkittle", .{
        .root_source_file = b.path("src/Template.zig"),
    });
    module.addImport("console", ext.console);
    module.addImport("percent_encoding", ext.percent_encoding);

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const tests = b.addTest(.{
        .root_source_file = b.path("tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests.root_module.addImport("console", ext.console);
    tests.root_module.addImport("percent_encoding", ext.percent_encoding);
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_tests.step);


    const test_exe = b.addExecutable(.{
        .name = "testexe",
        .root_source_file = b.path("tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_exe.root_module.addImport("console", ext.console);
    test_exe.root_module.addImport("percent_encoding", ext.percent_encoding);
    const run_test_exe = b.addRunArtifact(test_exe);
    const test_exe_step = b.step("testexe", "Run test executable");
    test_exe_step.dependOn(&run_test_exe.step);
}
