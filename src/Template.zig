pub const Parser = @import("Parser.zig");
pub const Source = @import("Source.zig");
pub const Token = @import("Token.zig");

const Template = @This();

pub const Render_Options = struct {
    Context: type = struct {},
    escape_fn: *const Escape_Fn = escape_html,
};
pub const Escape_Fn = fn(str: []const u8, writer: std.io.AnyWriter) anyerror!void;

pub fn render(self: Template, writer: std.io.AnyWriter, obj: anytype, comptime options: Render_Options) anyerror!void {
    try self.execute(writer, make_ref(@TypeOf(obj), &obj, options.escape_fn, options.Context));
}

pub const max_stack_size = 31;

pub const Instruction = struct {
    op: Opcode,
    data: Operands,
};

pub const Opcode = enum (u8) {
    print_literal, // literal_ref
    print_ref_raw,
    print_ref_escaped,
    print_loop_index,
    field, // literal_ref
    index, // offset
    as_number,
    number_to_ref,
    dupe_ref, // offset
    dupe_ref_0,
    pop_and_skip_if_zero, // offset
    skip, // offset
    begin_loop,
    end_loop,
    skip_if_equal, // offset
    dupe_ref_0_indexed,
    pop_ref,
    increment_and_retry_if_less, // offset
};

pub const Operands = union {
    none: void,
    offset: usize,
    literal_string: Literal_Ref,
};

pub const Literal_Ref = struct {
    offset: u32,
    length: u32,
};

pub const Ref = union (enum) {
    nil,
    collection: Collection,
    structure: Structure,
    value: Value,
};

pub const Collection = struct {
    data: *const anyopaque,
    size: usize,
    element: *const fn(self: *const anyopaque, index: usize) Ref,
};

pub const Structure = struct {
    data: *const anyopaque,
    field: *const fn(self: *const anyopaque, name: []const u8) ?Ref,
    print: *const fn(self: *const anyopaque, writer: std.io.AnyWriter, escape: bool) anyerror!void
};

pub const Value = struct {
    data: *const anyopaque,
    as_number: *const fn (self: *const anyopaque) usize,
    print: *const fn(self: *const anyopaque, writer: std.io.AnyWriter, escape: bool) anyerror!void
};

opcodes: []const Opcode,
operands: [*]const Operands,
literal_data: []const u8,

pub fn init_static(comptime instruction_count: usize, comptime data: []const u8) Template {
    const end_of_operands = instruction_count * @sizeOf(Operands);
    const start_of_opcodes = comptime std.mem.alignForward(comptime_int, end_of_operands, @alignOf(Opcode));
    const end_of_opcodes = start_of_opcodes + instruction_count * @sizeOf(Opcode);
    return comptime .{
        .opcodes = @ptrCast(data[start_of_opcodes..end_of_opcodes]),
        .operands = @ptrCast(data),
        .literal_data = data[end_of_opcodes..],
    };
}

pub fn init(allocator: std.mem.Allocator, instructions: std.MultiArrayList(Instruction), literal_data: []const u8) !Template {
    const opcodes = try allocator.dupe(Opcode, instructions.items(.op));
    errdefer allocator.free(opcodes);

    const operands = try allocator.dupe(Operands, instructions.items(.data));
    errdefer allocator.free(operands);

    const literal_data_copy = try allocator.dupe(u8, literal_data);
    errdefer allocator.free(literal_data_copy);

    return .{
        .opcodes = opcodes,
        .operands = operands.ptr,
        .literal_data = literal_data_copy,
    };
}

pub fn deinit(self: *Template, allocator: std.mem.Allocator) void {
    allocator.free(self.literal_data);
    allocator.free(self.operands[0..self.opcodes.len]);
    allocator.free(self.opcodes);
}

fn literal(self: Template, pc: usize) []const u8 {
    const ref = self.operands[pc].literal_string;
    return self.literal_data[ref.offset..][0..ref.length];
}

fn print_ref(ref: Ref, writer: std.io.AnyWriter, escape: bool) anyerror!void {
    switch (ref) {
        .nil => {},
        .collection => |c| {
            for (0..c.size) |i| {
                try print_ref(c.element(c.data, i), writer, escape);
            }
        },
        .structure => |s| {
            try s.print(s.data, writer, escape);
        },
        .value => |v| {
            try v.print(v.data, writer, escape);
        },
    }
}

fn ref_to_number(ref: Ref) usize {
    return switch (ref) {
        .nil => 0,
        .collection => |c| c.size,
        .structure => 1,
        .value => |v| v.as_number(v.data),
    };
}

fn number_ref(n: usize) Ref {
    const vtable = struct {
        pub fn as_number(self: *const anyopaque) usize {
            return @intFromPtr(self);
        }
        pub fn print(self: *const anyopaque, writer: std.io.AnyWriter, escape: bool) anyerror!void {
            _ = escape;
            try writer.print("{d}", .{ as_number(self) });
        }
    };

    return .{ .value = .{
        .data = @ptrFromInt(n),
        .as_number = vtable.as_number,
        .print = vtable.print,
    }};
}

fn lookup_field(self: Template, ref: Ref, pc: usize) !Ref {
    switch (ref) {
        .nil => return .nil,
        .structure => |s| {
            if (s.field(s.data, self.literal(pc))) |r| {
                return r;
            } else {
                log.debug("No field named {s} (pc={d})", .{ self.literal(pc), pc });
                return .nil;
            }
        },
        .collection => {
            log.debug("Expected struct with field named {s}; found collection (pc={d})", .{ self.literal(pc), pc });
            return .nil;
        },
        .value => {
            log.debug("Expected struct with field named {s}; found value (pc={d})", .{ self.literal(pc), pc });
            return .nil;
        },
    }
}

fn lookup_index(ref: Ref, index: usize, pc: usize) !Ref {
    switch (ref) {
        .nil => return .nil,
        .collection => |c| {
            if (index < c.size) {
                return c.element(c.data, index);
            } else {
                log.debug("Expected collection of size > {d}; found size {d} (pc={d})", .{ index, c.size, pc });
                return .nil;
            }
        },
        .structure => {
            if (index == 0) {
                // This is needed for the "within" syntax
                return ref;
            }
            log.debug("Expected collection of size > {d}; found structure (pc={d})", .{ index, pc });
            return .nil;
        },
        .value => return ref, // this is needed in order for optionals to work with the "within" syntax
    }
}

pub fn execute(self: Template, writer: std.io.AnyWriter, root_ref: Ref) anyerror!void {
    const opcodes = self.opcodes;

    var variables: [max_stack_size]usize = .{ 0 } ** max_stack_size;
    var refs: [max_stack_size + 1]Ref = undefined;
    refs[0] = root_ref;

    var variable_sp: usize = 0;
    var ref_sp: usize = 1;

    var pc: usize = 0;
    while (pc < opcodes.len) {
        switch (opcodes[pc]) {
            .print_literal => {
                const lit = self.literal(pc);
                log.debug("{}: print_literal: {}", .{ pc, std.zig.fmtEscapes(lit) });
                try writer.writeAll(lit);
                pc += 1;
            },
            .print_ref_raw => {
                if (ref_sp == 0) return error.InvalidTemplate;
                ref_sp -= 1;
                log.debug("{}: print_ref_raw: ref={}", .{ pc, ref_sp });
                try print_ref(refs[ref_sp], writer, false);
                pc += 1;
            },
            .print_ref_escaped => {
                if (ref_sp == 0) return error.InvalidTemplate;
                ref_sp -= 1;
                log.debug("{}: print_ref_escaped: ref={}", .{ pc, ref_sp });
                try print_ref(refs[ref_sp], writer, true);
                pc += 1;
            },
            .print_loop_index => {
                if (variable_sp == 0) return error.InvalidTemplate;
                log.debug("{}: print_loop_index: var={}", .{ pc, variable_sp - 1 });
                try writer.print("{d}", .{ variables[variable_sp - 1] });
                pc += 1;
            },
            .field => {
                if (ref_sp == 0) return error.InvalidTemplate;
                log.debug("{}: field: ref={}", .{ pc, ref_sp - 1 });
                refs[ref_sp - 1] = try self.lookup_field(refs[ref_sp - 1], pc);
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
                log.debug("{}: as_number: ref={} var={}", .{ pc, ref_sp, variable_sp });
                variables[variable_sp] = ref_to_number(refs[ref_sp]);
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
                log.debug("{}: increment_and_retry_if_less: inc_var={} [{}] compare_var={} [{}], addr={}", .{ pc, variable_sp - 1, new, variable_sp - 2, compare, offset });
                variables[variable_sp - 1] = new;
                if (new < compare) {
                    pc = offset;
                } else {
                    pc += 1;
                }
            },
        }
    }
}

pub fn make_ref(comptime T: type, ptr: *const T, comptime escape_fn: *const Escape_Fn, comptime Context: anytype) Ref {
    return switch (@typeInfo(T)) {
        .Void, .Null, .Undefined => .nil,
        .Bool => .{ .value = .{
            .data = ptr,
            .as_number = Bool_VTable(Context).as_number,
            .print = Bool_VTable(Context).print,
        }},
        .Int => .{ .value = .{
            .data = ptr,
            .as_number = Int_VTable(T, Context).as_number,
            .print = Int_VTable(T, Context).print,
        }},
        .Float => .{ .value = .{
            .data = ptr,
            .as_number = Float_VTable(T, Context).as_number,
            .print = Float_VTable(T, Context).print,
        }},
        .Enum => .{ .value = .{
            .data = ptr,
            .as_number = Enum_VTable(T, escape_fn, Context).as_number,
            .print = Enum_VTable(T, escape_fn, Context).print,
        }},
        .Pointer => |info| {
            if (info.size == .Slice) {
                if (info.child == u8) {
                    return .{ .value = .{
                        .data = @ptrCast(ptr),
                        .as_number = String_VTable(escape_fn, Context).as_number,
                        .print = String_VTable(escape_fn, Context).print,
                    }};
                } else {
                    return .{ .collection = .{
                        .data = ptr.ptr,
                        .size = ptr.len,
                        .element = Array_VTable(info.child, escape_fn, Context).element,
                    }};
                }
            } else {
                return make_ref(@TypeOf(ptr.*.*), ptr.*, escape_fn, Context);
            }
        },
        .Array => |info| {
            if (info.child == u8) {
                return .{ .value = .{
                    .data = ptr,
                    .as_number = Array_String_VTable(info.len, escape_fn, Context).as_number,
                    .print = Array_String_VTable(info.len, escape_fn, Context).print,
                }};
            } else {
                return .{ .collection = .{
                    .data = ptr,
                    .size = info.len,
                    .element = Array_VTable(info.child, escape_fn, Context).element,
                }};
            }
        },
        .Optional => |info| .{ .collection = .{
            .data = ptr,
            .size = if (ptr.* == null) 0 else 1,
            .element = Optional_VTable(info.child, escape_fn, Context).element,
        }},
        .Union => |info| {
            if (info.tag_type == null) @compileError("Unions must be tagged");
            return .{ .structure = .{
                .data = ptr,
                .field = Union_VTable(T, escape_fn, Context).field,
                .print = Union_VTable(T, escape_fn, Context).print,
            }};
        },
        .Struct => |info| {
            if (info.is_tuple) {
                return .{ .collection = .{
                    .data = ptr,
                    .size = info.fields.len,
                    .element = Struct_VTable(T, escape_fn, Context).tuple_element,
                }};
            } else {
                return .{ .structure = .{
                    .data = ptr,
                    .field = Struct_VTable(T, escape_fn, Context).field,
                    .print = Struct_VTable(T, escape_fn, Context).print,
                }};
            }
        },
        .ErrorUnion => @compileError("Can't serialize error set; did you forget a 'try'?"),
        else => @compileError("Unsupported type: " ++ @typeName(T)),
    };
}

fn Bool_VTable(comptime Context: anytype) type {
    return struct {
        pub fn as_number(self: *const anyopaque) usize {
            const ptr: *const bool = @alignCast(@ptrCast(self));
            return @intFromBool(ptr.*);
        }

        pub fn print(self: *const anyopaque, writer: std.io.AnyWriter, escape: bool) anyerror!void {
            const ptr: *const bool = @alignCast(@ptrCast(self));
            switch (@typeInfo(@TypeOf(Context))) {
                .Fn => {
                    try Context(ptr.*, writer, escape);
                },
                .Pointer => {
                    try writer.print("{" ++ Context ++ "}", .{ ptr.* });
                },
                else => {
                    try writer.writeAll(if (ptr.*) "true" else "false");
                },
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

        pub fn print(self: *const anyopaque, writer: std.io.AnyWriter, escape: bool) anyerror!void {
            const ptr: *const T = @alignCast(@ptrCast(self));
            switch (@typeInfo(@TypeOf(Context))) {
                .Fn => {
                    try Context(ptr.*, writer, escape);
                },
                .Pointer => {
                    try writer.print("{" ++ Context ++ "}", .{ ptr.* });
                },
                else => {
                    try writer.print("{d}", .{ ptr.* });
                },
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

        pub fn print(self: *const anyopaque, writer: std.io.AnyWriter, escape: bool) anyerror!void {
            const ptr: *const T = @alignCast(@ptrCast(self));
            switch (@typeInfo(@TypeOf(Context))) {
                .Fn => {
                    try Context(ptr.*, writer, escape);
                },
                .Pointer => {
                    try writer.print("{" ++ Context ++ "}", .{ ptr.* });
                },
                else => {
                    try writer.print("{d}", .{ ptr.* });
                },
            }
        }
    };
}

fn Enum_VTable(comptime T: type, comptime escape_fn: *const Escape_Fn, comptime Context: anytype) type {
    return struct {
        pub fn as_number(self: *const anyopaque) usize {
            const ptr: *const T = @alignCast(@ptrCast(self));
            return @intFromEnum(ptr.*);
        }

        pub fn print(self: *const anyopaque, writer: std.io.AnyWriter, escape: bool) anyerror!void {
            const ptr: *const T = @alignCast(@ptrCast(self));
            switch (@typeInfo(@TypeOf(Context))) {
                .Fn => {
                    try Context(ptr.*, writer, escape);
                },
                .Pointer => {
                    try writer.print("{" ++ Context ++ "}", .{ ptr.* });
                },
                else => {
                    if (std.enums.tagName(T, ptr.*)) |name| {
                        if (escape) {
                            try escape_fn(name, writer);
                        } else {
                            try writer.writeAll(name);
                        }
                    } else {
                        try writer.print("({d})", .{ @intFromEnum(ptr.*) });
                    }
                },
            }
        }
    };
}

fn String_VTable(comptime escape_fn: *const Escape_Fn, comptime Context: anytype) type {
    return struct {
        pub fn as_number(self: *const anyopaque) usize {
            const ptr: *const []const u8 = @alignCast(@ptrCast(self));
            return @intFromBool(ptr.*.len > 0);
        }

        pub fn print(self: *const anyopaque, writer: std.io.AnyWriter, escape: bool) anyerror!void {
            const ptr: *const []const u8 = @alignCast(@ptrCast(self));
            switch (@typeInfo(@TypeOf(Context))) {
                .Fn => {
                    try Context(ptr.*, writer, escape);
                },
                .Pointer => {
                    try writer.print("{" ++ Context ++ "}", .{ ptr.* });
                },
                else => {
                    if (escape) {
                        try escape_fn(ptr.*, writer);
                    } else {
                        try writer.writeAll(ptr.*);
                    }
                },
            }
        }
    };
}

fn Array_String_VTable(comptime length: usize, comptime escape_fn: *const Escape_Fn, comptime Context: anytype) type {
    return struct {
        pub fn as_number(self: *const anyopaque) usize {
            _ = self;
            return @intFromBool(length > 0);
        }

        pub fn print(self: *const anyopaque, writer: std.io.AnyWriter, escape: bool) anyerror!void {
            const ptr: *const [length]u8 = @alignCast(@ptrCast(self));
            switch (@typeInfo(@TypeOf(Context))) {
                .Fn => {
                    try Context(ptr, writer, escape);
                },
                .Pointer => {
                    try writer.print("{" ++ Context ++ "}", .{ ptr });
                },
                else => {
                    if (escape) {
                        try escape_fn(ptr, writer);
                    } else {
                        try writer.writeAll(ptr);
                    }
                },
            }
        }       
    };
}

fn Array_VTable(comptime T: type, comptime escape_fn: *const Escape_Fn, comptime Context: anytype) type {
    return struct {
        pub fn element(self: *const anyopaque, index: usize) Ref {
            const ptr: [*]const T = @alignCast(@ptrCast(self));
            return make_ref(@TypeOf(ptr[index]), &ptr[index], escape_fn, Context);
        }
    };
}

fn Optional_VTable(comptime T: type, comptime escape_fn: *const Escape_Fn, comptime Context: anytype) type {
    return struct {
        pub fn element(self: *const anyopaque, index: usize) Ref {
            _ = index;
            const ptr: *const ?T = @alignCast(@ptrCast(self));
            if (ptr.*) |*value| {
                return make_ref(@TypeOf(value.*), value, escape_fn, Context);
            } else {
                return make_ref(void, undefined, escape_fn, Context);
            }
        }
    };
}

fn Union_VTable(comptime T: type, comptime escape_fn: *const Escape_Fn, comptime Context: anytype) type {
    return struct {
        pub fn field(self: *const anyopaque, name: []const u8) ?Ref {
            const ptr: *const T = @alignCast(@ptrCast(self));
            const ordinal = @intFromEnum(ptr.*);
            inline for (0.., @typeInfo(T).Union.fields) |i, f| {
                if (std.mem.eql(u8, name, f.name)) {
                    if (i == ordinal) {
                        return make_ref(f.type, &@field(ptr.*, f.name), escape_fn, Child_Context(Context, f.name));
                    } else {
                        return make_ref(void, undefined, escape_fn, struct {});
                    }
                }
            }
            return null;
        }

        pub fn print(self: *const anyopaque, writer: std.io.AnyWriter, escape: bool) anyerror!void {
            const ptr: *const T = @alignCast(@ptrCast(self));
            switch (@typeInfo(@TypeOf(Context))) {
                .Fn => {
                    try Context(ptr.*, writer, escape);
                },
                .Pointer => {
                    try writer.print("{" ++ Context ++ "}", .{ ptr.* });
                },
                else => {
                    const ordinal = @intFromEnum(ptr.*);
                    inline for (0.., @typeInfo(T).Union.fields) |i, f| {
                        if (i == ordinal) {
                            const ref = make_ref(f.type, &@field(ptr.*, f.name), escape_fn, Child_Context(Context, f.name));
                            try print_ref(ref, writer, escape);
                        }
                    }
                    unreachable;
                },
            }
        }
    };
}

fn Struct_VTable(comptime T: type, comptime escape_fn: *const Escape_Fn, comptime Context: anytype) type {
    return struct {
        pub fn tuple_element(self: *const anyopaque, index: usize) Ref {
            const ptr: *const T = @alignCast(@ptrCast(self));
            inline for (0.., @typeInfo(T).Struct.fields) |i, f| {
                if (i == index) {
                    if (f.is_comptime) {
                        const val = @field(ptr.*, f.name);
                        return make_ref(f.type, &val, escape_fn, Child_Context(Context, f.name));
                    } else {
                        return make_ref(f.type, &@field(ptr.*, f.name), escape_fn, Child_Context(Context, f.name));
                    }
                }
            }
            unreachable;
        }

        pub fn field(self: *const anyopaque, name: []const u8) ?Ref {
            const ptr: *const T = @alignCast(@ptrCast(self));
            inline for (@typeInfo(T).Struct.fields) |f| {
                if (std.mem.eql(u8, name, f.name)) {
                    if (f.is_comptime) {
                        const val = @field(ptr.*, f.name);
                        return make_ref(f.type, &val, escape_fn, Child_Context(Context, f.name));
                    } else {
                        return make_ref(f.type, &@field(ptr.*, f.name), escape_fn, Child_Context(Context, f.name));
                    }
                }
            }
            return null;
        }

        pub fn print(self: *const anyopaque, writer: std.io.AnyWriter, escape: bool) anyerror!void {
            const ptr: *const T = @alignCast(@ptrCast(self));
            switch (@typeInfo(@TypeOf(Context))) {
                .Fn => {
                    try Context(ptr.*, writer, escape);
                },
                .Pointer => {
                    try writer.print("{" ++ Context ++ "}", .{ ptr.* });
                },
                else => {
                    inline for (@typeInfo(T).Struct.fields) |f| {
                        if (f.is_comptime) {
                            const val = @field(ptr.*, f.name);
                            const ref = make_ref(f.type, &val, escape_fn, Child_Context(Context, f.name));
                            try print_ref(ref, writer, escape);
                        } else {
                            const ref = make_ref(f.type, &@field(ptr.*, f.name), escape_fn, Child_Context(Context, f.name));
                            try print_ref(ref, writer, escape);
                        }
                    }
                },
            }
        }
    };
}

fn Child_Context(comptime Context: anytype, comptime field: []const u8) Child_Context_Type(Context, field) {
    if (@typeInfo(@TypeOf(Context)) == .Struct and @hasDecl(Context, field)) {
        return @field(Context, field);
    }
    return struct {};
}
fn Child_Context_Type(comptime Context: anytype, comptime field: []const u8) type {
    if (@typeInfo(@TypeOf(Context)) == .Struct and @hasDecl(Context, field)) {
        return @TypeOf(@field(Context, field));
    }
    return type;
}

fn escape_none(str: []const u8, writer: std.io.AnyWriter) anyerror!void {
    try writer.writeAll(str);
}

fn escape_html(str: []const u8, writer: std.io.AnyWriter) anyerror!void {
    var iter = std.mem.splitAny(u8, str, "&<>\"'");
    while (iter.next()) |chunk| {
        try writer.writeAll(chunk);
        if (iter.index) |i| {
            try writer.writeAll(switch (iter.buffer[i-1]) {
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

const log = std.log.scoped(.zkittle);

const std = @import("std");

