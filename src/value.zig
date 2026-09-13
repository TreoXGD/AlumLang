const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Aligned = std.array_list.Aligned;

const tok = @import("./token.zig");
const Token = tok.Token;
const OpType = tok.OpType;

const EvalError = @import("./errors.zig").EvalError;

pub const Value = union(enum) {
    int: i32,
    float: f64,
    bool: bool,
    block: []Token,
    array: []Value,

    pub fn isNumber(self: Value) EvalError!Value {
        return switch (self) {
            .int, .float => self,
            else => EvalError.NotANumber,
        };
    }

    pub fn isInteger(self: Value) EvalError!i32 {
        return switch (self) {
            .int => |i| i,
            else => EvalError.NotAnInteger,
        };
    }

    pub fn isFloat(self: Value) EvalError!f64 {
        return switch (self) {
            .float => |f| f,
            else => EvalError.NotAFloat,
        };
    }

    pub fn isBool(self: Value) EvalError!bool {
        return switch (self) {
            .bool => |b| b,
            else => EvalError.NotABoolean,
        };
    }

    pub fn isBlock(self: Value) EvalError![]Token {
        return switch (self) {
            .block => |b| b,
            else => EvalError.NotABlock,
        };
    }

    pub fn format(self: Value, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try switch (self) {
            .int => |i| writer.print("{d}", .{i}),
            .float => |f| if (f == @floor(f)) writer.print("{d:.1}", .{f}) else writer.print("{d}", .{f}),
            .bool => |b| writer.print("{}", .{b}),
            .block => |b| {
                try writer.writeAll("{ ");
                for (b, 0..) |token, i| {
                    if (i > 0) try writer.writeByte(' ');
                    try writer.print("{f}", .{token});
                }
                try writer.writeAll(" }");
            },
            .array => |a| {
                try writer.writeAll("[ ");
                for (a, 0..) |val, i| {
                    if (i > 0) try writer.writeByte(' ');
                    try writer.print("{f}", .{val});
                }
                try writer.writeAll(" ]");
            },
        };
    }
};
