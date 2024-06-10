
pub fn none(str: []const u8, w: std.io.AnyWriter) anyerror!void {
    try w.writeAll(str);
}

pub fn html(str: []const u8, w: std.io.AnyWriter) anyerror!void {
    var iter = std.mem.splitAny(u8, str, "&<>\"'");
    while (iter.next()) |chunk| {
        try w.writeAll(chunk);
        if (iter.index) |i| {
            try w.writeAll(switch (iter.buffer[i-1]) {
                '&' => "&amp;",
                '<' => "&lt;",
                '>' => "&gt;",
                '"' => "&quot;",
                '\'' => "&#39;",
                else => unreachable,
            });
        }
    }
}

pub fn url(str: []const u8, w: std.io.AnyWriter) anyerror!void {
    var iter = percent_encoding.encode(str, .{});
    while (iter.next()) |chunk| {
        try w.writeAll(chunk);
    }
}

pub const Fn = fn(str: []const u8, writer: std.io.AnyWriter) anyerror!void;
const Writer = std.io.GenericWriter(Writer_Context, anyerror, Writer_Context.write);
const Writer_Context = struct {
    inner: std.io.AnyWriter,
    escape_fn: *const Fn,

    pub fn write(self: Writer_Context, bytes: []const u8) anyerror!usize {
        try self.escape_fn(bytes, self.inner);
        return bytes.len;
    }
};

pub fn writer(w: std.io.AnyWriter, escape_fn: *const Fn) Writer {
    return .{ .context = .{
        .inner = w,
        .escape_fn = escape_fn,
    }};
}

const percent_encoding = @import("percent_encoding");
const std = @import("std");
