pub const Parser = @import("Parser.zig");
pub const Source = @import("Source.zig");
pub const Token = @import("Token.zig");
pub const escape = @import("escape.zig");

const Template = @This();

pub const Extension_Function = fn(root_ref: Ref, args: []const Ref, writer: std.io.AnyWriter, escape_fn: *const escape.Fn, url_fn: *const escape.Fn) anyerror!void;

pub const Render_Options = struct {
    Context: type = struct {},
    escape_fn: *const escape.Fn = escape.html,
    url_fn: *const escape.Fn = escape.url,
};

pub fn render(self: Template, writer: std.io.AnyWriter, obj: anytype, comptime options: Render_Options) anyerror!void {
    try self.execute(writer, make_ref(@TypeOf(obj), &obj, options.Context), options.escape_fn, options.url_fn);
}

pub const max_stack_size = 31;

pub const Opcode = enum (u8) {
    push_var, // offset -- should be followed immediately by push_literal_var_len, print_literal_var_len, field_var_len, push_field_var_len, etc.
    push_literal, // literal_string
    push_literal_var_len, // offset
    print_literal, // literal_string
    print_literal_var_len, // offset
    as_number,
    print_ref_raw,
    print_ref_escaped,
    print_ref_url,
    field, // literal_string
    field_var_len, // offset
    push_field, // literal_string
    push_field_var_len, // offset
    index, // offset
    begin_loop,
    end_loop,
    number_to_ref,
    skip, // offset
    pop_ref,
    dupe_ref, // offset
    dupe_ref_0,
    skip_if_equal, // offset
    pop_and_skip_if_zero, // offset
    pop_and_skip_if_nonzero, // offset
    dupe_ref_0_indexed,
    increment_and_retry_if_less, // offset
    push_loop_index,
    is_ref_nonnil,
    push_nil,
    call_func, // offset
};

pub const Operands = extern union {
    none: void,
    offset: u32,
    literal_string: u32,

    pub fn literal_ref(self: Operands) Literal_Ref {
        return @bitCast(self.literal_string);
    }
};

pub const Literal_Ref = packed struct {
    offset: u23,
    length: u9,
};

pub const Ref = union (enum) {
    nil,
    collection: Collection,
    value: Value,
    inline_value: Inline_Value,
    string_literal: []const u8,
    func: *const Extension_Function,
};

pub const Collection = struct {
    data: *const anyopaque,
    size: usize,
    element: *const fn(self: *const anyopaque, index: usize) Ref,
};

pub const Value = struct {
    data: *const anyopaque,
    as_number: *const fn (self: *const anyopaque) usize,
    field: *const fn(self: *const anyopaque, name: []const u8) Ref,
    print: *const fn(self: *const anyopaque, writer: std.io.AnyWriter) anyerror!void,
};

/// Instead of pointing to a number, just store it directly
pub const Inline_Value = struct {
    data: usize,
    field: *const fn(self: usize, name: []const u8) Ref,
    print: *const fn(self: usize, writer: std.io.AnyWriter) anyerror!void,
};

opcodes: []const Opcode,
operands: [*]const Operands,
literal_data: []const u8,

pub fn init_static(comptime op_data: []const u8, comptime operand_data: []const u32, comptime literal_data: []const u8) Template {
    std.debug.assert(op_data.len == operand_data.len);
    const ops: []const Opcode = @ptrCast(op_data);
    const operands: []const Operands = @ptrCast(operand_data);
    return .{
        .opcodes = ops,
        .operands = operands.ptr,
        .literal_data = literal_data,
    };
}

pub fn init(allocator: std.mem.Allocator, ops: []const Opcode, operands: []const Operands, literal_data: []const u8) !Template {
    std.debug.assert(ops.len == operands.len);

    const owned_opcodes = try allocator.dupe(Opcode, ops);
    errdefer allocator.free(owned_opcodes);

    const owned_operands = try allocator.dupe(Operands, operands);
    errdefer allocator.free(owned_operands);

    const owned_literal_data = try allocator.dupe(u8, literal_data);
    errdefer allocator.free(owned_literal_data);

    return .{
        .opcodes = owned_opcodes,
        .operands = owned_operands.ptr,
        .literal_data = owned_literal_data,
    };
}

pub fn deinit(self: *Template, allocator: std.mem.Allocator) void {
    allocator.free(self.literal_data);
    allocator.free(self.operands[0..self.opcodes.len]);
    allocator.free(self.opcodes);
}

fn literal(self: Template, pc: usize) []const u8 {
    const ref = self.operands[pc].literal_ref();
    return self.literal_data[ref.offset..][0..ref.length];
}

pub fn print_ref(ref: Ref, writer: std.io.AnyWriter, escape_fn: ?*const escape.Fn) anyerror!void {
    switch (ref) {
        .nil, .func => {},
        .collection => |c| if (escape_fn) |func| {
            const w = escape.writer(writer, func);
            for (0..c.size) |i| {
                try print_ref(c.element(c.data, i), w.any(), null);
            }
        } else {
            for (0..c.size) |i| {
                try print_ref(c.element(c.data, i), writer, null);
            }
        },
        .value => |v| if (escape_fn) |func| {
            const w = escape.writer(writer, func);
            try v.print(v.data, w.any());
        } else {
            try v.print(v.data, writer);
        },
        .inline_value => |v| if (escape_fn) |func| {
            const w = escape.writer(writer, func);
            try v.print(v.data, w.any());
        } else {
            try v.print(v.data, writer);
        },
        .string_literal => |v| if (escape_fn) |func| {
            try escape.writer(writer, func).writeAll(v);
        } else {
            try writer.writeAll(v);
        },
    }
}

pub fn ref_to_number(ref: Ref) usize {
    return switch (ref) {
        .nil, .func => 0,
        .collection => |c| c.size,
        .value => |v| v.as_number(v.data),
        .inline_value => |v| v.data,
        .string_literal => |v| @intFromBool(v.len > 0),
    };
}

fn number_ref(n: usize) Ref {
    const vtable = struct {
        pub fn field(self: usize, name: []const u8) Ref {
            _ = self;
            _ = name;
            return .nil;
        }
        pub fn print(self: usize, writer: std.io.AnyWriter) anyerror!void {
            try writer.print("{d}", .{ self });
        }
    };

    return .{ .inline_value = .{
        .data = n,
        .field = vtable.field,
        .print = vtable.print,
    }};
}

fn bool_ref(b: bool) Ref {
    const vtable = struct {
        pub fn field(self: usize, name: []const u8) Ref {
            _ = self;
            _ = name;
            return .nil;
        }
        pub fn print(self: usize, writer: std.io.AnyWriter) anyerror!void {
            try writer.print("{}", .{ self != 0 });
        }
    };

    return .{ .inline_value = .{
        .data = @intFromBool(b),
        .field = vtable.field,
        .print = vtable.print,
    }};
}

fn lookup_field(ref: Ref, name: []const u8, pc: usize) !Ref {
    return switch (ref) {
        .nil, .func => .nil,
        .collection => {
            log.debug("Expected struct with field named {s}; found collection (pc={d})", .{ name, pc });
            return .nil;
        },
        .value => |v| v.field(v.data, name),
        .inline_value => |v| v.field(v.data, name),
        .string_literal => |v| {
            if (std.mem.eql(u8, name, "len")) {
                return number_ref(v.len);
            } else {
                return .nil;
            }
        },
    };
}

fn lookup_index(ref: Ref, index: usize, pc: usize) !Ref {
    switch (ref) {
        .nil, .func => return .nil,
        .collection => |c| {
            if (index < c.size) {
                return c.element(c.data, index);
            } else {
                log.debug("Expected collection of size > {d}; found size {d} (pc={d})", .{ index, c.size, pc });
                return .nil;
            }
        },
        .value, .inline_value, .string_literal => {
            if (index == 0) {
                // This is needed for the "within" syntax
                return ref;
            }
            log.debug("Expected collection of size > {d}; found value (pc={d})", .{ index, pc });
            return .nil;
        },
    }
}

pub fn execute(self: Template, writer: std.io.AnyWriter, root_ref: Ref, escape_fn: *const escape.Fn, url_fn: *const escape.Fn) anyerror!void {
    const opcodes = self.opcodes;

    var variables: [max_stack_size + 1]usize = .{ 0 } ** (max_stack_size + 1);
    var refs: [max_stack_size + 1]Ref = undefined;
    refs[0] = root_ref;

    var variable_sp: usize = 0;
    var ref_sp: usize = 1;

    var pc: usize = 0;
    while (pc < opcodes.len) {
        switch (opcodes[pc]) {
            .push_var => {
                const offset = self.operands[pc].offset;
                log.debug("{}: push_var: var={} n={}", .{ pc, variable_sp, offset });
                variables[variable_sp] = offset;
                variable_sp += 1;
                pc += 1;
            },
            .push_literal => {
                const lit = self.literal(pc);
                log.debug("{}: push_literal: ref={} lit={}", .{ pc, ref_sp, std.zig.fmtEscapes(lit) });
                refs[ref_sp] = .{ .string_literal = lit };
                ref_sp += 1;
                pc += 1;
            },
            .push_literal_var_len => {
                if (variable_sp == 0) return error.InvalidTemplate;
                const offset = self.operands[pc].offset;
                const len = variables[variable_sp - 1];
                const lit = self.literal_data[offset..][0..len];
                log.debug("{}: push_literal_var_len: ref={} name={s}", .{ pc, ref_sp, lit });
                refs[ref_sp] = .{ .string_literal = lit };
                ref_sp += 1;
                variable_sp -= 1;
                pc += 1;
            },
            .print_literal => {
                const lit = self.literal(pc);
                log.debug("{}: print_literal: {}", .{ pc, std.zig.fmtEscapes(lit) });
                try writer.writeAll(lit);
                pc += 1;
            },
            .print_literal_var_len => {
                if (variable_sp == 0) return error.InvalidTemplate;
                const offset = self.operands[pc].offset;
                const len = variables[variable_sp - 1];
                const lit = self.literal_data[offset..][0..len];
                log.debug("{}: print_literal_var_len: {}", .{ pc, std.zig.fmtEscapes(lit) });
                try writer.writeAll(lit);
                variable_sp -= 1;
                pc += 1;
            },
            .print_ref_raw => {
                if (ref_sp == 0) return error.InvalidTemplate;
                ref_sp -= 1;
                log.debug("{}: print_ref_raw: ref={}", .{ pc, ref_sp });
                try print_ref(refs[ref_sp], writer, null);
                pc += 1;
            },
            .print_ref_escaped => {
                if (ref_sp == 0) return error.InvalidTemplate;
                ref_sp -= 1;
                log.debug("{}: print_ref_escaped: ref={}", .{ pc, ref_sp });
                try print_ref(refs[ref_sp], writer, escape_fn);
                pc += 1;
            },
            .print_ref_url => {
                if (ref_sp == 0) return error.InvalidTemplate;
                ref_sp -= 1;
                log.debug("{}: print_ref_url: ref={}", .{ pc, ref_sp });
                try print_ref(refs[ref_sp], writer, url_fn);
                pc += 1;
            },
            .push_loop_index => {
                if (variable_sp > 0) {
                    log.debug("{}: push_loop_index: ref={}, var={}", .{ pc, ref_sp, variable_sp - 1 });
                    refs[ref_sp] = number_ref(variables[variable_sp - 1]);
                } else {
                    log.debug("{}: push_loop_index: ref={}, (nil)", .{ pc, ref_sp });
                    refs[ref_sp] = .nil;
                }
                ref_sp += 1;
                pc += 1;
            },
            .field => {
                if (ref_sp == 0) return error.InvalidTemplate;
                const lit = self.literal(pc);
                log.debug("{}: field: ref={} name={s}", .{ pc, ref_sp - 1, lit });
                refs[ref_sp - 1] = try lookup_field(refs[ref_sp - 1], lit, pc);
                pc += 1;
            },
            .field_var_len => {
                if (ref_sp == 0) return error.InvalidTemplate;
                if (variable_sp == 0) return error.InvalidTemplate;
                const offset = self.operands[pc].offset;
                const len = variables[variable_sp - 1];
                const lit = self.literal_data[offset..][0..len];
                log.debug("{}: field_var_len: ref={} name={s}", .{ pc, ref_sp - 1, lit });
                refs[ref_sp - 1] = try lookup_field(refs[ref_sp - 1], lit, pc);
                variable_sp -= 1;
                pc += 1;
            },
            .push_field => {
                if (ref_sp == 0) return error.InvalidTemplate;
                const lit = self.literal(pc);
                log.debug("{}: push_field: ref={} name={s}", .{ pc, ref_sp, lit });
                var i = ref_sp;
                while (i > 0) : (i -= 1) {
                    const ref = try lookup_field(refs[i - 1], lit, pc);
                    if (ref != .nil) {
                        refs[ref_sp] = ref;
                        break;
                    }
                } else {
                    refs[ref_sp] = .nil;
                }
                ref_sp += 1;
                pc += 1;
            },
            .push_field_var_len => {
                if (ref_sp == 0) return error.InvalidTemplate;
                if (variable_sp == 0) return error.InvalidTemplate;
                const offset = self.operands[pc].offset;
                const len = variables[variable_sp - 1];
                const lit = self.literal_data[offset..][0..len];
                log.debug("{}: push_field_var_len: ref={} name={s}", .{ pc, ref_sp, lit });
                var i = ref_sp;
                while (i > 0) : (i -= 1) {
                    const ref = try lookup_field(refs[i - 1], lit, pc);
                    if (ref != .nil) {
                        refs[ref_sp] = ref;
                        break;
                    }
                } else {
                    refs[ref_sp] = .nil;
                }
                ref_sp += 1;
                variable_sp -= 1;
                pc += 1;
            },
            .index => {
                if (ref_sp == 0) return error.InvalidTemplate;
                const index = self.operands[pc].offset;
                log.debug("{}: index: ref={} [{}]", .{ pc, ref_sp - 1, index });
                refs[ref_sp - 1] = try lookup_index(refs[ref_sp - 1], index, pc);
                pc += 1;
            },
            .as_number => {
                if (ref_sp == 0) return error.InvalidTemplate;
                ref_sp -= 1;
                const number = ref_to_number(refs[ref_sp]);
                log.debug("{}: as_number: ref={} var={} num={}", .{ pc, ref_sp, variable_sp, number });
                variables[variable_sp] = number;
                variable_sp += 1;
                pc += 1;
            },
            .number_to_ref => {
                if (variable_sp == 0) return error.InvalidTemplate;
                variable_sp -= 1;
                log.debug("{}: number_to_ref: var={} ref={}", .{ pc, variable_sp, ref_sp });
                refs[ref_sp] = number_ref(variables[variable_sp]);
                ref_sp += 1;
                pc += 1;
            },
            .dupe_ref => {
                const offset = self.operands[pc].offset;
                if (ref_sp <= offset) return error.InvalidTemplate;
                log.debug("{}: dupe_ref: [ref={}] -> ref={}", .{ pc, ref_sp - offset - 1, ref_sp });
                refs[ref_sp] = refs[ref_sp - offset - 1];
                ref_sp += 1;
                pc += 1;
            },
            .dupe_ref_0 => {
                if (ref_sp == 0) return error.InvalidTemplate;
                log.debug("{}: dupe_ref_0: ref={}", .{ pc, ref_sp });
                refs[ref_sp] = refs[ref_sp - 1];
                ref_sp += 1;
                pc += 1;
            },
            .pop_and_skip_if_zero => {
                if (variable_sp == 0) return error.InvalidTemplate;
                variable_sp -= 1;
                const value = variables[variable_sp];
                const offset = self.operands[pc].offset;
                log.debug("{}: pop_and_skip_if_zero: var={} val={} offset={}", .{ pc, variable_sp, value, offset });
                if (value == 0) {
                    pc += offset + 1;
                } else {
                    pc += 1;
                }
            },
            .pop_and_skip_if_nonzero => {
                if (variable_sp == 0) return error.InvalidTemplate;
                variable_sp -= 1;
                const value = variables[variable_sp];
                const offset = self.operands[pc].offset;
                log.debug("{}: pop_and_skip_if_zero: var={} val={} offset={}", .{ pc, variable_sp, value, offset });
                if (value != 0) {
                    pc += offset + 1;
                } else {
                    pc += 1;
                }
            },
            .skip => {
                const offset = self.operands[pc].offset;
                log.debug("{}: skip: offset={}", .{ pc, offset });
                pc += offset + 1;
            },
            .begin_loop => {
                variables[variable_sp] = ref_to_number(refs[ref_sp - 1]);
                variables[variable_sp + 1] = 0;
                log.debug("{}: begin_loop: ref={} var={} [{}] var={} [0]", .{ pc, ref_sp - 1, variable_sp, variables[variable_sp], variable_sp + 1 });
                variable_sp += 2;
                pc += 1;
            },
            .end_loop => {
                if (ref_sp == 0) return error.InvalidTemplate;
                if (variable_sp < 2) return error.InvalidTemplate;
                log.debug("{}: end_loop", .{ pc });
                variable_sp -= 2;
                ref_sp -= 1;
                pc += 1;
            },
            .skip_if_equal => {
                if (variable_sp < 2) return error.InvalidTemplate;
                const val1 = variables[variable_sp - 1];
                const val2 = variables[variable_sp - 2];
                const offset = self.operands[pc].offset;
                log.debug("{}: skip_if_equal: val-2={} val-1={}, offset={}", .{ pc, val2, val1, offset });
                if (val1 == val2) {
                    pc += offset + 1;
                } else {
                    pc += 1;
                }
            },
            .dupe_ref_0_indexed => {
                if (ref_sp == 0) return error.InvalidTemplate;
                if (variable_sp == 0) return error.InvalidTemplate;
                log.debug("{}: dupe_ref_0_indexed: ref={} var={} [{}]", .{ pc, ref_sp - 1, variable_sp - 1, variables[variable_sp - 1] });
                refs[ref_sp] = try lookup_index(refs[ref_sp - 1], variables[variable_sp - 1], pc);
                ref_sp += 1;
                pc += 1;
            },
            .pop_ref => {
                if (ref_sp == 0) return error.InvalidTemplate;
                log.debug("{}: pop_ref: ref={}", .{ pc, ref_sp - 1 });
                ref_sp -= 1;
                pc += 1;
            },
            .increment_and_retry_if_less => {
                if (variable_sp < 2) return error.InvalidTemplate;
                const compare = variables[variable_sp - 2];
                const new = variables[variable_sp - 1] + 1;
                const offset = self.operands[pc].offset;
                log.debug("{}: increment_and_retry_if_less: inc_var={} [{}] compare_var={} [{}], addr={}", .{ pc, variable_sp - 1, new, variable_sp - 2, compare, pc - offset });
                variables[variable_sp - 1] = new;
                if (new < compare) {
                    pc -= offset;
                } else {
                    pc += 1;
                }
            },
            .is_ref_nonnil => {
                if (ref_sp == 0) return error.InvalidTemplate;
                log.debug("{}: is_ref_nonnil: ref={}", .{ pc, ref_sp - 1 });
                refs[ref_sp - 1] = bool_ref(refs[ref_sp - 1] != .nil);
                pc += 1;
            },
            .push_nil => {
                refs[ref_sp] = .nil;
                ref_sp += 1;
                pc += 1;
            },
            .call_func => {
                const num_params = self.operands[pc].offset;
                if (ref_sp < num_params + 2) return error.InvalidTemplate;
                const fn_ref = ref_sp - num_params - 1;
                log.debug("{}: call_func: fn={} params={}", .{ pc, fn_ref, num_params });
                const params = refs[fn_ref + 1 ..][0..num_params];
                switch (refs[fn_ref]) {
                    .nil, .collection, .value, .inline_value, .string_literal => {},
                    .func => |fn_ptr| try fn_ptr(refs[0], params, writer, escape_fn, url_fn),
                }
                ref_sp = fn_ref;
                pc += 1;
            },
        }
    }
}

pub fn make_ref(comptime T: type, ptr: *const T, comptime Context: anytype) Ref {
    return switch (@typeInfo(T)) {
        .void, .undefined => .nil,
        .null => .{ .collection = .{
            .data = undefined,
            .size = 0,
            .element = Null_VTable.element,
        }},
        .bool => .{ .value = .{
            .data = ptr,
            .as_number = Bool_VTable(Context).as_number,
            .field = Bool_VTable(Context).field,
            .print = Bool_VTable(Context).print,
        }},
        .int => .{ .value = .{
            .data = ptr,
            .as_number = Int_VTable(T, Context).as_number,
            .field = Int_VTable(T, Context).field,
            .print = Int_VTable(T, Context).print,
        }},
        .comptime_int => number_ref(@as(usize, ptr.*)),
        .float => .{ .value = .{
            .data = ptr,
            .as_number = Float_VTable(T, Context).as_number,
            .field = Float_VTable(T, Context).field,
            .print = Float_VTable(T, Context).print,
        }},
        .@"enum" => .{ .value = .{
            .data = ptr,
            .as_number = Enum_VTable(T, Context).as_number,
            .field = Enum_VTable(T, Context).field,
            .print = Enum_VTable(T, Context).print,
        }},
        .pointer => |info| {
            switch (info.size) {
                .slice => {
                    if (info.child == u8) {
                        return .{ .value = .{
                            .data = @ptrCast(ptr),
                            .as_number = String_VTable(Context).as_number,
                            .field = String_VTable(Context).field,
                            .print = String_VTable(Context).print,
                        }};
                    } else {
                        return .{ .collection = .{
                            .data = @ptrCast(ptr.ptr),
                            .size = ptr.len,
                            .element = Array_VTable(info.child, Context).element,
                        }};
                    }
                },
                .many, .c => {
                    return make_ref(info.child, &ptr.*[0], Context);
                },
                .one => {
                    return make_ref(info.child, ptr.*, Context);
                },
            }
        },
        .array => |info| {
            if (info.child == u8) {
                return .{ .value = .{
                    .data = @ptrCast(ptr),
                    .as_number = Array_String_VTable(info.len, Context).as_number,
                    .field = Array_String_VTable(info.len, Context).field,
                    .print = Array_String_VTable(info.len, Context).print,
                }};
            } else {
                return .{ .collection = .{
                    .data = @ptrCast(ptr),
                    .size = info.len,
                    .element = Array_VTable(info.child, Context).element,
                }};
            }
        },
        .optional => |info| .{ .collection = .{
            .data = @ptrCast(ptr),
            .size = if (ptr.* == null) 0 else 1,
            .element = Optional_VTable(info.child, Context).element,
        }},
        .@"union" => |info| {
            if (info.tag_type == null) @compileError("Unions must be tagged");
            return .{ .value = .{
                .data = ptr,
                .as_number = Union_VTable(T, Context).as_number,
                .field = Union_VTable(T, Context).field,
                .print = Union_VTable(T, Context).print,
            }};
        },
        .@"struct" => |info| {
            if (info.is_tuple) {
                return .{ .collection = .{
                    .data = ptr,
                    .size = info.fields.len,
                    .element = Struct_VTable(T, Context).tuple_element,
                }};
            } else {
                return .{ .value = .{
                    .data = ptr,
                    .as_number = Struct_VTable(T, Context).as_number,
                    .field = Struct_VTable(T, Context).field,
                    .print = Struct_VTable(T, Context).print,
                }};
            }
        },
        .@"fn" => .{ .func = ptr },
        .error_union => @compileError("Can't serialize error set; did you forget a 'try'?"),
        else => @compileError("Unsupported type: " ++ @typeName(T)),
    };
}

pub const Null_VTable = struct {
    pub fn element(self: *const anyopaque, index: usize) Ref {
        _ = self;
        _ = index;
        return .nil;
    }
};

fn Bool_VTable(comptime Context: anytype) type {
    return struct {
        pub fn as_number(self: *const anyopaque) usize {
            const ptr: *const bool = @alignCast(@ptrCast(self));
            return @intFromBool(ptr.*);
        }

        pub fn field(self: *const anyopaque, name: []const u8) Ref {
            _ = self;
            _ = name;
            return .nil;
        }

        pub fn print(self: *const anyopaque, writer: std.io.AnyWriter) anyerror!void {
            const ptr: *const bool = @alignCast(@ptrCast(self));
            switch (@typeInfo(@TypeOf(Context))) {
                .@"fn" => try Context(ptr.*, writer),
                .pointer => try writer.print("{" ++ Context ++ "}", .{ ptr.* }),
                else => try writer.writeAll(if (ptr.*) "true" else "false"),
            }
        }
    };
}

fn Int_VTable(comptime T: type, comptime Context: anytype) type {
    return struct {
        pub fn as_number(self: *const anyopaque) usize {
            const ptr: *const T = @alignCast(@ptrCast(self));
            return @intCast(ptr.*);
        }

        pub fn field(self: *const anyopaque, name: []const u8) Ref {
            _ = self;
            _ = name;
            return .nil;
        }

        pub fn print(self: *const anyopaque, writer: std.io.AnyWriter) anyerror!void {
            const ptr: *const T = @alignCast(@ptrCast(self));
            switch (@typeInfo(@TypeOf(Context))) {
                .@"fn" => try Context(ptr.*, writer),
                .pointer => try writer.print("{" ++ Context ++ "}", .{ ptr.* }),
                else => try writer.print("{d}", .{ ptr.* }),
            }
        }
    };
}

fn Float_VTable(comptime T: type, comptime Context: anytype) type {
    return struct {
        pub fn as_number(self: *const anyopaque) usize {
            const ptr: *const T = @alignCast(@ptrCast(self));
            return @intFromFloat(ptr.*);
        }

        pub fn field(self: *const anyopaque, name: []const u8) Ref {
            _ = self;
            _ = name;
            return .nil;
        }

        pub fn print(self: *const anyopaque, writer: std.io.AnyWriter) anyerror!void {
            const ptr: *const T = @alignCast(@ptrCast(self));
            switch (@typeInfo(@TypeOf(Context))) {
                .@"fn" => try Context(ptr.*, writer),
                .pointer => try writer.print("{" ++ Context ++ "}", .{ ptr.* }),
                else => try writer.print("{d}", .{ ptr.* }),
            }
        }
    };
}

fn Enum_VTable(comptime T: type, comptime Context: anytype) type {
    return struct {
        pub fn as_number(self: *const anyopaque) usize {
            const ptr: *const T = @alignCast(@ptrCast(self));
            return @intCast(@intFromEnum(ptr.*));
        }

        pub fn field(self: *const anyopaque, name: []const u8) Ref {
            const ptr: *const T = @alignCast(@ptrCast(self));
            const ordinal = @intFromEnum(ptr.*);
            inline for (0.., @typeInfo(T).@"enum".fields) |i, f| {
                if (i == ordinal and std.mem.eql(u8, name, f.name)) {
                    return .{ .value = .{
                        .data = self,
                        .as_number = as_number,
                        .field = field,
                        .print = print,
                    }};
                }
            }
            inline for (@typeInfo(T).@"enum".decls) |d| {
                if (comptime std.mem.startsWith(u8, d.name, "zk_")) {
                    if (std.mem.eql(u8, name, d.name[3..])) {
                        return make_ref(@TypeOf(@field(T, d.name)), &@field(T, d.name), Child_Context(Context, d.name));
                    }
                }
            }
            return .nil;
        }

        pub fn print(self: *const anyopaque, writer: std.io.AnyWriter) anyerror!void {
            const ptr: *const T = @alignCast(@ptrCast(self));
            switch (@typeInfo(@TypeOf(Context))) {
                .@"fn" => try Context(ptr.*, writer),
                .pointer => try writer.print("{" ++ Context ++ "}", .{ ptr.* }),
                else => if (std.enums.tagName(T, ptr.*)) |name| {
                    try writer.writeAll(name);
                } else {
                    try writer.print("({d})", .{ @intFromEnum(ptr.*) });
                },
            }
        }
    };
}

fn String_VTable(comptime Context: anytype) type {
    return struct {
        pub fn as_number(self: *const anyopaque) usize {
            const ptr: *const []const u8 = @alignCast(@ptrCast(self));
            return @intFromBool(ptr.*.len > 0);
        }

        pub fn field(self: *const anyopaque, name: []const u8) Ref {
            const ptr: *const []const u8 = @alignCast(@ptrCast(self));
            if (std.mem.eql(u8, name, "len")) {
                return number_ref(ptr.len);
            }
            return .nil;
        }

        pub fn print(self: *const anyopaque, writer: std.io.AnyWriter) anyerror!void {
            const ptr: *const []const u8 = @alignCast(@ptrCast(self));
            switch (@typeInfo(@TypeOf(Context))) {
                .@"fn" => try Context(ptr.*, writer),
                .pointer => try writer.print("{" ++ Context ++ "}", .{ ptr.* }),
                else => try writer.writeAll(ptr.*),
            }
        }
    };
}

fn Array_String_VTable(comptime length: usize, comptime Context: anytype) type {
    return struct {
        pub fn as_number(self: *const anyopaque) usize {
            _ = self;
            return @intFromBool(length > 0);
        }

        pub fn field(self: *const anyopaque, name: []const u8) Ref {
            _ = self;
            if (std.mem.eql(u8, name, "len")) {
                return number_ref(length);
            }
            return .nil;
        }

        pub fn print(self: *const anyopaque, writer: std.io.AnyWriter) anyerror!void {
            const ptr: *const [length]u8 = @alignCast(@ptrCast(self));
            switch (@typeInfo(@TypeOf(Context))) {
                .@"fn" => try Context(ptr, writer),
                .pointer => try writer.print("{" ++ Context ++ "}", .{ ptr }),
                else => try writer.writeAll(ptr),
            }
        }       
    };
}

fn Array_VTable(comptime T: type, comptime Context: anytype) type {
    return struct {
        pub fn element(self: *const anyopaque, index: usize) Ref {
            const ptr: [*]const T = @alignCast(@ptrCast(self));
            return make_ref(@TypeOf(ptr[index]), &ptr[index], Context);
        }
    };
}

fn Optional_VTable(comptime T: type, comptime Context: anytype) type {
    return struct {
        pub fn element(self: *const anyopaque, index: usize) Ref {
            _ = index;
            const ptr: *const ?T = @alignCast(@ptrCast(self));
            if (ptr.*) |*value| {
                return make_ref(@TypeOf(value.*), value, Context);
            } else {
                return .nil;
            }
        }
    };
}

fn Union_VTable(comptime T: type, comptime Context: anytype) type {
    return struct {
        pub fn as_number(self: *const anyopaque) usize {
            _ = self;
            // use .tag.# to get the tag's backing integer
            return 1;
        }

        pub fn field(self: *const anyopaque, name: []const u8) Ref {
            const ptr: *const T = @alignCast(@ptrCast(self));
            const ordinal = @intFromEnum(ptr.*);
            inline for (0.., @typeInfo(T).@"union".fields) |i, f| {
                if (i == ordinal and std.mem.eql(u8, name, f.name)) {
                    return make_ref(f.type, &@field(ptr.*, f.name), Child_Context(Context, f.name));
                }
            }

            inline for (@typeInfo(T).@"union".decls) |d| {
                if (comptime std.mem.startsWith(u8, d.name, "zk_")) {
                    if (std.mem.eql(u8, name, d.name[3..])) {
                        return make_ref(@TypeOf(@field(T, d.name)), &@field(T, d.name), Child_Context(Context, d.name));
                    }
                }
            }

            if (std.mem.eql(u8, name, "tag")) {
                const Tag = std.meta.Tag(T);
                return make_ref(Tag, &@as(Tag, ptr.*), Child_Context(Context, "tag"));
            }

            return .nil;
        }

        pub fn print(self: *const anyopaque, writer: std.io.AnyWriter) anyerror!void {
            const ptr: *const T = @alignCast(@ptrCast(self));
            switch (@typeInfo(@TypeOf(Context))) {
                .@"fn" => {
                    try Context(ptr.*, writer);
                },
                .pointer, .array => {
                    try writer.print("{" ++ Context ++ "}", .{ ptr.* });
                },
                else => {
                    const ordinal = @intFromEnum(ptr.*);
                    inline for (0.., @typeInfo(T).@"union".fields) |i, f| {
                        if (i == ordinal) {
                            const ref = make_ref(f.type, &@field(ptr.*, f.name), Child_Context(Context, f.name));
                            try print_ref(ref, writer, null);
                        }
                    }
                },
            }
        }
    };
}

fn Struct_VTable(comptime T: type, comptime Context: anytype) type {
    return struct {
        pub fn tuple_element(self: *const anyopaque, index: usize) Ref {
            const ptr: *const T = @alignCast(@ptrCast(self));
            inline for (0.., @typeInfo(T).@"struct".fields) |i, f| {
                if (i == index) {
                    if (f.is_comptime) {
                        const val = @field(ptr.*, f.name);
                        return make_ref(f.type, &val, Child_Context(Context, f.name));
                    } else {
                        return make_ref(f.type, &@field(ptr.*, f.name), Child_Context(Context, f.name));
                    }
                }
            }
            unreachable;
        }

        pub fn as_number(self: *const anyopaque) usize {
            _ = self;
            return 1;
        }

        pub fn field(self: *const anyopaque, name: []const u8) Ref {
            const ptr: *const T = @alignCast(@ptrCast(self));
            inline for (@typeInfo(T).@"struct".fields) |f| {
                if (std.mem.eql(u8, name, f.name)) {
                    if (f.is_comptime) {
                        const val = @field(ptr.*, f.name);
                        return make_ref(f.type, &val, Child_Context(Context, f.name));
                    } else {
                        return make_ref(f.type, &@field(ptr.*, f.name), Child_Context(Context, f.name));
                    }
                }
            }
            inline for (@typeInfo(T).@"struct".decls) |d| {
                if (comptime std.mem.startsWith(u8, d.name, "zk_")) {
                    if (std.mem.eql(u8, name, d.name[3..])) {
                        return make_ref(@TypeOf(@field(T, d.name)), &@field(T, d.name), Child_Context(Context, d.name));
                    }
                }
            }
            return .nil;
        }

        pub fn print(self: *const anyopaque, writer: std.io.AnyWriter) anyerror!void {
            const ptr: *const T = @alignCast(@ptrCast(self));
            switch (@typeInfo(@TypeOf(Context))) {
                .@"fn" => try Context(ptr.*, writer),
                .pointer, .array => try writer.print("{" ++ Context ++ "}", .{ ptr.* }),
                else => inline for (@typeInfo(T).@"struct".fields) |f| {
                    if (f.is_comptime) {
                        const val = @field(ptr.*, f.name);
                        const ref = make_ref(f.type, &val, Child_Context(Context, f.name));
                        try print_ref(ref, writer, null);
                    } else {
                        const ref = make_ref(f.type, &@field(ptr.*, f.name), Child_Context(Context, f.name));
                        try print_ref(ref, writer, null);
                    }
                },
            }
        }
    };
}

fn Child_Context(comptime Context: anytype, comptime field: []const u8) Child_Context_Type(Context, field) {
    if (@TypeOf(Context) == type and @typeInfo(Context) == .@"struct" and @hasDecl(Context, field)) {
        return @field(Context, field);
    }
    return struct {};
}
fn Child_Context_Type(comptime Context: anytype, comptime field: []const u8) type {
    if (@TypeOf(Context) == type and @typeInfo(Context) == .@"struct" and @hasDecl(Context, field)) {
        return @TypeOf(@field(Context, field));
    }
    return type;
}

const log = std.log.scoped(.zkittle);

const std = @import("std");
