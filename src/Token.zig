kind: Kind,
span: []const u8,

const min_interned_literal_length = 15;

const Token = @This();

pub const List = struct {
    kinds: []const Kind,
    spans: [*]const []const u8,

    pub fn deinit(self: List, allocator: std.mem.Allocator) void {
        allocator.free(self.spans[0..self.kinds.len]);
        allocator.free(self.kinds);
    }

    pub fn get(self: List, token: usize) Token {
        return .{
            .kind = self.kinds[token],
            .span = self.spans[token],
        };
    }
};

pub const Kind = enum (u8) {
    eof = 0,
    invalid,
    literal,
    id,
    string_literal,
    number,
    kw_resource,
    kw_include,
    kw_raw,
    kw_index,
    kw_exists,
    kw_url,
    kw_count,
    condition,      // ?
    within,         // : (when followed by whitespace or end of command block)
    fn_call,        // : (when not followed by whitespace or end of command block)
    otherwise,      // ;
    end,            // ~
    parent,         // ^
    child,          // .
    fragment,       // #
    self,           // *
    fallback,       // |
    alternative,    // /
    open_paren,     // (
    close_paren,    // )
};

pub fn lex(allocator: std.mem.Allocator, text: []const u8) !List {
    const initial_capacity = text.len / 2 + 100;
    var kinds = try std.ArrayList(Kind).initCapacity(allocator, initial_capacity);
    defer kinds.deinit();
    var spans = try std.ArrayList([]const u8).initCapacity(allocator, initial_capacity);
    defer kinds.deinit();

    var remaining = text;
    while (remaining.len > 0) {
        const literal = remaining[0 .. std.mem.indexOf(u8, remaining, "\\\\") orelse remaining.len];
        if (literal.len > 0) {
            var literal_start: usize = 0;
            var search_start: usize = 0;

            while (std.mem.indexOfScalarPos(u8, literal, search_start, '\n')) |end_of_line| {
                search_start = end_of_line + 1;
                const prefix_len = search_start - literal_start;
                const remaining_len = literal.len - search_start;
                if (prefix_len > min_interned_literal_length and remaining_len > min_interned_literal_length) {
                    try append(&kinds, &spans, .literal, literal[literal_start..search_start]);
                    literal_start = search_start;
                }
            }

            if (literal_start < literal.len) {
                try append(&kinds, &spans, .literal, literal[literal_start..]);
            }
        }
        remaining = remaining[@min(remaining.len, literal.len + 2)..];

        var i: usize = 0;
        while (i < remaining.len) {
            switch (remaining[i]) {
                0...9, 11...' ' => i += 1,

                '\n' => {
                    remaining = remaining[i + 1 ..];
                    break;
                },

                '0'...'9' => {
                    var j = i + 1;
                    while (j < remaining.len) switch (remaining[j]) {
                        '0'...'9' => j += 1,
                        else => break,
                    };
                    try append(&kinds, &spans, .number, remaining[i..j]);
                    i = j;
                },

                'a'...'z', 'A'...'Z', '_' => {
                    var j = i + 1;
                    while (j < remaining.len) switch (remaining[j]) {
                        'a'...'z', 'A'...'Z', '0'...'9', '_' => j += 1,
                        else => break,
                    };
                    try append(&kinds, &spans, .id, remaining[i..j]);
                    i = j;
                },

                '"' => {
                    const start = i + 1;
                    const end = std.mem.indexOfScalarPos(u8, remaining, i + 1, '"') orelse remaining.len;
                    try append(&kinds, &spans, .string_literal, remaining[start..end]);
                    i = @min(remaining.len, end + 1);
                },

                '/' => {
                    if (i + 1 < remaining.len and remaining[i + 1] == '/') {
                        remaining = remaining[i + 2 ..];
                        break;
                    } else {
                        try append(&kinds, &spans, .alternative, remaining[i .. i + 1]);
                        i += 1;
                    }
                },

                '?' => {
                    try append(&kinds, &spans, .condition, remaining[i .. i + 1]);
                    i += 1;
                },
                ':' => {
                    if (remaining.len > i + 1 and remaining[i + 1] > ' ') {
                        try append(&kinds, &spans, .fn_call, remaining[i .. i + 1]);
                    } else {
                        try append(&kinds, &spans, .within, remaining[i .. i + 1]);
                    }
                    i += 1;
                },
                ';' => {
                    try append(&kinds, &spans, .otherwise, remaining[i .. i + 1]);
                    i += 1;
                },
                '~' => {
                    try append(&kinds, &spans, .end, remaining[i .. i + 1]);
                    i += 1;
                },
                '^' => {
                    try append(&kinds, &spans, .parent, remaining[i .. i + 1]);
                    i += 1;
                },
                '.' => {
                    try append(&kinds, &spans, .child, remaining[i .. i + 1]);
                    i += 1;
                },
                '#' => {
                    try append(&kinds, &spans, .fragment, remaining[i .. i + 1]);
                    i += 1;
                },
                '*' => {
                    try append(&kinds, &spans, .self, remaining[i .. i + 1]);
                    i += 1;
                },
                '|' => {
                    try append(&kinds, &spans, .fallback, remaining[i .. i + 1]);
                    i += 1;
                },
                '(' => {
                    try append(&kinds, &spans, .open_paren, remaining[i .. i + 1]);
                    i += 1;
                },
                ')' => {
                    try append(&kinds, &spans, .close_paren, remaining[i .. i + 1]);
                    i += 1;
                },

                '@' => {
                    var j = i + 1;
                    while (j < remaining.len) switch (remaining[j]) {
                        'a'...'z', 'A'...'Z', '_' => j += 1,
                        else => break,
                    };
                    const token = remaining[i..j];
                    if (std.mem.eql(u8, token, "@resource")) {
                        try append(&kinds, &spans, .kw_resource, token);
                    } else if (std.mem.eql(u8, token, "@include")) {
                        try append(&kinds, &spans, .kw_include, token);
                    } else if (std.mem.eql(u8, token, "@raw")) {
                        try append(&kinds, &spans, .kw_raw, token);
                    } else if (std.mem.eql(u8, token, "@index")) {
                        try append(&kinds, &spans, .kw_index, token);
                    } else if (std.mem.eql(u8, token, "@exists")) {
                        try append(&kinds, &spans, .kw_exists, token);
                    } else if (std.mem.eql(u8, token, "@url")) {
                        try append(&kinds, &spans, .kw_url, token);
                    } else if (std.mem.eql(u8, token, "@count")) {
                        try append(&kinds, &spans, .kw_count, token);
                    } else {
                        try append(&kinds, &spans, .invalid, token);
                    }
                    i = j;
                },

                '$' => {
                    // comment
                    var j = i + 1;
                    while (j < remaining.len) : (j += 1) switch (remaining[j]) {
                        '/' => if (j + 1 < remaining.len and remaining[j + 1] == '/') {
                            break;
                        },
                        '\n' => break,
                        else => {},
                    };
                    i = j;
                },

                else => {
                    try append(&kinds, &spans, .invalid, remaining[i .. i + 1]);
                    i += 1;
                },
            }
        } else {
            remaining = remaining[remaining.len..];
        }
    }

    try append(&kinds, &spans, .eof, remaining[remaining.len..]);

    std.debug.assert(kinds.items.len == spans.items.len);

    const final_kinds = try kinds.toOwnedSlice();
    errdefer allocator.free(final_kinds);

    const final_spans = try spans.toOwnedSlice();

    return .{
        .kinds = final_kinds,
        .spans = final_spans.ptr,
    };
}

fn append(kinds: *std.ArrayList(Kind), spans: *std.ArrayList([]const u8), kind: Kind, span: []const u8) !void {
    try kinds.ensureUnusedCapacity(1);
    try spans.ensureUnusedCapacity(1);
    std.debug.assert(kinds.items.len == spans.items.len);
    kinds.appendAssumeCapacity(kind);
    spans.appendAssumeCapacity(span);
}

const std = @import("std");
