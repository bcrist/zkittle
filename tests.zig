
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
        \\\\ ^ a . b :;~?#%|/
        ,
        \\parent:^
        \\id:a
        \\child:.
        \\id:b
        \\within::
        \\otherwise:;
        \\end:~
        \\condition:?
        \\fragment:#
        \\invalid:%
        \\fallback:|
        \\alternative:/
        \\eof:
        \\
    );
    try test_lex(
        \\\\ @raw
        \\\\@url
        \\\\@rawwww @include
        \\\\ @resource @index
        \\\\ @INDEX index @exists
        ,
        \\kw_raw:@raw
        \\kw_url:@url
        \\invalid:@rawwww
        \\kw_include:@include
        \\kw_resource:@resource
        \\kw_index:@index
        \\invalid:@INDEX
        \\id:index
        \\kw_exists:@exists
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

    try test_lex(
        \\\\ (abc).d
        ,
        \\open_paren:(
        \\id:abc
        \\close_paren:)
        \\child:.
        \\id:d
        \\eof:
        \\
    );
}

fn test_lex(src: []const u8, expected: []const u8) !void {
    var tokens = try Token.lex(std.testing.allocator, src);
    defer tokens.deinit(std.testing.allocator);

    var temp = std.ArrayList(u8).init(std.testing.allocator);
    defer temp.deinit();

    for (tokens.kinds, tokens.spans) |kind, span| {
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
        \\Hellorld!
        \\Multiple lines!
        ,
        \\print_literal: "Hellorld!\nMultiple lines!"
        \\
    );

    try test_parse(
        \\Hellorld!  This is a long line.
        \\Hellorld!  This is a long line.
        \\Hellorld again!!!
        ,
        \\print_literal: "Hellorld!  This is a long line.\n"
        \\print_literal: "Hellorld!  This is a long line.\nHellorld again!!!"
        \\
    );

    try test_parse(
        \\AAAAAAAAAAAAAAAAAAAA
        \\BBBBBBBBBBBBBBBBBBBB
        \\CCCCCCCCCCCCCCCCCCCC
        \\BBBBBBBBBBBBBBBBBBBB
        \\CCCCCCCCCCCCCCCCCCCC
        \\AAAAAAAAAAAAAAAAAAAA
        \\AAAAAAAAAAAAAAAAAAAA
        \\BBBBBBBBBBBBBBBBBBBB
        \\CCCCCCCCCCCCCCCCCCCC
        \\
        ,
        \\print_literal: "AAAAAAAAAAAAAAAAAAAA\nBBBBBBBBBBBBBBBBBBBB\nCCCCCCCCCCCCCCCCCCCC\n"
        \\print_literal: "BBBBBBBBBBBBBBBBBBBB\nCCCCCCCCCCCCCCCCCCCC\n"
        \\print_literal: "AAAAAAAAAAAAAAAAAAAA\n"
        \\print_literal: "AAAAAAAAAAAAAAAAAAAA\nBBBBBBBBBBBBBBBBBBBB\nCCCCCCCCCCCCCCCCCCCC\n"
        \\
    );

    try test_parse(
        \\\\ whatever
        ,
        \\push_field: "whatever"
        \\print_ref_escaped
        \\
    );

    try test_invalid_parse(
        \\\\ #
    );

    try test_parse(
        \\\\ @count
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
        \\push_field: "included_field"
        \\print_ref_escaped
        \\
    );

    try test_parse(
        \\\\ @raw ax."something here".@count.1.c
        ,
        \\push_field: "ax"
        \\field: "something here"
        \\as_number
        \\number_to_ref
        \\index: 1
        \\field: "c"
        \\print_ref_raw
        \\
    );

    try test_parse(
        \\\\ @url ax."something here".@count.1.c
        ,
        \\push_field: "ax"
        \\field: "something here"
        \\as_number
        \\number_to_ref
        \\index: 1
        \\field: "c"
        \\print_ref_url
        \\
    );

    try test_parse(
        \\\\ @index.@exists
        ,
        \\push_loop_index
        \\is_ref_nonnil
        \\print_ref_escaped
        \\
    );

    try test_parse(
        \\\\ something? 1 ~
        ,
        \\push_field: "something"
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
        \\push_field: "something"
        \\as_number
        \\pop_and_skip_if_zero: 2
        \\print_literal: "abc\n"
        \\skip: 2
        \\push_field: "whatever"
        \\print_ref_escaped
        \\
    );

    try test_parse(
        \\\\ *.something?
        \\abc
        \\\\ ; whatever ~
        ,
        \\dupe_ref_0
        \\field: "something"
        \\as_number
        \\pop_and_skip_if_zero: 2
        \\print_literal: "abc\n"
        \\skip: 2
        \\push_field: "whatever"
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
        \\push_field: "a"
        \\as_number
        \\pop_and_skip_if_zero: 7
        \\print_literal: "1\n"
        \\push_field: "b"
        \\as_number
        \\pop_and_skip_if_zero: 1
        \\print_literal: "2\n"
        \\print_literal: "3\n"
        \\skip: 8
        \\print_literal: "4\n"
        \\push_field: "c"
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
        \\push_field: "something"
        \\begin_loop
        \\skip_if_equal: 6
        \\dupe_ref_0_indexed
        \\print_literal: "abc\n"
        \\pop_ref
        \\increment_and_retry_if_less: 3
        \\end_loop
        \\skip: 3
        \\end_loop
        \\push_field: "whatever"
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
        \\push_field: "a"
        \\begin_loop
        \\skip_if_equal: 15
        \\dupe_ref_0_indexed
        \\print_literal: "1\n"
        \\push_field: "b"
        \\begin_loop
        \\skip_if_equal: 4
        \\dupe_ref_0_indexed
        \\print_literal: "2\n"
        \\pop_ref
        \\increment_and_retry_if_less: 3
        \\end_loop
        \\print_literal: "3\n"
        \\pop_ref
        \\increment_and_retry_if_less: 12
        \\end_loop
        \\skip: 14
        \\end_loop
        \\print_literal: "4\n"
        \\push_field: "c"
        \\begin_loop
        \\skip_if_equal: 6
        \\dupe_ref_0_indexed
        \\print_literal: "5\n"
        \\pop_ref
        \\increment_and_retry_if_less: 3
        \\end_loop
        \\skip: 2
        \\end_loop
        \\print_literal: "6\n"
        \\print_literal: "7\n"
        \\print_literal: "8\n"
        \\
    );

    try test_parse(
        \\\\ something: ^@count ^^something.0 ~
        ,
        \\push_field: "something"
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
        \\increment_and_retry_if_less: 10
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
        \\push_field: "gg"
        \\print_ref_escaped
        \\print_literal: " asdf"
        \\
    );

    try test_parse(
        \\\\ hello: * //
        \\\\ ~
        ,
        \\push_field: "hello"
        \\begin_loop
        \\skip_if_equal: 6
        \\dupe_ref_0_indexed
        \\dupe_ref_0
        \\print_ref_escaped
        \\print_literal: "\n"
        \\pop_ref
        \\increment_and_retry_if_less: 5
        \\end_loop
        \\
    );

    try test_parse(
        \\\\ a | b
        ,
        \\push_field: "a"
        \\dupe_ref_0
        \\is_ref_nonnil
        \\as_number
        \\pop_and_skip_if_nonzero: 2
        \\pop_ref
        \\push_field: "b"
        \\print_ref_escaped
        \\
    );

    try test_parse(
        \\\\ a | b | c
        ,
        \\push_field: "a"
        \\dupe_ref_0
        \\is_ref_nonnil
        \\as_number
        \\pop_and_skip_if_nonzero: 8
        \\pop_ref
        \\push_field: "b"
        \\dupe_ref_0
        \\is_ref_nonnil
        \\as_number
        \\pop_and_skip_if_nonzero: 2
        \\pop_ref
        \\push_field: "c"
        \\print_ref_escaped
        \\
    );

    
    try test_parse(
        \\\\ a / b
        ,
        \\push_field: "a"
        \\dupe_ref_0
        \\as_number
        \\pop_and_skip_if_nonzero: 2
        \\pop_ref
        \\push_field: "b"
        \\print_ref_escaped
        \\
    );

    try test_parse(
        \\\\ a / b | c
        ,
        \\push_field: "a"
        \\dupe_ref_0
        \\as_number
        \\pop_and_skip_if_nonzero: 8
        \\pop_ref
        \\push_field: "b"
        \\dupe_ref_0
        \\is_ref_nonnil
        \\as_number
        \\pop_and_skip_if_nonzero: 2
        \\pop_ref
        \\push_field: "c"
        \\print_ref_escaped
        \\
    );

    try test_parse(
        \\\\ (a|b).@exists
        ,
        \\push_field: "a"
        \\dupe_ref_0
        \\is_ref_nonnil
        \\as_number
        \\pop_and_skip_if_nonzero: 2
        \\pop_ref
        \\push_field: "b"
        \\is_ref_nonnil
        \\print_ref_escaped
        \\
    );

    try test_parse(
        \\verylongstringverylongstringverylongstringverylongstringverylongstringverylongstringverylongstringverylongstringverylongstringverylongstringverylongstringverylongstring0
        \\verylongstringverylongstringverylongstringverylongstringverylongstringverylongstringverylongstringverylongstringverylongstringverylongstringverylongstringverylongstring1
        \\verylongstringverylongstringverylongstringverylongstringverylongstringverylongstringverylongstringverylongstringverylongstringverylongstringverylongstringverylongstring2
        \\verylongstringverylongstringverylongstringverylongstringverylongstringverylongstringverylongstringverylongstringverylongstringverylongstringverylongstringverylongstring3
        ,
        \\push_var: 679
        \\print_literal_var_len: 0
        \\
    );
}

var test_include: ?Source = null;

fn test_include_callback(p: *Parser, id: []const u8) anyerror!Source {
    _ = p;
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

fn test_resource_callback(p: *Parser, id: []const u8) anyerror![]const u8 {
    _ = p;
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

    var template = try parser.finish(std.testing.allocator, true);
    defer template.deinit(std.testing.allocator);

    var temp = std.ArrayList(u8).init(std.testing.allocator);
    defer temp.deinit();

    var writer = temp.writer();

    for (0.., template.opcodes) |i, opcode| {
        const operands = template.operands[i];
        try writer.writeAll(@tagName(opcode));
        switch (opcode) {
            .print_literal, .field, .push_field => {
                const ref = operands.literal_ref();
                const span = template.literal_data[ref.offset..][0..ref.length];
                try writer.print(": \"{}\"", .{ std.zig.fmtEscapes(span) });
            },
            .print_literal_var_len, .field_var_len, .push_field_var_len,
            .skip_if_equal, .increment_and_retry_if_less,
            .index, .dupe_ref, .skip, .push_var,
            .pop_and_skip_if_zero, .pop_and_skip_if_nonzero => {
                try writer.print(": {}", .{ operands.offset });
            },
            .print_ref_raw, .print_ref_escaped, .print_ref_url, .push_loop_index,
            .begin_loop, .end_loop, .dupe_ref_0_indexed, .pop_ref,
            .as_number, .number_to_ref, .dupe_ref_0, .is_ref_nonnil,
            .push_nil => {},

        }
        try writer.writeByte('\n');
    }

    try std.testing.expectEqualStrings(expected, temp.items);
}
fn test_invalid_parse(source_str: []const u8) !void {
    var parser: Parser = .{
        .gpa = std.testing.allocator,
        .include_callback = test_include_callback,
        .resource_callback = test_resource_callback,
    };
    defer parser.deinit();

    var source = try Source.init_buf(std.testing.allocator, "source", source_str);
    defer source.deinit(std.testing.allocator);

    try std.testing.expectError(error.InvalidTemplate, parser.append(source));
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

    try test_template(
        \\\\ hello: outer //
        \\\\ ~
        , .{ .hello = .{ "abc", "asdfasdf" }, .outer = "asdf" },
        \\asdf
        \\asdf
        \\
    );

    try test_template(
        \\\\ @index
        , {},
        \\
    );

    try test_template(
        \\\\ @index.@exists
        , {},
        \\false
    );

    try test_template(
        \\\\ @index | index
        , .{ .index = 5 },
        \\5
    );

    try test_template(
        \\\\ a / b
        , .{ .a = "", .b = "XYZ" },
        \\XYZ
    );

    try test_template(
        \\\\ a / b / c
        , .{ .a = null, .b = "XYZ", .c = 123 },
        \\XYZ
    );

    try test_template(
        \\\\ @index | index1 | index2
        , .{ .index1 = 5, .index2 = 10 },
        \\5
    );

    try test_template(
        \\\\ html
        , .{ .html = "<html></html>" },
        \\&lt;html&gt;&lt;/html&gt;
    );

    try test_template(
        \\\\ @raw html
        , .{ .html = "<html></html>" },
        \\<html></html>
    );

    try test_template(
        \\\\ @url html
        , .{ .html = "<html></html>" },
        \\%3Chtml%3E%3C%2Fhtml%3E
    );

    try test_template(
        \\\\ (a|b).@exists? //1\\~
        , .{ .a = undefined, .b = undefined },
        \\
    );

    try test_template(
        \\\\ (a|b).@exists? //1\\~
        , .{ .a = undefined, .b = null },
        \\1
    );

    const template_with_frags = 
        \\XYZ
        \\\\ #some_fragment_name
        \\a b c
        \\\\ a
        \\\\ #another_fragment
        \\a;sldkfj
        \\\\~
        \\asdf
        \\\\ ~
        ;

    try test_template(template_with_frags, .{ .a = "1234" },
        \\XYZ
        \\a b c
        \\1234a;sldkfj
        \\asdf
        \\
    );

    try test_template_fragment(template_with_frags, .{ .a = "1234" }, "some_fragment_name",
        \\a b c
        \\1234a;sldkfj
        \\asdf
        \\
    );

    try test_template_fragment(template_with_frags, .{ .a = "1234" }, "another_fragment",
        \\a;sldkfj
        \\
    );
}

fn test_template(source_str: []const u8, value: anytype, expected: []const u8) !void {
    try test_template_alloc(std.heap.page_allocator, source_str, null, value, expected);
}
fn test_template_fragment(source_str: []const u8, value: anytype, fragment: []const u8, expected: []const u8) !void {
    try test_template_alloc(std.heap.page_allocator, source_str, fragment, value, expected);
}

fn test_template_alloc(allocator: std.mem.Allocator, source_str: []const u8, fragment: ?[]const u8, value: anytype, expected: []const u8) !void {
    var parser: Parser = .{
        .gpa = allocator,
        .include_callback = test_include_callback,
        .resource_callback = test_resource_callback,
    };
    defer parser.deinit();

    var source = try Source.init_buf(allocator, "source", source_str);
    defer source.deinit(allocator);

    try parser.append(source);

    var template = if (fragment) |name| try parser.get_fragment(allocator, name) orelse return error.FragmentNotFound else try parser.finish(allocator, true);
    defer template.deinit(allocator);

    var temp = std.ArrayList(u8).init(allocator);
    defer temp.deinit();

    const writer = temp.writer();
    try template.render(writer.any(), value, .{});
    try std.testing.expectEqualStrings(expected, temp.items);
}

pub fn main() !void {
    try test_template(
        \\\\ @index | index
        , .{ .index = 5 },
        \\5
    );
}

const Template = @import("src/Template.zig");
const Parser = @import("src/Parser.zig");
const Source = @import("src/Source.zig");
const Token = @import("src/Token.zig");
const std = @import("std");
