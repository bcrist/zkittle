
pub fn none(str: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll(str);
}

pub fn html(str: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
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

pub fn url(str: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    var iter = percent_encoding.encode(str, .default);
    while (iter.next()) |chunk| {
        try w.writeAll(chunk);
    }
}

pub const Fn = fn(str: []const u8, writer: *std.Io.Writer) std.Io.Writer.Error!void;

pub const Writer = struct {
    interface: std.Io.Writer,
    out: *std.Io.Writer,
    escape_fn: *const Fn,

    pub fn init(out: *std.Io.Writer, buffer: []u8, func: *const Fn) Writer {
        return .{
            .interface = .{
                .buffer = buffer,
                .vtable = &.{ .drain = drain },
            },
            .out = out,
            .escape_fn = func,
        };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Writer = @fieldParentPtr("interface", w);

        var written_bytes: usize = 0;

        try self.escape_fn(w.buffered(), self.out);
        written_bytes += w.end;
        w.end = 0;

        if (data.len > 1) for (data[0 .. data.len - 1]) |chunk| {
            try self.escape_fn(chunk, self.out);
            written_bytes += chunk.len;
        };

        std.debug.assert(data.len != 0);

        const chunk = data[data.len - 1];
        if (splat > 1 and chunk.len < 128) {
            var temp_buf: [128]u8 = undefined;
            var temp = std.Io.Writer.fixed(&temp_buf);
            if (self.escape_fn(chunk, &temp)) {
                const escaped_chunk = temp.buffered();
                var d = [_][]const u8 { escaped_chunk };
                try self.out.writeSplatAll(&d, splat);
                written_bytes += escaped_chunk.len * splat;
                return written_bytes;
            } else |_| {} // insufficient space, presumably.  Fall through to passing self.out directly
        }

        for (0..splat) |_| {
            try self.escape_fn(chunk, self.out);
            written_bytes += chunk.len;
        }

        return written_bytes;
    }
};

pub fn writer(out: *std.Io.Writer, buffer: []u8, escape_fn: *const Fn) Writer {
    return .init(out, buffer, escape_fn);
}

const percent_encoding = @import("percent_encoding");
const std = @import("std");
