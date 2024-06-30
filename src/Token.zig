kind: Kind,
span: []const u8,

const min_interned_literal_length = 15;

const Token = @This();

pub const List = std.MultiArrayList(Token);

pub const Kind = enum (u8) {
    invalid,
    eof,
    literal,
    id,
    number,
    kw_resource,
    kw_include,
    kw_raw,
    kw_index,
    kw_exists,
    kw_url,
    condition,   // ?
    within,      // :
    otherwise,   // ;
    end,         // ~
    parent,      // ^
    child,       // .
    count,       // #
    self,        // *
    fallback,    // |
    alternative, // /
    open_paren,  // (
    close_paren, // )
};


pub fn lex(allocator: std.mem.Allocator, text: []const u8) !List {
    var tokens: List = .{};
    try tokens.setCapacity(allocator, text.len / 2 + 100);

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
                    try tokens.append(allocator, .{ .kind = .literal, .span = literal[literal_start..search_start] });
                    literal_start = search_start;
                }
            }

            if (literal_start < literal.len) {
                try tokens.append(allocator, .{ .kind = .literal, .span = literal[literal_start..] });
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
                    try tokens.append(allocator, .{ .kind = .number, .span = remaining[i..j] });
                    i = j;
                },

                'a'...'z', 'A'...'Z', '_' => {
                    var j = i + 1;
                    while (j < remaining.len) switch (remaining[j]) {
                        'a'...'z', 'A'...'Z', '0'...'9', '_' => j += 1,
                        else => break,
                    };
                    try tokens.append(allocator, .{ .kind = .id, .span = remaining[i..j] });
                    i = j;
                },

                '"' => {
                    const start = i + 1;
                    const end = std.mem.indexOfScalarPos(u8, remaining, i + 1, '"') orelse remaining.len;
                    try tokens.append(allocator, .{ .kind = .id, .span = remaining[start..end] });
                    i = @min(remaining.len, end + 1);
                },

                '/' => {
                    if (i + 1 < remaining.len and remaining[i + 1] == '/') {
                        remaining = remaining[i + 2 ..];
                        break;
                    } else {
                        try tokens.append(allocator, .{ .kind = .alternative, .span = remaining[i .. i + 1] });
                        i += 1;
                    }
                },

                '?' => {
                    try tokens.append(allocator, .{ .kind = .condition, .span = remaining[i .. i + 1] });
                    i += 1;
                },
                ':' => {
                    try tokens.append(allocator, .{ .kind = .within, .span = remaining[i .. i + 1] });
                    i += 1;
                },
                ';' => {
                    try tokens.append(allocator, .{ .kind = .otherwise, .span = remaining[i .. i + 1] });
                    i += 1;
                },
                '~' => {
                    try tokens.append(allocator, .{ .kind = .end, .span = remaining[i .. i + 1] });
                    i += 1;
                },
                '^' => {
                    try tokens.append(allocator, .{ .kind = .parent, .span = remaining[i .. i + 1] });
                    i += 1;
                },
                '.' => {
                    try tokens.append(allocator, .{ .kind = .child, .span = remaining[i .. i + 1] });
                    i += 1;
                },
                '#' => {
                    try tokens.append(allocator, .{ .kind = .count, .span = remaining[i .. i + 1] });
                    i += 1;
                },
                '*' => {
                    try tokens.append(allocator, .{ .kind = .self, .span = remaining[i .. i + 1] });
                    i += 1;
                },
                '|' => {
                    try tokens.append(allocator, .{ .kind = .fallback, .span = remaining[i .. i + 1] });
                    i += 1;
                },
                '(' => {
                    try tokens.append(allocator, .{ .kind = .open_paren, .span = remaining[i .. i + 1] });
                    i += 1;
                },
                ')' => {
                    try tokens.append(allocator, .{ .kind = .close_paren, .span = remaining[i .. i + 1] });
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
                        try tokens.append(allocator, .{ .kind = .kw_resource, .span = token });
                    } else if (std.mem.eql(u8, token, "@include")) {
                        try tokens.append(allocator, .{ .kind = .kw_include, .span = token });
                    } else if (std.mem.eql(u8, token, "@raw")) {
                        try tokens.append(allocator, .{ .kind = .kw_raw, .span = token });
                    } else if (std.mem.eql(u8, token, "@index")) {
                        try tokens.append(allocator, .{ .kind = .kw_index, .span = token });
                    } else if (std.mem.eql(u8, token, "@exists")) {
                        try tokens.append(allocator, .{ .kind = .kw_exists, .span = token });
                    } else if (std.mem.eql(u8, token, "@url")) {
                        try tokens.append(allocator, .{ .kind = .kw_url, .span = token });
                    } else {
                        try tokens.append(allocator, .{ .kind = .invalid, .span = token });
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
                    try tokens.append(allocator, .{ .kind = .invalid, .span = remaining[i .. i + 1] });
                    i += 1;
                },
            }
        } else {
            remaining = "";
        }
    }

    try tokens.append(allocator, .{ .kind = .eof, .span = "" });

    return tokens;
}

const std = @import("std");
