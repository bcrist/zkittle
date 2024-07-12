gpa: std.mem.Allocator,

/// N.B. The memory referenced by the returned source must remain stable and constant until the parse is complete!
include_callback: *const fn (id: []const u8) anyerror!Source,

/// N.B. The memory returned must remain stable and constant until the parse is complete!
resource_callback: *const fn (id: []const u8) anyerror![]const u8,

instructions: std.MultiArrayList(Instruction) = .{},
fragments: std.StringArrayHashMapUnmanaged(Fragment) = .{},
literal_data: std.ArrayListUnmanaged(u8) = .{},
literal_dedup: std.StringHashMapUnmanaged(Literal_Ref) = .{},
ref_stack_depth: u32 = 0,

include_stack: std.ArrayListUnmanaged(Source) = .{},

token_kinds: []const Token.Kind = &.{},
token_spans: []const []const u8 = &.{},
next_token: usize = 0,

const Instruction = struct {
    op: Template.Opcode,
    data: Template.Operands,
};

pub const Literal_Ref = packed struct {
    offset: u32,
    length: u32,

    pub fn small(self: Literal_Ref) ?Template.Literal_Ref {
        const Offset = std.meta.FieldType(Template.Literal_Ref, .offset);
        const Length = std.meta.FieldType(Template.Literal_Ref, .length);

        if (self.offset > std.math.maxInt(Offset)) return null;
        if (self.length > std.math.maxInt(Length)) return null;
        
        return .{
            .offset = @intCast(self.offset),
            .length = @intCast(self.length),
        };
    }
};

// A reference to a slice of the instructions array
const Fragment = struct {
    content: []const u8,
    first_instruction: usize,
    instruction_count: usize,
};

const Parser = @This();

pub fn deinit(self: *Parser) void {
    self.instructions.deinit(self.gpa);
    self.fragments.deinit(self.gpa);
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
    while (!self.try_token(.eof)) {
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

pub fn get_fragment(self: *Parser, allocator: std.mem.Allocator, name: []const u8) !?Template {
    if (self.fragments.get(name)) |frag| {
        const ops = self.instructions.items(.op)[frag.first_instruction..][0..frag.instruction_count];
        const data = self.instructions.items(.data)[frag.first_instruction..][0..frag.instruction_count];
        return try Template.init(allocator, ops, data, self.literal_data.items);
    }
    return null;
}

pub fn finish(self: *Parser, allocator: std.mem.Allocator, clear_literal_data: bool) !Template {
    const ops = self.instructions.items(.op);
    const data = self.instructions.items(.data);
    const template = try Template.init(allocator, ops, data, self.literal_data.items);

    self.instructions.len = 0;
    self.ref_stack_depth = 0;
    self.fragments.clearRetainingCapacity();
    
    if (clear_literal_data) {
        self.literal_data.clearRetainingCapacity();
        self.literal_dedup.clearRetainingCapacity();
    }

    return template;
}

fn parse_block(self: *Parser) anyerror!void {
    while (try self.parse_item()) {}
}

fn parse_item(self: *Parser) !bool {
    switch (self.token_kinds[self.next_token]) {
        .literal => {
            const initial_span = self.token_spans[self.next_token];
            self.next_token += 1;

            if (initial_span.len == 0) return true;

            var literal_ref = try self.intern_literal(initial_span);
            while (self.token_kinds[self.next_token] == .literal) {
                const next_span = self.token_spans[self.next_token];
                if (next_span.len == 0) {
                    self.next_token += 1;
                    continue;
                }

                const next_ref = try self.intern_literal(next_span);

                if (literal_ref.offset + literal_ref.length != next_ref.offset) break;

                literal_ref.length += next_ref.length;
                self.next_token += 1;
            }
            
            try self.add_literal_ref_instruction(.print_literal, literal_ref);
            return true;
        },
        .fragment => {
            self.next_token += 1;
            const fragment_token = self.next_token;
            const fragment = try self.require_id();
            const begin_token = self.next_token;
            const begin = self.pc();
            try self.parse_block();
            const end = self.pc();
            const end_token = self.next_token;
            _ = try self.require_token(.end);

            const src = self.include_stack.getLast();
            const spans = src.tokens.items(.span);
            const begin_ptr = spans[begin_token].ptr;

            const gop = try self.fragments.getOrPut(self.gpa, fragment);
            if (gop.found_existing) {
                if (gop.value_ptr.content.ptr != begin_ptr) {
                    try self.include_stack.getLast().report_error(fragment_token, "Ignoring fragment definition; it has already been defined elsewhere!");
                }
            } else {
                const begin_offset = @intFromPtr(begin_ptr) - @intFromPtr(src.source.ptr);
                const end_offset = @intFromPtr(spans[end_token].ptr) - @intFromPtr(src.source.ptr);
                gop.key_ptr.* = try self.gpa.dupe(u8, fragment);
                gop.value_ptr.* = .{
                    .content = src.source[begin_offset..end_offset],
                    .first_instruction = begin,
                    .instruction_count = end - begin,
                };
            }
            return true;
        },
        .kw_resource => {
            self.next_token += 1;
            const id = try self.require_id();
            if (self.resource_callback(id)) |literal| {
                try self.add_print_literal_instruction(literal);
            } else |err| {
                try self.include_stack.getLast().report_error(self.next_token - 1, @errorName(err));
            }
            return true;
        },
        .kw_include => {
            self.next_token += 1;
            const id = try self.require_id();
            if (self.include_callback(id)) |source| {
                try self.append(source);
            } else |err| {
                try self.include_stack.getLast().report_error(self.next_token - 1, @errorName(err));
            }
            return true;
        },
        .kw_raw => {
            self.next_token += 1;
            if (try self.parse_expression()) {
                try self.add_basic_instruction(.print_ref_raw);
            } else {
                try self.include_stack.getLast().report_error(self.next_token, "Expected value reference");
            }
            return true;
        },
        .kw_url => {
            self.next_token += 1;
            if (try self.parse_expression()) {
                try self.add_basic_instruction(.print_ref_url);
            } else {
                try self.include_stack.getLast().report_error(self.next_token, "Expected value reference");
            }
            return true;
        },
        else => {
            if (try self.parse_expression()) {
                if (!(try self.parse_condition()) and !(try self.parse_within())) {
                    try self.add_basic_instruction(.print_ref_escaped);
                }
                return true;
            }
            return false;
        },
    }
}

fn parse_condition(self: *Parser) !bool {
    if (!self.try_token(.condition)) return false;

    try self.add_basic_instruction(.as_number);
    const conditional_jump_instruction = self.pc();
    try self.add_offset_instruction(.pop_and_skip_if_zero, 0); // to else block or end of block
    try self.parse_block();

    if (self.try_token(.otherwise)) {
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
    if (!self.try_token(.within)) return false;

    try self.add_basic_instruction(.begin_loop);
    const skip_if_equal_instruction = self.pc();
    try self.add_offset_instruction(.skip_if_equal, 0); // to else block or end of block
    const loop_begin_instruction = self.pc();
    try self.add_basic_instruction(.dupe_ref_0_indexed);
    try self.parse_block();
    try self.add_basic_instruction(.pop_ref);

    try self.add_loop_instruction(.increment_and_retry_if_less, loop_begin_instruction);
    self.finalize_skip_instruction(skip_if_equal_instruction, self.pc());
    try self.add_basic_instruction(.end_loop);
    
    if (self.try_token(.otherwise)) {
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

fn parse_expression(self: *Parser) !bool {
    if (self.try_token(.open_paren)) {
        if (!try self.parse_expression()) {
            try self.include_stack.getLast().report_error(self.next_token, "Expected expression");
            return error.InvalidTemplate;
        }
        try self.require_token(.close_paren);
    } else if (!try self.parse_ref()) return false;

    while (self.try_token(.child)) {
        if (try self.parse_field_or_index_or_count()) continue;

        if (self.try_token(.kw_exists)) {
            try self.add_basic_instruction(.is_ref_nonnil);
            continue;
        }

        try self.include_stack.getLast().report_error(self.next_token, "Expected field name, index, '#', or '@exists'");
        return error.InvalidTemplate;
    }
    
    if (self.try_token(.fallback)) {
        try self.add_basic_instruction(.dupe_ref_0);
        try self.add_basic_instruction(.is_ref_nonnil);
        try self.add_basic_instruction(.as_number);
        const conditional_jump_instruction = self.pc();
        try self.add_offset_instruction(.pop_and_skip_if_nonzero, 0); // to end of expression
        try self.add_basic_instruction(.pop_ref);
        if (!try self.parse_expression()) {
            try self.add_basic_instruction(.push_nil);
        }
        self.finalize_skip_instruction(conditional_jump_instruction, self.pc());
    } else if (self.try_token(.alternative)) {
        try self.add_basic_instruction(.dupe_ref_0);
        try self.add_basic_instruction(.as_number);
        const conditional_jump_instruction = self.pc();
        try self.add_offset_instruction(.pop_and_skip_if_nonzero, 0); // to end of expression
        try self.add_basic_instruction(.pop_ref);
        if (!try self.parse_expression()) {
            try self.add_basic_instruction(.push_nil);
        }
        self.finalize_skip_instruction(conditional_jump_instruction, self.pc());
    }

    return true;
}

fn parse_ref(self: *Parser) !bool {
    switch (self.token_kinds[self.next_token]) {
        .invalid, .eof, .literal, .kw_resource, .kw_include, .kw_raw, .kw_url,
        .condition, .within, .otherwise, .end, .child, .fallback, .alternative,
        .kw_exists, .open_paren, .close_paren, .fragment => return false,
        .id, .number, .parent, .kw_count, .self, .kw_index => {},
    }

    if (self.try_token(.self)) {
        try self.add_basic_instruction(.dupe_ref_0);
        return true;
    } else if (self.try_token(.kw_index)) {
        try self.add_basic_instruction(.push_loop_index);
        return true;
    }

    var parent_count: u32 = 0;
    while (self.try_token(.parent)) parent_count += 1;

    if (parent_count == 0) {
        if (self.try_id()) |field_name| {
            try self.add_literal_instruction(.push_field, field_name);
            return true;
        }

        try self.add_basic_instruction(.dupe_ref_0);
        if (!try self.parse_field_or_index_or_count()) {
            try self.include_stack.getLast().report_error(self.next_token, "Expected field name, index, or '#'");
            return error.InvalidTemplate;
        }
        return true;
    }

    if (parent_count > self.ref_stack_depth) {
        var buf: [128]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "Not enough parent data contexts; only {} exist", .{ self.ref_stack_depth });
        try self.include_stack.getLast().report_error(self.next_token - 1, msg);
        parent_count = self.ref_stack_depth;
    }

    try self.add_offset_instruction(.dupe_ref, parent_count);
    if (!try self.parse_field_or_index_or_count()) {
        try self.include_stack.getLast().report_error(self.next_token, "Expected field name, index, or '#'");
        return error.InvalidTemplate;
    }

    return true;
}

fn parse_field_or_index_or_count(self: *Parser) !bool {
    if (self.try_id()) |field_name| {
        try self.add_literal_instruction(.field, field_name);

    } else if (self.try_token(.number)) {
        const index_str = self.token_spans[self.next_token - 1];
        const index = try std.fmt.parseInt(u32, index_str, 10);
        try self.add_offset_instruction(.index, index);

    } else if (self.try_token(.kw_count)) {
        try self.add_basic_instruction(.as_number);
        try self.add_basic_instruction(.number_to_ref);

    } else {
        return false;
    }
    return true;
}

fn try_id(self: *Parser) ?[]const u8 {
    if (self.token_kinds[self.next_token] == .id) {
        const span = self.token_spans[self.next_token];
        self.next_token += 1;
        return span;
    }
    return null;
}

fn try_token(self: *Parser, kind: Token.Kind) bool {
    if (self.token_kinds[self.next_token] == kind) {
        self.next_token += 1;
        return true;
    }
    return false;
}

fn require_id(self: *Parser) ![]const u8 {
    if (self.try_id()) |span| return span;
    try self.include_stack.getLast().report_error(self.next_token, "Expected id");
    return error.InvalidTemplate;
}

fn require_token(self: *Parser, comptime kind: Token.Kind) !void {
    if (self.try_token(kind)) return;
    try self.include_stack.getLast().report_error(self.next_token, "Expected " ++ @tagName(kind));
    return error.InvalidTemplate;
}

fn add_print_literal_instruction(self: *Parser, literal: []const u8) !void {
    if (literal.len == 0) return;
    try self.add_literal_instruction(.print_literal, literal);
}

fn pc(self: *Parser) u32 {
    return @intCast(self.instructions.len);
}

fn add_basic_instruction(self: *Parser, op: Template.Opcode) !void {
    switch (op) {
        .print_literal, // literal_ref
        .field, // literal_ref
        .push_field, // literal_ref
        .index, // offset
        .dupe_ref, // offset
        .pop_and_skip_if_zero, // offset
        .pop_and_skip_if_nonzero, // offset
        .skip, // offset
        .skip_if_equal, // offset
        .increment_and_retry_if_less, // offset
        .push_var,
        .print_literal_var_len,
        .field_var_len,
        .push_field_var_len,
        => unreachable,

        .print_ref_raw,
        .print_ref_escaped,
        .print_ref_url,
        .as_number,
        .end_loop,
        .pop_ref,
        => {
            self.ref_stack_depth -= 1;
        },

        .begin_loop,
        .is_ref_nonnil,
        => {},

        .dupe_ref_0,
        .dupe_ref_0_indexed,
        .number_to_ref,
        .push_loop_index,
        .push_nil,
        => try self.check_and_increment_ref_stack(),
    }
    try self.instructions.append(self.gpa, .{
        .op = op,
        .data = .{ .none = {} },
    });
}

fn add_offset_instruction(self: *Parser, op: Template.Opcode, offset: u32) !void {
    switch (op) {
        .print_literal, // literal_ref
        .print_ref_raw,
        .print_ref_escaped,
        .print_ref_url,
        .push_loop_index,
        .field, // literal_ref
        .push_field, // literal_ref
        .as_number,
        .number_to_ref,
        .dupe_ref_0,
        .begin_loop,
        .end_loop,
        .dupe_ref_0_indexed,
        .pop_ref,
        .is_ref_nonnil,
        .push_nil,
        .increment_and_retry_if_less, // offset
        => unreachable,

        .index, // offset
        .pop_and_skip_if_zero, // offset
        .pop_and_skip_if_nonzero, // offset
        .skip, // offset
        .skip_if_equal, // offset
        .push_var,
        => {},

        .dupe_ref, // offset
        => try self.check_and_increment_ref_stack(),

        .print_literal_var_len,
        .field_var_len,
        .push_field_var_len,
        => unreachable, // these are offset instructions, but they should be handled with add_literal_ref_instruction
    }
    try self.instructions.append(self.gpa, .{
        .op = op,
        .data = .{ .offset = offset },
    });
}

fn add_loop_instruction(self: *Parser, op: Template.Opcode, target_address: u32) !void {
    switch (op) {
        .print_literal, // literal_ref
        .field, // literal_ref
        .push_field, // literal_ref
        .print_ref_raw,
        .print_ref_escaped,
        .print_ref_url,
        .push_loop_index,
        .as_number,
        .number_to_ref,
        .dupe_ref_0,
        .index, // offset
        .dupe_ref, // offset
        .begin_loop,
        .end_loop,
        .dupe_ref_0_indexed,
        .pop_ref,
        .is_ref_nonnil,
        .push_nil,
        .skip_if_equal, // offset
        .pop_and_skip_if_zero, // offset
        .pop_and_skip_if_nonzero, // offset
        .skip, // offset
        .push_var,
        .print_literal_var_len,
        .field_var_len,
        .push_field_var_len,
        => unreachable,

        .increment_and_retry_if_less, // offset
        => {},
    }
    const pc_delta = self.pc() - target_address;
    try self.instructions.append(self.gpa, .{
        .op = op,
        .data = .{ .offset = pc_delta },
    });
}

fn add_literal_instruction(self: *Parser, op: Template.Opcode, literal: []const u8) !void {
    try self.add_literal_ref_instruction(op, try self.intern_literal(literal));
}
fn add_literal_ref_instruction(self: *Parser, op: Template.Opcode, literal_ref: Literal_Ref) !void {
    switch (op) {
        .print_literal, // literal_ref
        .field, // literal_ref
        => {},

        .push_field, // literal_ref
        => try self.check_and_increment_ref_stack(),

        .print_ref_raw,
        .print_ref_escaped,
        .print_ref_url,
        .push_loop_index,
        .as_number,
        .number_to_ref,
        .dupe_ref_0,
        .index, // offset
        .dupe_ref, // offset
        .pop_and_skip_if_zero, // offset
        .pop_and_skip_if_nonzero, // offset
        .skip, // offset
        .begin_loop,
        .end_loop,
        .skip_if_equal, // offset
        .dupe_ref_0_indexed,
        .pop_ref,
        .increment_and_retry_if_less, // offset
        .is_ref_nonnil,
        .push_nil,
        .print_literal_var_len,
        .field_var_len,
        .push_field_var_len,
        .push_var,
        => unreachable,
    }

    if (literal_ref.small()) |ref| {
        try self.instructions.append(self.gpa, .{
            .op = op,
            .data = .{ .literal_string = @bitCast(ref) },
        });
    } else {
        try self.instructions.append(self.gpa, .{
            .op = .push_var,
            .data = .{ .offset = literal_ref.length },
        });
        try self.instructions.append(self.gpa, .{
            .op = switch (op) {
                .print_literal => .print_literal_var_len,
                .field => .field_var_len,
                .push_field => .push_field_var_len,
                else => unreachable,
            },
            .data = .{ .offset = literal_ref.offset },
        });
    }
}

fn finalize_skip_instruction(self: *Parser, instruction_address: u32, target_address: u32) void {
    switch (self.instructions.items(.op)[instruction_address]) {
        .print_literal, // literal_ref
        .field, // literal_ref
        .push_field, // literal_ref
        .print_ref_raw,
        .print_ref_escaped,
        .print_ref_url,
        .push_loop_index,
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
        .is_ref_nonnil,
        .push_nil,
        .push_var,
        .print_literal_var_len,
        .field_var_len,
        .push_field_var_len,
        => unreachable,

        .skip_if_equal, // offset
        .pop_and_skip_if_zero, // offset
        .pop_and_skip_if_nonzero, // offset
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

fn intern_literal(self: *Parser, literal: []const u8) !Literal_Ref {
    if (self.literal_dedup.get(literal)) |ref| return ref;

    const start = self.literal_data.items.len;
    try self.literal_data.appendSlice(self.gpa, literal);

    const ref: Literal_Ref = .{
        .offset = @intCast(start),
        .length = @intCast(literal.len),
    };

    try self.literal_dedup.put(self.gpa, literal, ref);
    return ref;
}

const Template = @import("Template.zig");
const Source = @import("Source.zig");
const Token = @import("Token.zig");
const std = @import("std");
