test {
    const hmm = .{
        .fishy = @as([]const u8, "mcfisherson"),
    };

    funnyBusiness(@as(NotFunnyBusiness, hmm));

    funnyBusiness(hmm);
}

const NotFunnyBusiness = struct {
    fishy: []const u8,
};

fn funnyBusiness(what: anytype) void {
    typedFunnyBusiness(fixType(@TypeOf(what)), &what);
}

fn fixType(comptime T: type) type {
    if (std.mem.startsWith(u8, @typeName(T), "struct{")) {
        var info = @typeInfo(T).Struct;
        var new_fields: [info.fields.len]std.builtin.Type.StructField = undefined;
        for (info.fields, &new_fields) |f, *nf| {
            if (!f.is_comptime) return T;
            nf.* = f;
            nf.is_comptime = false;
        }
        info.fields = &new_fields;
        return @Type(.{ .Struct = info });
    }
    return T;
}

fn typedFunnyBusiness(comptime T: type, ptr: *const T) void {
    inline for (@typeInfo(T).Struct.fields) |f| {
        std.debug.print("{*}", .{ &@field(ptr.*, f.name) });
    }
}

const std = @import("std");
