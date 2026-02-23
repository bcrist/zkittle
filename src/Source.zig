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

pub fn init_file(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !Source {
    const realpath = dir.realPathFileAlloc(io, path, allocator) catch try allocator.dupe(u8, path);
    errdefer allocator.free(realpath);

    const source = try dir.readFileAllocOptions(io, path, allocator, .limited(1_000_000_000), .@"1", null);
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

pub fn report_error(self: Source, writer: *std.Io.Writer, token: usize, desc: []const u8) !void {
    const span = self.tokens.spans[token];

    try console.print_context(self.source, &.{
        .{
            .offset = @intFromPtr(span.ptr) - @intFromPtr(self.source.ptr),
            .len = span.len,
            .note = desc,
        },
    }, writer, 160, .{
        .filename = self.path,
    });
}
pub fn report_error_2(self: Source, writer: *std.Io.Writer, token: usize, desc: []const u8, token2: usize, desc2: []const u8) !void {
    const span = self.tokens.spans[token];
    const span2 = self.tokens.spans[token2];

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
    }, writer, 160, .{
        .filename = self.path,
    });
}

const Token = @import("Token.zig");
const console = @import("console");
const std = @import("std");