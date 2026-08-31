const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Aligned = std.array_list.Aligned;

const tok = @import("./token.zig");
const Token = tok.Token;
const OpType = tok.OpType;

pub const EvalError = error{
    StackUnderflow,
    DivisionByZero,
    WriteFailed,
    ArithmeticWithNoNumber,
    OverflowOnCommand,
    InvalidFloat,
    UndefinedVariable,
    NotOnNonBoolean,
    UnmatchedRightBrace,
    Quit,
} || Allocator.Error;

pub const Value = union(enum) {
    int: i32,
    float: f64,
    bool: bool,
    block: []Token,

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
        };
    }
};

pub const Stack = Aligned(Value, null);

pub const Interpreter = struct {
    arena: Allocator,
    writer: *std.Io.Writer,
    block_level: u32 = 0,
    block_contents: Aligned(Token, null) = .empty,
    stack: Stack = .empty,
    var_dict: std.array_hash_map.String(Value) = .empty,

    pub fn init(arena: Allocator, writer: *std.Io.Writer) Interpreter {
        return .{
            .arena = arena,
            .writer = writer,
        };
    }

    pub fn eval(self: *Interpreter, token: Token) EvalError!void {
        if (self.block_level != 0) {
            switch (token) {
                .op => |op| {
                    if (op == .left_brace) self.block_level += 1;
                    if (op == .right_brace) self.block_level -= 1;
                },
                else => {},
            }

            if (self.block_level == 0) {
                const block = try self.block_contents.toOwnedSlice(self.arena);
                try self.stack.append(self.arena, .{ .block = block });
            } else {
                try self.block_contents.append(self.arena, token);
            }

            return;
        }

        switch (token) {
            .int => |i| try self.stack.append(self.arena, .{ .int = i }),
            .float => |f| try self.stack.append(self.arena, .{ .float = f }),
            .bool => |b| try self.stack.append(self.arena, .{ .bool = b }),
            .set_var => |ident| {
                const value = try self.popOrError();
                try self.var_dict.put(self.arena, ident, value);
            },
            .get_var => |ident| {
                if (self.var_dict.get(ident)) |value| {
                    try self.stack.append(self.arena, value);
                } else return EvalError.UndefinedVariable;
            },
            .op => |op| {
                switch (op) {
                    // binary operations
                    .plus, .minus, .star, .slash, .percent, .min, .max, .less, .less_equal, .greater, .greater_equal, .equal, .not_equal => {
                        const rhs = try isNumber(try self.popOrError());
                        const lhs = try isNumber(try self.popOrError());

                        const result = try computeBin(op, lhs, rhs);

                        try self.stack.append(self.arena, result);
                    },
                    // binary operations without return
                    .swap => {
                        const rhs = try self.popOrError();
                        const lhs = try self.popOrError();

                        try self.stack.append(self.arena, rhs);
                        try self.stack.append(self.arena, lhs);
                    },
                    .over => {
                        // second from top
                        const second = try self.peekAtOrError(1);
                        try self.stack.append(self.arena, second);
                    },
                    // unary arithmetic operations
                    .neg, .abs => {
                        const num = try isNumber(try self.popOrError());

                        const result = try computeUnary(op, num);

                        try self.stack.append(self.arena, result);
                    },
                    .not => {
                        const val = try self.popOrError();
                        if (val != .bool) return EvalError.NotOnNonBoolean;

                        try self.stack.append(self.arena, .{ .bool = !val.bool });
                    },
                    // unary operations without return
                    .dup => {
                        const num = try self.popOrError();

                        try self.stack.append(self.arena, num);
                        try self.stack.append(self.arena, num);
                    },
                    .left_brace => self.block_level += 1,
                    .right_brace => return EvalError.UnmatchedRightBrace,
                    // tertiary operations
                    .rot => {
                        const top = try self.popOrError();
                        const middle = try self.popOrError();
                        const bottom = try self.popOrError();

                        try self.stack.append(self.arena, middle);
                        try self.stack.append(self.arena, top);
                        try self.stack.append(self.arena, bottom);
                    },
                    // no argument operations
                    .drop => _ = try self.popOrError(),
                    .print => try self.writer.print("> {f}\n", .{try self.popOrError()}),
                    .peek => try self.writer.print("| {f}\n", .{try self.peekAtOrError(0)}),
                    .clear => self.stack.clearRetainingCapacity(),
                    .stack => {
                        if (self.stack.items.len == 0) {
                            try self.writer.writeAll("|\n");
                        } else {
                            var i = self.stack.items.len;
                            while (i > 0) : (i -= 1) try self.writer.print("| {f}\n", .{self.stack.items[i - 1]});
                        }
                    },
                    .vars => {
                        if (self.var_dict.count() == 0) {
                            try self.writer.writeAll("||\n");
                        } else {
                            var iter = self.var_dict.iterator();
                            while (iter.next()) |entry| {
                                try self.writer.print("|| {s} = {f}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
                            }
                        }
                    },
                    .quit => return EvalError.Quit,
                    .help => {
                        const help_commands =
                            \\+ - pops 2, pushes their sum
                            \\- - pops 2, pushes their second-from-top minus top
                            \\* - pops 2, pushes their product
                            \\/ - pops 2, pushes their second-from-top over top and errors if top is 0
                            \\% - pops 2, pushes remainder of second-from-top over top and errors if top is 0
                            \\< - pops 2, pushes boolean showing if second-from-top is less than top
                            \\<= - pops 2, pushes boolean showing if second-from-top is less or equal than top
                            \\> - pops 2, pushes boolean showing if second-from-top is greater than top
                            \\>= - pops 2, pushes boolean showing if second-from-top is greater or equal than top
                            \\== - pops 2, pushes boolean showing if second-from-top is equal than top
                            \\!= - pops 2, pushes boolean showing if second-from-top is not equal than top
                            \\! - pops 1, pushes opposite boolean value
                            \\$(ident) - pops 1, defines a variable with popped value and (ident) name
                            \\@(ident) - pushes value of defined (ident) variable onto the stack
                            \\neg - pops 1, pushes its negations
                            \\abs - pops 1, pushes its absolute value
                            \\min - pops 2, pushes smaller value
                            \\max - pops 2, pushes bigger value
                            \\dup - pushes a copy of the top
                            \\swap - swaps the 2 top values
                            \\drop - pops the top
                            \\over - pushes copy of second-from-top value to top
                            \\rot - moves third-from-top to top
                            \\clear - empties the stack
                            \\print - pops and prints the top
                            \\peek - prints the top without popping
                            \\stack - prints the entire stack top to bottom without popping
                            \\vars - prints the entire list of defined variables
                            \\quit - exit the program
                            \\help - shows this message
                        ;

                        try self.writer.writeAll(help_commands ++ "\n");
                    },
                }
            },
        }
    }

    // checks if the given value is of a numeric type
    fn isNumber(val: Value) EvalError!Value {
        switch (val) {
            .int, .float => return val,
            else => return EvalError.ArithmeticWithNoNumber,
        }
    }

    // checks the types of both lhs and rhs. calls numOp afterwards
    fn computeBin(op: OpType, lhs: Value, rhs: Value) EvalError!Value {
        // comparison operators
        if (isCompOp(op)) {
            if (lhs == .int and rhs == .int) return .{ .bool = numCompOp(i32, op, lhs.int, rhs.int) };

            const lf: f64 = if (lhs == .int) @floatFromInt(lhs.int) else lhs.float;
            const rf: f64 = if (rhs == .int) @floatFromInt(rhs.int) else rhs.float;

            return .{ .bool = numCompOp(f64, op, lf, rf) };
        }

        // arithmetic operators
        if (lhs == .int and rhs == .int) return .{ .int = try numArithOp(i32, op, lhs.int, rhs.int) };

        const lf: f64 = if (lhs == .int) @floatFromInt(lhs.int) else lhs.float;
        const rf: f64 = if (rhs == .int) @floatFromInt(rhs.int) else rhs.float;

        const res = try numArithOp(f64, op, lf, rf);
        if (std.math.isInf(res) or std.math.isNan(res)) return EvalError.InvalidFloat;
        return .{ .float = res };
    }

    fn computeUnary(op: OpType, rhs: Value) EvalError!Value {
        // does not need a separate function because only one argument needs to have type checked
        return blk: switch (op) {
            .neg => if (rhs == .int) {
                const res = @subWithOverflow(0, rhs.int);
                if (res[1] != 0) return EvalError.OverflowOnCommand;
                break :blk .{ .int = res[0] };
            } else .{ .float = -rhs.float },
            .abs => if (rhs == .int) {
                if (rhs.int == std.math.minInt(i32)) return EvalError.OverflowOnCommand;
                break :blk .{ .int = if (rhs.int < 0) -rhs.int else rhs.int };
            } else .{ .float = @abs(rhs.float) },
            else => unreachable,
        };
    }

    // finds the result of 'lhs op rhs' expression and returns it with same type as the arguments
    fn numArithOp(T: type, op: OpType, lhs: T, rhs: T) EvalError!T {
        return blk: switch (op) {
            .plus => if (T == i32) {
                const res = @addWithOverflow(lhs, rhs);
                if (res[1] != 0) return EvalError.OverflowOnCommand;
                break :blk res[0];
            } else lhs + rhs,
            .minus => if (T == i32) {
                const res = @subWithOverflow(lhs, rhs);
                if (res[1] != 0) return EvalError.OverflowOnCommand;
                break :blk res[0];
            } else lhs - rhs,
            .star => if (T == i32) {
                const res = @mulWithOverflow(lhs, rhs);
                if (res[1] != 0) return EvalError.OverflowOnCommand;
                break :blk res[0];
            } else lhs * rhs,
            .slash => {
                if (rhs == 0) return EvalError.DivisionByZero;
                break :blk if (T == i32) @divTrunc(lhs, rhs) else lhs / rhs;
            },
            .percent => {
                if (rhs == 0) return EvalError.DivisionByZero;
                break :blk @rem(lhs, rhs);
            },
            .min => @min(lhs, rhs),
            .max => @max(lhs, rhs),
            else => unreachable,
        };
    }

    fn numCompOp(T: type, op: OpType, lhs: T, rhs: T) bool {
        return switch (op) {
            .less => lhs < rhs,
            .less_equal => lhs <= rhs,
            .greater => lhs > rhs,
            .greater_equal => lhs >= rhs,
            .equal => lhs == rhs,
            .not_equal => lhs != rhs,
            else => unreachable,
        };
    }

    fn isCompOp(op: OpType) bool {
        return switch (op) {
            .less, .less_equal, .greater, .greater_equal, .equal, .not_equal => true,
            else => false,
        };
    }

    fn peekAtOrError(self: *Interpreter, depth: usize) EvalError!Value {
        if (depth >= self.stack.items.len) return EvalError.StackUnderflow;
        return self.stack.items[self.stack.items.len - 1 - depth];
    }

    fn popOrError(self: *Interpreter) EvalError!Value {
        return self.stack.pop() orelse return EvalError.StackUnderflow;
    }
};

test "rot operation" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = Interpreter.init(std.testing.allocator, &w);
    defer interp.stack.deinit(std.testing.allocator);

    try interp.eval(.{ .int = 1 });
    try interp.eval(.{ .int = 2 });
    try interp.eval(.{ .int = 3 });
    try interp.eval(.{ .op = .rot });

    try std.testing.expectEqualSlices(Value, &.{ .{ .int = 2 }, .{ .int = 3 }, .{ .int = 1 } }, interp.stack.items);
}

test "add operation" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = Interpreter.init(std.testing.allocator, &w);
    defer interp.stack.deinit(std.testing.allocator);

    try interp.eval(.{ .int = 2 });
    try interp.eval(.{ .int = 3 });
    try interp.eval(.{ .op = .plus });

    try std.testing.expectEqualSlices(Value, &.{.{ .int = 5 }}, interp.stack.items);
}

test "sub operation" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = Interpreter.init(std.testing.allocator, &w);
    defer interp.stack.deinit(std.testing.allocator);

    try interp.eval(.{ .int = 10 });
    try interp.eval(.{ .int = 3 });
    try interp.eval(.{ .op = .minus });

    try std.testing.expectEqualSlices(Value, &.{.{ .int = 7 }}, interp.stack.items);
}

test "mul operation" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = Interpreter.init(std.testing.allocator, &w);
    defer interp.stack.deinit(std.testing.allocator);

    try interp.eval(.{ .int = 4 });
    try interp.eval(.{ .int = 5 });
    try interp.eval(.{ .op = .star });

    try std.testing.expectEqualSlices(Value, &.{.{ .int = 20 }}, interp.stack.items);
}

test "div operation" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = Interpreter.init(std.testing.allocator, &w);
    defer interp.stack.deinit(std.testing.allocator);

    try interp.eval(.{ .int = 20 });
    try interp.eval(.{ .int = 4 });
    try interp.eval(.{ .op = .slash });

    try std.testing.expectEqualSlices(Value, &.{.{ .int = 5 }}, interp.stack.items);
}

test "div operation with division by zero" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = Interpreter.init(std.testing.allocator, &w);
    defer interp.stack.deinit(std.testing.allocator);

    try interp.eval(.{ .int = 5 });
    try interp.eval(.{ .int = 0 });

    try std.testing.expectError(EvalError.DivisionByZero, interp.eval(.{ .op = .slash }));
}

test "mod operation" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = Interpreter.init(std.testing.allocator, &w);
    defer interp.stack.deinit(std.testing.allocator);

    try interp.eval(.{ .int = -7 });
    try interp.eval(.{ .int = 3 });
    try interp.eval(.{ .op = .percent });

    try std.testing.expectEqualSlices(Value, &.{.{ .int = -1 }}, interp.stack.items);
}

test "mod operation with division by zero" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = Interpreter.init(std.testing.allocator, &w);
    defer interp.stack.deinit(std.testing.allocator);

    try interp.eval(.{ .int = 5 });
    try interp.eval(.{ .int = 0 });

    try std.testing.expectError(EvalError.DivisionByZero, interp.eval(.{ .op = .percent }));
}

test "neg operation" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = Interpreter.init(std.testing.allocator, &w);
    defer interp.stack.deinit(std.testing.allocator);

    try interp.eval(.{ .int = 5 });
    try interp.eval(.{ .op = .neg });

    try std.testing.expectEqualSlices(Value, &.{.{ .int = -5 }}, interp.stack.items);
}

test "abs operation on negative" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = Interpreter.init(std.testing.allocator, &w);
    defer interp.stack.deinit(std.testing.allocator);

    try interp.eval(.{ .int = -5 });
    try interp.eval(.{ .op = .abs });

    try std.testing.expectEqualSlices(Value, &.{.{ .int = 5 }}, interp.stack.items);
}

test "abs operation on positive" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = Interpreter.init(std.testing.allocator, &w);
    defer interp.stack.deinit(std.testing.allocator);

    try interp.eval(.{ .int = 7 });
    try interp.eval(.{ .op = .abs });

    try std.testing.expectEqualSlices(Value, &.{.{ .int = 7 }}, interp.stack.items);
}

test "min operation" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = Interpreter.init(std.testing.allocator, &w);
    defer interp.stack.deinit(std.testing.allocator);

    try interp.eval(.{ .int = 5 });
    try interp.eval(.{ .int = 2 });
    try interp.eval(.{ .op = .min });

    try std.testing.expectEqualSlices(Value, &.{.{ .int = 2 }}, interp.stack.items);
}

test "max operation" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = Interpreter.init(std.testing.allocator, &w);
    defer interp.stack.deinit(std.testing.allocator);

    try interp.eval(.{ .int = 3 });
    try interp.eval(.{ .int = 9 });
    try interp.eval(.{ .op = .max });

    try std.testing.expectEqualSlices(Value, &.{.{ .int = 9 }}, interp.stack.items);
}

test "dup operation" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = Interpreter.init(std.testing.allocator, &w);
    defer interp.stack.deinit(std.testing.allocator);

    try interp.eval(.{ .int = 7 });
    try interp.eval(.{ .op = .dup });

    try std.testing.expectEqualSlices(Value, &.{ .{ .int = 7 }, .{ .int = 7 } }, interp.stack.items);
}

test "swap operation" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = Interpreter.init(std.testing.allocator, &w);
    defer interp.stack.deinit(std.testing.allocator);

    try interp.eval(.{ .int = 1 });
    try interp.eval(.{ .int = 2 });
    try interp.eval(.{ .op = .swap });

    try std.testing.expectEqualSlices(Value, &.{ .{ .int = 2 }, .{ .int = 1 } }, interp.stack.items);
}

test "over operation" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = Interpreter.init(std.testing.allocator, &w);
    defer interp.stack.deinit(std.testing.allocator);

    try interp.eval(.{ .int = 1 });
    try interp.eval(.{ .int = 2 });
    try interp.eval(.{ .op = .over });

    try std.testing.expectEqualSlices(Value, &.{ .{ .int = 1 }, .{ .int = 2 }, .{ .int = 1 } }, interp.stack.items);
}

test "drop operation" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = Interpreter.init(std.testing.allocator, &w);
    defer interp.stack.deinit(std.testing.allocator);

    try interp.eval(.{ .int = 1 });
    try interp.eval(.{ .int = 2 });
    try interp.eval(.{ .op = .drop });

    try std.testing.expectEqualSlices(Value, &.{.{ .int = 1 }}, interp.stack.items);
}

test "clear operation" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = Interpreter.init(std.testing.allocator, &w);
    defer interp.stack.deinit(std.testing.allocator);

    try interp.eval(.{ .int = 1 });
    try interp.eval(.{ .int = 2 });
    try interp.eval(.{ .int = 3 });
    try interp.eval(.{ .op = .clear });

    try std.testing.expectEqual(0, interp.stack.items.len);
}

test "print operation" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = Interpreter.init(std.testing.allocator, &w);
    defer interp.stack.deinit(std.testing.allocator);

    try interp.eval(.{ .int = 5 });
    try interp.eval(.{ .op = .print });

    try std.testing.expectEqualStrings("> 5\n", w.buffer[0..w.end]);
    try std.testing.expectEqual(0, interp.stack.items.len);
}

test "peek operation" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = Interpreter.init(std.testing.allocator, &w);
    defer interp.stack.deinit(std.testing.allocator);

    try interp.eval(.{ .int = 5 });
    try interp.eval(.{ .op = .peek });

    try std.testing.expectEqualStrings("| 5\n", w.buffer[0..w.end]);
    try std.testing.expectEqualSlices(Value, &.{.{ .int = 5 }}, interp.stack.items);
}

test "stack operation" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = Interpreter.init(std.testing.allocator, &w);
    defer interp.stack.deinit(std.testing.allocator);

    try interp.eval(.{ .int = 1 });
    try interp.eval(.{ .int = 2 });
    try interp.eval(.{ .op = .stack });

    try std.testing.expectEqualStrings("| 2\n| 1\n", w.buffer[0..w.end]);
    try std.testing.expectEqualSlices(Value, &.{ .{ .int = 1 }, .{ .int = 2 } }, interp.stack.items);
}

test "quit operation" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = Interpreter.init(std.testing.allocator, &w);
    defer interp.stack.deinit(std.testing.allocator);

    try std.testing.expectError(EvalError.Quit, interp.eval(.{ .op = .quit }));
}

test "less than operation" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = Interpreter.init(std.testing.allocator, &w);
    defer interp.stack.deinit(std.testing.allocator);

    try interp.eval(.{ .int = 5 });
    try interp.eval(.{ .int = 4 });
    try interp.eval(.{ .op = .less });

    try std.testing.expectEqualSlices(Value, &.{.{ .bool = false }}, interp.stack.items);
}

test "less than or equal operation" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = Interpreter.init(std.testing.allocator, &w);
    defer interp.stack.deinit(std.testing.allocator);

    try interp.eval(.{ .int = 5 });
    try interp.eval(.{ .int = 5 });
    try interp.eval(.{ .op = .less_equal });

    try std.testing.expectEqualSlices(Value, &.{.{ .bool = true }}, interp.stack.items);
}

test "greater than operation" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = Interpreter.init(std.testing.allocator, &w);
    defer interp.stack.deinit(std.testing.allocator);

    try interp.eval(.{ .float = 5.1 });
    try interp.eval(.{ .int = 5 });
    try interp.eval(.{ .op = .greater });

    try std.testing.expectEqualSlices(Value, &.{.{ .bool = true }}, interp.stack.items);
}

test "greater than or equal operation" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = Interpreter.init(std.testing.allocator, &w);
    defer interp.stack.deinit(std.testing.allocator);

    try interp.eval(.{ .int = 5 });
    try interp.eval(.{ .int = 5 });
    try interp.eval(.{ .op = .greater_equal });

    try std.testing.expectEqualSlices(Value, &.{.{ .bool = true }}, interp.stack.items);
}

test "equal operation" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = Interpreter.init(std.testing.allocator, &w);
    defer interp.stack.deinit(std.testing.allocator);

    try interp.eval(.{ .int = 5 });
    try interp.eval(.{ .int = 5 });
    try interp.eval(.{ .op = .equal });

    try std.testing.expectEqualSlices(Value, &.{.{ .bool = true }}, interp.stack.items);
}

test "not equal operation" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = Interpreter.init(std.testing.allocator, &w);
    defer interp.stack.deinit(std.testing.allocator);

    try interp.eval(.{ .int = 5 });
    try interp.eval(.{ .int = 5 });
    try interp.eval(.{ .op = .not_equal });

    try std.testing.expectEqualSlices(Value, &.{.{ .bool = false }}, interp.stack.items);
}

test "mul operation with float overflow" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = Interpreter.init(std.testing.allocator, &w);
    defer interp.stack.deinit(std.testing.allocator);

    try interp.eval(.{ .float = std.math.floatMax(f64) });
    try interp.eval(.{ .float = 2.0 });

    try std.testing.expectError(EvalError.InvalidFloat, interp.eval(.{ .op = .star }));
}

test "Value.format" {
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);

    try w.print("{f} {f} {f}", .{ Value{ .int = 5 }, Value{ .float = 2.5 }, Value{ .float = 5.0 } });

    try std.testing.expectEqualStrings("5 2.5 5.0", w.buffer[0..w.end]);
}

test "arithmetic errors on non-numeric value" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = Interpreter.init(std.testing.allocator, &w);
    defer interp.stack.deinit(std.testing.allocator);

    try interp.stack.append(interp.arena, .{ .bool = true });
    try interp.stack.append(interp.arena, .{ .int = 1 });

    try std.testing.expectError(EvalError.ArithmeticWithNoNumber, interp.eval(.{ .op = .plus }));
}

test "set var and get var operations" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = Interpreter.init(std.testing.allocator, &w);
    defer interp.stack.deinit(std.testing.allocator);
    defer interp.var_dict.deinit(std.testing.allocator);

    try interp.eval(.{ .int = 5 });
    try interp.eval(.{ .set_var = "x" });
    try interp.eval(.{ .get_var = "x" });

    try std.testing.expectEqualSlices(Value, &.{.{ .int = 5 }}, interp.stack.items);
}

test "get var errors on undefined variable" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = Interpreter.init(std.testing.allocator, &w);
    defer interp.stack.deinit(std.testing.allocator);
    defer interp.var_dict.deinit(std.testing.allocator);

    try std.testing.expectError(EvalError.UndefinedVariable, interp.eval(.{ .get_var = "x" }));
}

test "set var overwrites an existing variable" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = Interpreter.init(std.testing.allocator, &w);
    defer interp.stack.deinit(std.testing.allocator);
    defer interp.var_dict.deinit(std.testing.allocator);

    try interp.eval(.{ .int = 1 });
    try interp.eval(.{ .set_var = "x" });
    try interp.eval(.{ .int = 2 });
    try interp.eval(.{ .set_var = "x" });
    try interp.eval(.{ .get_var = "x" });

    try std.testing.expectEqualSlices(Value, &.{.{ .int = 2 }}, interp.stack.items);
}

test "variable name matching a keyword doesn't collide with it" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = Interpreter.init(std.testing.allocator, &w);
    defer interp.stack.deinit(std.testing.allocator);
    defer interp.var_dict.deinit(std.testing.allocator);

    try interp.eval(.{ .int = 99 });
    try interp.eval(.{ .set_var = "dup" });
    try interp.eval(.{ .int = 7 });
    try interp.eval(.{ .op = .dup });
    try interp.eval(.{ .get_var = "dup" });

    try std.testing.expectEqualSlices(Value, &.{ .{ .int = 7 }, .{ .int = 7 }, .{ .int = 99 } }, interp.stack.items);
}

test "not operator errors on non-boolean" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = Interpreter.init(std.testing.allocator, &w);
    defer interp.stack.deinit(std.testing.allocator);

    try interp.eval(.{ .int = 5 });

    try std.testing.expectError(EvalError.NotOnNonBoolean, interp.eval(.{ .op = .not }));
}

test "comparison errors on a boolean operand" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = Interpreter.init(std.testing.allocator, &w);
    defer interp.stack.deinit(std.testing.allocator);

    try interp.eval(.{ .int = 1 });
    try interp.eval(.{ .int = 2 });
    try interp.eval(.{ .op = .less });
    try interp.eval(.{ .int = 1 });
    try interp.eval(.{ .int = 2 });
    try interp.eval(.{ .op = .less });

    try std.testing.expectError(EvalError.ArithmeticWithNoNumber, interp.eval(.{ .op = .equal }));
}
