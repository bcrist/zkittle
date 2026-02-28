pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ext = .{
        .console = b.dependency("console_helper", .{}).module("console"),
        .percent_encoding = b.dependency("percent_encoding", .{}).module("percent_encoding"),
    };

    _ = b.addModule("zkittle", .{
        .root_source_file = b.path("src/Template.zig"),
        .imports = &.{
            .{ .name = "console", .module = ext.console },
            .{ .name = "percent_encoding", .module = ext.percent_encoding },
        },
    });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "console", .module = ext.console },
                .{ .name = "percent_encoding", .module = ext.percent_encoding },
            },
        }),
    });
    b.step("test", "Run all tests").dependOn(&b.addRunArtifact(tests).step);
}

const std = @import("std");
