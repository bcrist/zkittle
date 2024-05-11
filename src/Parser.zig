gpa: std.mem.Allocator,

/// N.B. The memory referenced by the returned source must remain stable and constant until the parse is complete!
include_callback: *const fn (id: []const u8) anyerror!Source,

/// N.B. The memory returned must remain stable and constant until the parse is complete!
resource_callback: *const fn (id: []const u8) anyerror![]const u8,

instructions: std.MultiArrayList(Template.Instruction) = .{},
literal_data: std.ArrayListUnmanaged(u8) = .{},
literal_dedup: std.StringHashMapUnmanaged(Template.Literal_Ref) = .{},
ref_stack_depth: usize = 0,

include_stack: std.ArrayListUnmanaged(Source) = .{},

token_kinds: []const Token.Kind = &.{},
token_spans: []const []const u8 = &.{},
next_token: usize = 0,

const Parser = @This();

pub fn deinit(self: *Parser) void {
    self.instructions.deinit(self.gpa);
    self.literal_data.deinit(self.gpa);
    self.literal_dedup.deinit(self.gpa);
    self.include_stack.deinit(self.gpa);
}

pub fn append(self: *Parser, source: Source) anyerror!void {
    const old_next = self.next_token;

    for (self.include_stack.items) |other_source| {
        if (std.mem.eql(u8, source.path, other_source.path)) {
            return error.RecursiveTemplate;
        }
    }

    try self.include_stack.append(self.gpa, source);
    self.token_kinds = source.tokens.items(.kind);
    self.token_spans = source.tokens.items(.span);
    self.next_token = 0;

    try self.parse_block();
    while (self.try_token(.eof) == null) {
        try source.report_error(self.next_token, "Expected expression or directive");
        self.next_token += 1;
        try self.parse_block();
    }

    _ = self.include_stack.pop();
    if (self.include_stack.getLastOrNull()) |s| {
        self.token_kinds = s.tokens.items(.kind);
        self.token_spans = s.tokens.items(.span);
    }
    self.next_token = old_next;
}

pub fn finish(self: *Parser, allocator: std.mem.Allocator) !Template {
    const template = try Template.init(allocator, self.instructions, self.literal_data.items);

    self.instructions.len = 0;
    self.literal_data.clearRetainingCapacity();
    self.literal_dedup.clearRetainingCapacity();
    self.ref_stack_depth = 0;

    return template;
}

fn parse_block(self: *Parser) anyerror!void {
    while (try self.parse_item()) {}
}

fn parse_item(self: *Parser) !bool {
    switch (self.token_kinds[self.next_token]) {
        .literal => {
            try self.add_print_literal_instruction(self.token_spans[self.next_token]);
            self.next_token += 1;
            return true;
        },
        .kw_resource => {
            self.next_token += 1;
            const id = try self.require_token(.id);
            if (self.resource_callback(id)) |literal| {
                try self.add_print_literal_instruction(literal);
            } else |err| {
                try self.include_stack.getLast().report_error(self.next_token - 1, @errorName(err));
            }
            return true;
        },
        .kw_include => {
            self.next_token += 1;
            const id = try self.require_token(.id);
            if (self.include_callback(id)) |source| {
                try self.append(source);
            } else |err| {
                try self.include_stack.getLast().report_error(self.next_token - 1, @errorName(err));
            }
            return true;
        },
        .kw_raw => {
            self.next_token += 1;
            if (try self.parse_ref()) {
                try self.add_basic_instruction(.print_ref_raw);
            } else {
                try self.include_stack.getLast().report_error(self.next_token, "Expected value reference");
            }
            return true;
        },
        .kw_index => {
            self.next_token += 1;
            try self.add_basic_instruction(.print_loop_index);
            return true;
        },
        else => {
            if (try self.parse_expression()) return true;
            if (try self.parse_ref()) {
                try self.add_basic_instruction(.print_ref_escaped);
                return true;
            }
            return false;
        },
    }
}

fn parse_expression(self: *Parser) !bool {
    if (try self.parse_ref()) {
        if (!(try self.parse_condition()) and !(try self.parse_within())) {
            try self.add_basic_instruction(.print_ref_escaped);
        }
        return true;
    }
    return false;
}

fn parse_condition(self: *Parser) !bool {
    if (self.try_token(.condition) == null) return false;

    try self.add_basic_instruction(.as_number);
    const conditional_jump_instruction = self.pc();
    try self.add_offset_instruction(.pop_and_skip_if_zero, 0); // to else block or end of block
    try self.parse_block();

    if (self.try_token(.otherwise)) |_| {
        const jump_instruction = self.pc();
        try self.add_offset_instruction(.skip, 0); // to end of block
        self.finalize_skip_instruction(conditional_jump_instruction, self.pc());
        try self.parse_block();
        self.finalize_skip_instruction(jump_instruction, self.pc());
    } else {
        self.finalize_skip_instruction(conditional_jump_instruction, self.pc());
    }

    _ = try self.require_token(.end);
    return true;
}

fn parse_within(self: *Parser) !bool {
    if (self.try_token(.within) == null) return false;

    try self.add_basic_instruction(.begin_loop);
    const skip_if_equal_instruction = self.pc();
    try self.add_offset_instruction(.skip_if_equal, 0); // to else block or end of block
    const loop_begin_instruction = self.pc();
    try self.add_basic_instruction(.dupe_ref_0_indexed);
    try self.parse_block();
    try self.add_basic_instruction(.pop_ref);

    try self.add_offset_instruction(.increment_and_retry_if_less, loop_begin_instruction);
    self.finalize_skip_instruction(skip_if_equal_instruction, self.pc());
    try self.add_basic_instruction(.end_loop);
    
    if (self.try_token(.otherwise)) |_| {
        const skip_to_end_of_block_instruction = self.pc();
        try self.add_offset_instruction(.skip, 0); // to end of block
        self.finalize_skip_instruction(skip_if_equal_instruction, self.pc());
        self.ref_stack_depth += 1; // the following end_loop is a duplicate of the one above; only one of them will be executed
        try self.add_basic_instruction(.end_loop);
        try self.parse_block();
        self.finalize_skip_instruction(skip_to_end_of_block_instruction, self.pc());
    }

    _ = try self.require_token(.end);
    return true;
}

fn parse_ref(self: *Parser) !bool {
    if (self.try_token(.self)) |_| {
        try self.add_dupe_ref_instruction(.{});
        return true;
    }

    switch (self.token_kinds[self.next_token]) {
        .invalid, .eof, .literal, .kw_resource, .kw_include, .kw_raw, .kw_index,
        .condition, .within, .otherwise, .end, .child => return false,
        .id, .number, .parent, .count, .self => {},
    }

    var parent_count: usize = 0;
    while (self.try_token(.parent)) |_| parent_count += 1;

    try self.add_dupe_ref_instruction(.{ .parent_count = parent_count });
    try self.parse_field_or_index_or_count();

    while (self.try_token(.child)) |_| {
        try self.parse_field_or_index_or_count();
    }
    return true;
}

fn parse_field_or_index_or_count(self: *Parser) !void {
    if (self.try_token(.id)) |field_name| {
        try self.add_literal_instruction(.field, field_name);

    } else if (self.try_token(.number)) |index_str| {
        const index = try std.fmt.parseInt(usize, index_str, 10);
        try self.instructions.append(self.gpa, .{
            .op = .index,
            .data = .{ .offset = index },
        });
    } else if (self.try_token(.count)) |_| {
        try self.instructions.append(self.gpa, .{
            .op = .as_number,
            .data = .{ .none = {} },
        });
        try self.instructions.append(self.gpa, .{
            .op = .number_to_ref,
            .data = .{ .none = {} },
        });
    } else {
        try self.include_stack.getLast().report_error(self.next_token, "Expected field name, index, or '#'");
        return error.InvalidTemplate;
    }
}

fn try_token(self: *Parser, kind: Token.Kind) ?[]const u8 {
    if (self.token_kinds[self.next_token] == kind) {
        const span = self.token_spans[self.next_token];
        self.next_token += 1;
        return span;
    }
    return null;
}

fn require_token(self: *Parser, comptime kind: Token.Kind) ![]const u8 {
    if (self.try_token(kind)) |span| return span;
    try self.include_stack.getLast().report_error(self.next_token, "Expected " ++ @tagName(kind));
    return error.InvalidTemplate;
}

const Dupe_Ref_Options = struct {
    parent_count: usize = 0,
};
fn add_dupe_ref_instruction(self: *Parser, options: Dupe_Ref_Options) !void {
    var parent_count = options.parent_count;
    if (parent_count > self.ref_stack_depth) {
        var buf: [128]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "Not enough parent data contexts; only {} exist", .{ self.ref_stack_depth });
        try self.include_stack.getLast().report_error(self.next_token - 1, msg);
        parent_count = self.ref_stack_depth;
    }

    if (parent_count == 0) {
        try self.add_basic_instruction(.dupe_ref_0);
    } else {
        try self.add_offset_instruction(.dupe_ref, parent_count);
    }
}

fn add_print_literal_instruction(self: *Parser, literal: []const u8) !void {
    try self.add_literal_instruction(.print_literal, literal);
}

fn pc(self: *Parser) usize {
    return self.instructions.len;
}

fn add_basic_instruction(self: *Parser, op: Template.Opcode) !void {
    switch (op) {
        .print_literal, // literal_ref
        .field, // literal_ref
        .index, // offset
        .dupe_ref, // offset
        .pop_and_skip_if_zero, // offset
        .skip, // offset
        .skip_if_equal, // offset
        .increment_and_retry_if_less, // offset
        => unreachable,

        .print_ref_raw,
        .print_ref_escaped,
        .as_number,
        .end_loop,
        .pop_ref,
        => {
            self.ref_stack_depth -= 1;
        },

        .begin_loop,
        .print_loop_index,
        => {},

        .dupe_ref_0,
        .dupe_ref_0_indexed,
        .number_to_ref,
        => try self.check_and_increment_ref_stack(),
    }
    try self.instructions.append(self.gpa, .{
        .op = op,
        .data = .{ .none = {} },
    });
}

fn add_offset_instruction(self: *Parser, op: Template.Opcode, offset: usize) !void {
    switch (op) {
        .print_literal, // literal_ref
        .print_ref_raw,
        .print_ref_escaped,
        .print_loop_index,
        .field, // literal_ref
        .as_number,
        .number_to_ref,
        .dupe_ref_0,
        .begin_loop,
        .end_loop,
        .dupe_ref_0_indexed,
        .pop_ref,
        => unreachable,

        .index, // offset
        .pop_and_skip_if_zero, // offset
        .skip, // offset
        .skip_if_equal, // offset
        .increment_and_retry_if_less, // offset
        => {},

        .dupe_ref, // offset
        => try self.check_and_increment_ref_stack(),
    }
    try self.instructions.append(self.gpa, .{
        .op = op,
        .data = .{ .offset = offset },
    });
}

fn add_literal_instruction(self: *Parser, op: Template.Opcode, literal: []const u8) !void {
    switch (op) {
        .print_literal, // literal_ref
        .field, // literal_ref
        => {},

        .print_ref_raw,
        .print_ref_escaped,
        .print_loop_index,
        .as_number,
        .number_to_ref,
        .dupe_ref_0,
        .index, // offset
        .dupe_ref, // offset
        .pop_and_skip_if_zero, // offset
        .skip, // offset
        .begin_loop,
        .end_loop,
        .skip_if_equal, // offset
        .dupe_ref_0_indexed,
        .pop_ref,
        .increment_and_retry_if_less, // offset
        => unreachable,
    }
    const literal_ref = try self.intern_literal(literal);
    try self.instructions.append(self.gpa, .{
        .op = op,
        .data = .{ .literal_string = literal_ref },
    });
}

fn finalize_skip_instruction(self: *Parser, instruction_address: usize, target_address: usize) void {
    switch (self.instructions.items(.op)[instruction_address]) {
        .print_literal, // literal_ref
        .field, // literal_ref
        .print_ref_raw,
        .print_ref_escaped,
        .print_loop_index,
        .as_number,
        .number_to_ref,
        .dupe_ref_0,
        .index, // offset
        .dupe_ref, // offset
        .begin_loop,
        .end_loop,
        .dupe_ref_0_indexed,
        .pop_ref,
        .increment_and_retry_if_less, // offset
        => unreachable,

        .skip_if_equal, // offset
        .pop_and_skip_if_zero, // offset
        .skip, // offset
        => {},
    }
    const instructions_to_skip = target_address - instruction_address - 1;
    self.instructions.items(.data)[instruction_address] = .{ .offset = instructions_to_skip };
}

fn check_and_increment_ref_stack(self: *Parser) !void {
    if (self.ref_stack_depth + 1 >= Template.max_stack_size) {
        try self.include_stack.getLast().report_error(self.next_token - 1, "Too many nested data contexts");
        return error.NestingTooDeep;
    }
    self.ref_stack_depth += 1;
}

fn intern_literal(self: *Parser, literal: []const u8) !Template.Literal_Ref {
    try self.literal_data.ensureUnusedCapacity(self.gpa, literal.len);
    const gop = try self.literal_dedup.getOrPut(self.gpa, literal);
    if (!gop.found_existing) {
        const start = self.literal_data.items.len;
        self.literal_data.appendSliceAssumeCapacity(literal);
        gop.key_ptr.* = literal;
        gop.value_ptr.* = .{
            .offset = @intCast(start),
            .length = @intCast(literal.len),
        };
    }
    return gop.value_ptr.*;
}

const Template = @import("Template.zig");
const Source = @import("Source.zig");
const Token = @import("Token.zig");
const std = @import("std");
