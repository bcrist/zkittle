
test "lexing" {
    try test_lex(" ",
        \\literal: 
        \\eof:
        \\
    );
    try test_lex("asdf",
        \\literal:asdf
        \\eof:
        \\
    );
    try test_lex(
        \\a b c d
        \\fffff
        ,
        \\literal:a b c d\nfffff
        \\eof:
        \\
    );
    try test_lex(\\asdf \\ //fasdf
        ,
        \\literal:asdf 
        \\literal:fasdf
        \\eof:
        \\
    );
    try test_lex(
        \\\\asdf //
        \\\\
        \\\\
        ,
        \\id:asdf
        \\literal:\n
        \\eof:
        \\
    );
    try test_lex(\\asdf \\ a
        ,
        \\literal:asdf 
        \\id:a
        \\eof:
        \\
    );
    try test_lex(
        \\asdf \\ 
        \\fff
        ,
        \\literal:asdf 
        \\literal:fff
        \\eof:
        \\
    );

    try test_lex(
        \\\\ 
        \\\\  
        \\\\
        \\fff
        ,
        \\literal:fff
        \\eof:
        \\
    );
    try test_lex(
        \\\\ ^^a.b.c.*
        ,
        \\parent:^
        \\parent:^
        \\id:a
        \\child:.
        \\id:b
        \\child:.
        \\id:c
        \\child:.
        \\self:*
        \\eof:
        \\
    );
    try test_lex(
        \\\\ ^ a . b :;~?#%
        ,
        \\parent:^
        \\id:a
        \\child:.
        \\id:b
        \\within::
        \\otherwise:;
        \\end:~
        \\condition:?
        \\count:#
        \\invalid:%
        \\eof:
        \\
    );
    try test_lex(
        \\\\ @raw
        \\\\@rawwww @include
        \\\\ @resource @index
        \\\\ @INDEX index
        ,
        \\kw_raw:@raw
        \\invalid:@rawwww
        \\kw_include:@include
        \\kw_resource:@resource
        \\kw_index:@index
        \\invalid:@INDEX
        \\id:index
        \\eof:
        \\
    );
    try test_lex(
        \\\\ 123 13 Abcdef123 a;sldkfj
        ,
        \\number:123
        \\number:13
        \\id:Abcdef123
        \\id:a
        \\otherwise:;
        \\id:sldkfj
        \\eof:
        \\
    );
    try test_lex(
        \\\\ "a b c"
        ,
        \\id:a b c
        \\eof:
        \\
    );

    try test_lex(
        \\\\ $ "a b c"
        \\\\ asdf
        ,
        \\id:asdf
        \\eof:
        \\
    );

    try test_lex(
        \\\\ $ "a b c" // asdf
        ,
        \\literal: asdf
        \\eof:
        \\
    );
}

fn test_lex(src: []const u8, expected: []const u8) !void {
    var tokens = try Token.lex(std.testing.allocator, src);
    defer tokens.deinit(std.testing.allocator);

    var temp = std.ArrayList(u8).init(std.testing.allocator);
    defer temp.deinit();

    for (tokens.items(.kind), tokens.items(.span)) |kind, span| {
        try temp.writer().print("{s}:{}\n", .{ @tagName(kind), std.zig.fmtEscapes(span) });
    }

    try std.testing.expectEqualStrings(expected, temp.items);
}


test "parsing" {
    try test_parse(
        \\Hellorld!
        ,
        \\print_literal: "Hellorld!"
        \\
    );

    try test_parse(
        \\\\ whatever
        ,
        \\dupe_ref_0
        \\field: "whatever"
        \\print_ref_escaped
        \\
    );

    try test_parse(
        \\\\ #
        ,
        \\dupe_ref_0
        \\as_number
        \\number_to_ref
        \\print_ref_escaped
        \\
    );

    try test_parse(
        \\\\ @resource "test.htm"
        \\\\ @include whatever
        ,
        \\print_literal: "test resource content"
        \\print_literal: "test include content"
        \\dupe_ref_0
        \\field: "included_field"
        \\print_ref_escaped
        \\
    );

    try test_parse(
        \\\\ @raw ax."something here".#.1.c
        ,
        \\dupe_ref_0
        \\field: "ax"
        \\field: "something here"
        \\as_number
        \\number_to_ref
        \\index: 1
        \\field: "c"
        \\print_ref_raw
        \\
    );

    try test_parse(
        \\\\ @index
        ,
        \\print_loop_index
        \\
    );

    try test_parse(
        \\\\ something? 1 ~
        ,
        \\dupe_ref_0
        \\field: "something"
        \\as_number
        \\pop_and_skip_if_zero: 3
        \\dupe_ref_0
        \\index: 1
        \\print_ref_escaped
        \\
    );

    try test_parse(
        \\\\ something?
        \\abc
        \\\\ ; whatever ~
        ,
        \\dupe_ref_0
        \\field: "something"
        \\as_number
        \\pop_and_skip_if_zero: 2
        \\print_literal: "abc\n"
        \\skip: 3
        \\dupe_ref_0
        \\field: "whatever"
        \\print_ref_escaped
        \\
    );

    try test_parse(
        \\\\ a?
        \\1
        \\\\    b?
        \\2
        \\\\    ~
        \\3
        \\\\ ;
        \\4
        \\\\    c?
        \\5
        \\\\    ;
        \\6
        \\\\    ~
        \\7
        \\\\ ~
        \\8
        \\
        ,
        \\dupe_ref_0
        \\field: "a"
        \\as_number
        \\pop_and_skip_if_zero: 8
        \\print_literal: "1\n"
        \\dupe_ref_0
        \\field: "b"
        \\as_number
        \\pop_and_skip_if_zero: 1
        \\print_literal: "2\n"
        \\print_literal: "3\n"
        \\skip: 9
        \\print_literal: "4\n"
        \\dupe_ref_0
        \\field: "c"
        \\as_number
        \\pop_and_skip_if_zero: 2
        \\print_literal: "5\n"
        \\skip: 1
        \\print_literal: "6\n"
        \\print_literal: "7\n"
        \\print_literal: "8\n"
        \\
    );

    try test_parse(
        \\\\ something:
        \\abc
        \\\\ ; whatever ~
        ,
        \\dupe_ref_0
        \\field: "something"
        \\begin_loop
        \\skip_if_equal: 6
        \\dupe_ref_0_indexed
        \\print_literal: "abc\n"
        \\pop_ref
        \\increment_and_retry_if_less: 4
        \\end_loop
        \\skip: 4
        \\end_loop
        \\dupe_ref_0
        \\field: "whatever"
        \\print_ref_escaped
        \\
    );

    try test_parse(
        \\\\ a:
        \\1
        \\\\    b:
        \\2
        \\\\    ~
        \\3
        \\\\ ;
        \\4
        \\\\    c:
        \\5
        \\\\    ;
        \\6
        \\\\    ~
        \\7
        \\\\ ~
        \\8
        \\
        ,
        \\dupe_ref_0
        \\field: "a"
        \\begin_loop
        \\skip_if_equal: 16
        \\dupe_ref_0_indexed
        \\print_literal: "1\n"
        \\dupe_ref_0
        \\field: "b"
        \\begin_loop
        \\skip_if_equal: 4
        \\dupe_ref_0_indexed
        \\print_literal: "2\n"
        \\pop_ref
        \\increment_and_retry_if_less: 10
        \\end_loop
        \\print_literal: "3\n"
        \\pop_ref
        \\increment_and_retry_if_less: 4
        \\end_loop
        \\skip: 15
        \\end_loop
        \\print_literal: "4\n"
        \\dupe_ref_0
        \\field: "c"
        \\begin_loop
        \\skip_if_equal: 6
        \\dupe_ref_0_indexed
        \\print_literal: "5\n"
        \\pop_ref
        \\increment_and_retry_if_less: 26
        \\end_loop
        \\skip: 2
        \\end_loop
        \\print_literal: "6\n"
        \\print_literal: "7\n"
        \\print_literal: "8\n"
        \\
    );

    try test_parse(
        \\\\ something: ^# ^^something.0 ~
        ,
        \\dupe_ref_0
        \\field: "something"
        \\begin_loop
        \\skip_if_equal: 11
        \\dupe_ref_0_indexed
        \\dupe_ref: 1
        \\as_number
        \\number_to_ref
        \\print_ref_escaped
        \\dupe_ref: 2
        \\field: "something"
        \\index: 0
        \\print_ref_escaped
        \\pop_ref
        \\increment_and_retry_if_less: 4
        \\end_loop
        \\
    );

    try test_parse(
        \\\\$ asdfasdfasdf // asdf
        ,
        \\print_literal: " asdf"
        \\
    );
    try test_parse(
        \\\\$ asdfasdfasdf
        \\\\ gg // asdf
        ,
        \\dupe_ref_0
        \\field: "gg"
        \\print_ref_escaped
        \\print_literal: " asdf"
        \\
    );
}

var test_include: ?Source = null;

fn test_include_callback(id: []const u8) anyerror!Source {
    _ = id;

    if (test_include) |source| {
        return source;
    }

    const src_str = 
        \\test include content\\ included_field
        ;

    test_include = try Source.init_buf(std.heap.page_allocator, "included_source", src_str);

    return test_include.?;
}

fn test_resource_callback(id: []const u8) anyerror![]const u8 {
    _ = id;
    return "test resource content";
}

fn test_parse(source_str: []const u8, expected: []const u8) !void {
    var parser: Parser = .{
        .gpa = std.testing.allocator,
        .include_callback = test_include_callback,
        .resource_callback = test_resource_callback,
    };
    defer parser.deinit();

    var source = try Source.init_buf(std.testing.allocator, "source", source_str);
    defer source.deinit(std.testing.allocator);

    try parser.append(source);

    var template = try parser.finish(std.testing.allocator);
    defer template.deinit(std.testing.allocator);

    var temp = std.ArrayList(u8).init(std.testing.allocator);
    defer temp.deinit();

    var writer = temp.writer();

    for (0.., template.opcodes) |i, opcode| {
        const operands = template.operands[i];
        try writer.writeAll(@tagName(opcode));
        switch (opcode) {
            .print_literal, .field => {
                const ref = operands.literal_string;
                const span = template.literal_data[ref.offset..][0..ref.length];
                try writer.print(": \"{}\"", .{ std.zig.fmtEscapes(span) });
            },
            .skip_if_equal, .increment_and_retry_if_less,
            .index, .dupe_ref, .skip, .pop_and_skip_if_zero => {
                try writer.print(": {}", .{ operands.offset });
            },
            .print_ref_raw, .print_ref_escaped, .print_loop_index,
            .begin_loop, .end_loop, .dupe_ref_0_indexed, .pop_ref,
            .as_number, .number_to_ref, .dupe_ref_0 => {},

        }
        try writer.writeByte('\n');
    }

    try std.testing.expectEqualStrings(expected, temp.items);
}

test "render" {
    try test_template(
        \\abcd
        \\asdf
        , {},
        \\abcd
        \\asdf
    );

    try test_template(
        \\\\//abcd\\//
        \\\\//asdf\\
        \\
        , {},
        \\abcd
        \\asdf
    );

    try test_template(
        \\\\ *
        , .{ .a = @as(u16, 1), .span = "asdfasdf" },
        \\1asdfasdf
    );

    try test_parse(
        \\\\ hello: * //
        \\\\ ~
        //, .{ .hello = .{ "abc", "asdfasdf" } },
        ,
        \\dupe_ref_0
        \\field: "hello"
        \\begin_loop
        \\skip_if_equal: 6
        \\dupe_ref_0_indexed
        \\dupe_ref_0
        \\print_ref_escaped
        \\print_literal: "\n"
        \\pop_ref
        \\increment_and_retry_if_less: 4
        \\end_loop
        \\
    );

    try test_template(
        \\\\ hello: * //
        \\\\ ~
        , .{ .hello = .{ "abc", "asdfasdf" } },
        \\abc
        \\asdfasdf
        \\
    );

    const My_Union = union (enum) {
        a: u32,
        b: i16,
        c: []const u8,
    };

    try test_template(
        \\a:\\a//
        \\b:\\b//
        \\c:\\c//
        \\
        , @as(My_Union, .{ .c = "1234" }),
        \\a:
        \\b:
        \\c:1234
        \\
    );

}

fn test_template(source_str: []const u8, value: anytype, expected: []const u8) !void {
    var parser: Parser = .{
        .gpa = std.testing.allocator,
        .include_callback = test_include_callback,
        .resource_callback = test_resource_callback,
    };
    defer parser.deinit();

    var source = try Source.init_buf(std.testing.allocator, "source", source_str);
    defer source.deinit(std.testing.allocator);

    try parser.append(source);

    var template = try parser.finish(std.testing.allocator);
    defer template.deinit(std.testing.allocator);

    var temp = std.ArrayList(u8).init(std.testing.allocator);
    defer temp.deinit();

    const writer = temp.writer();
    try template.render(writer.any(), value, .{});
    try std.testing.expectEqualStrings(expected, temp.items);
}

const Template = @import("src/Template.zig");
const Parser = @import("src/Parser.zig");
const Source = @import("src/Source.zig");
const Token = @import("src/Token.zig");
const std = @import("std");
