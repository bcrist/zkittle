path: []const u8,
source: []const u8,
tokens: Token.List,

const Source = @This();

pub fn init_buf(allocator: std.mem.Allocator, path: []const u8, source: []const u8) !Source {
    const path_copy = try allocator.dupe(u8, path);
    errdefer allocator.free(path_copy);

    const source_copy = try allocator.dupe(u8, source);
    errdefer allocator.free(source_copy);

    const tokens = try Token.lex(allocator, source_copy);

    return .{
        .path = path_copy,
        .source = source_copy,
        .tokens = tokens,
    };
}

pub fn init_file(allocator: std.mem.Allocator, dir: std.fs.Dir, path: []const u8) !Source {
    const realpath = try dir.realpathAlloc(allocator, path);
    errdefer allocator.free(realpath);

    const stat = try dir.statFile(realpath);
    const source = try dir.readFileAllocOptions(allocator, realpath, 1_000_000_000, stat.size, 1, null);
    errdefer allocator.free(source);

    const tokens = try Token.lex(allocator, source);

    return .{
        .path = realpath,
        .source = source,
        .tokens = tokens,
    };
}

pub fn deinit(self: *Source, allocator: std.mem.Allocator) void {
    allocator.free(self.path);
    allocator.free(self.source);
    self.tokens.deinit(allocator);
}

pub fn report_error(self: Source, token: usize, desc: []const u8) !void {
    const span = self.tokens.spans[token];

    var buf: [64]u8 = undefined;
    var stderr = std.fs.File.stderr().writer(&buf);

    try console.print_context(self.source, &.{
        .{
            .offset = @intFromPtr(span.ptr) - @intFromPtr(self.source.ptr),
            .len = span.len,
            .note = desc,
        },
    }, &stderr.interface, 160, .{
        .filename = self.path,
    });

    try stderr.interface.flush();
}
pub fn report_error_2(self: Source, token: usize, desc: []const u8, token2: usize, desc2: []const u8) !void {
    const span = self.tokens.spans[token];
    const span2 = self.tokens.spans[token2];

    var buf: [64]u8 = undefined;
    var stderr = std.fs.File.stderr().writer(&buf);

    try console.print_context(self.source, &.{
        .{
            .offset = @intFromPtr(span.ptr) - @intFromPtr(self.source.ptr),
            .len = span.len,
            .note = desc,
        },
        .{
            .offset = @intFromPtr(span2.ptr) - @intFromPtr(self.source.ptr),
            .len = span2.len,
            .note = desc2,
        },
    }, &stderr.interface, 160, .{
        .filename = self.path,
    });

    try stderr.interface.flush();
}

const Token = @import("Token.zig");
const console = @import("console");
const std = @import("std");