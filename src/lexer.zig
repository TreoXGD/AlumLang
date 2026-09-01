const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Aligned = std.array_list.Aligned;

const tok = @import("./token.zig");
const Token = tok.Token;
const OpType = tok.OpType;

pub const LexError = error{
    NotKeyword,
    UnsupportedCharacter,
    Overflow,
    DecimalPointWithoutNumber,
    GetVarWithoutValidVar,
    SetVarWithoutValidVar,
    CallVarWithoutValidVar,
    EqualWithoutSecondEqual,
} || Allocator.Error;

pub const TokenList = Aligned(Token, null);

pub const Lexer = struct {
    arena: Allocator,
    index: usize = 0,
    text: []const u8 = "",

    const LexState = enum {
        start,
        num,
        ident_op,
        get_or_set_var,
        op,
        end,
    };

    pub fn lex(self: *Lexer, text: []const u8) LexError!TokenList {
        var token_list: TokenList = .empty;
        self.index = 0;
        self.text = text;

        state: switch (LexState.start) {
            .start => {
                if (self.isAtEnd()) continue :state .end;
                switch (self.advance()) {
                    '0'...'9' => {
                        continue :state .num;
                    },
                    '+', '*', '/', '%', '<', '>', '=', '!', '&', '|', '{', '}' => continue :state .op,
                    '-' => {
                        if (!self.isAtEnd() and std.ascii.isDigit(self.peekAt(0))) continue :state .num;

                        continue :state .op;
                    },
                    ';' => {
                        while (!self.isAtEnd() and self.peekAt(0) != '\n') self.index += 1;
                        continue :state .start;
                    },
                    ':' => {
                        if (self.isAtEnd() or !std.ascii.isAlphabetic(self.text[self.index])) return LexError.CallVarWithoutValidVar;
                        const start_index = self.index;
                        while (!self.isAtEnd() and std.ascii.isAlphanumeric(self.text[self.index])) self.index += 1;

                        const ident = try self.arena.dupe(u8, self.text[start_index..self.index]);

                        // syntactic sugar: :(ident) => @(ident) call
                        try token_list.append(self.arena, .{ .get_var = ident });
                        try token_list.append(self.arena, .{ .op = .call });
                        continue :state .start;
                    },
                    '@' => {
                        if (self.isAtEnd() or !std.ascii.isAlphabetic(self.text[self.index])) return LexError.GetVarWithoutValidVar;
                        continue :state .get_or_set_var;
                    },
                    '$' => {
                        if (self.isAtEnd() or !std.ascii.isAlphabetic(self.text[self.index])) return LexError.SetVarWithoutValidVar;
                        continue :state .get_or_set_var;
                    },
                    ' ', '\t', '\r', '\n' => continue :state .start,
                    'a'...'z' => continue :state .ident_op,
                    else => return LexError.UnsupportedCharacter,
                }
            },
            .op => {
                const op: OpType = switch (self.text[self.index - 1]) {
                    '+' => .plus,
                    '-' => .minus,
                    '*' => .star,
                    '/' => .slash,
                    '%' => .percent,
                    '{' => .left_brace,
                    '}' => .right_brace,
                    '<' => if (!self.isAtEnd() and self.matchAdvance('=')) .less_equal else .less,
                    '>' => if (!self.isAtEnd() and self.matchAdvance('=')) .greater_equal else .greater,
                    '=' => if (!self.isAtEnd() and self.matchAdvance('=')) .equal else return LexError.EqualWithoutSecondEqual,
                    '!' => if (!self.isAtEnd() and self.matchAdvance('=')) .not_equal else .not,
                    '&' => if (!self.isAtEnd() and self.matchAdvance('&')) .amp_amp else .amp,
                    '|' => if (!self.isAtEnd() and self.matchAdvance('|')) .bar_bar else .bar,
                    else => unreachable,
                };

                try token_list.append(self.arena, .{ .op = op });

                continue :state .start;
            },
            .num => {
                // start_index is index - 1 in order to include the '-' sign for parsing and bound checking
                const start_index = self.index - 1;
                while (!self.isAtEnd() and std.ascii.isDigit(self.peekAt(0))) {
                    self.index += 1;
                }

                // floats
                if (!self.isAtEnd() and self.peekAt(0) == '.') {
                    self.index += 1;
                    if (self.isAtEnd() or !std.ascii.isDigit(self.peekAt(0))) return LexError.DecimalPointWithoutNumber;

                    while (!self.isAtEnd() and std.ascii.isDigit(self.peekAt(0))) {
                        self.index += 1;
                    }
                    const num = std.fmt.parseFloat(f64, text[start_index..self.index]) catch unreachable;

                    try token_list.append(self.arena, .{ .float = num });
                } else {
                    const num = std.fmt.parseInt(i32, text[start_index..self.index], 10) catch |err| switch (err) {
                        error.InvalidCharacter => unreachable,
                        error.Overflow => return LexError.Overflow,
                    };

                    try token_list.append(self.arena, .{ .int = num });
                }

                continue :state .start;
            },
            .ident_op => {
                const start_index = self.index - 1;
                while (!self.isAtEnd() and std.ascii.isAlphabetic(self.peekAt(0))) {
                    self.index += 1;
                }

                // no support for non-keyword identifiers for now
                const keyword = try strToKeyword(text[start_index..self.index]);

                try token_list.append(self.arena, keyword);

                continue :state .start;
            },
            .get_or_set_var => {
                const start_index = self.index;
                while (!self.isAtEnd() and std.ascii.isAlphanumeric(self.text[self.index])) self.index += 1;

                const ident = try self.arena.dupe(u8, self.text[start_index..self.index]);
                const token: Token = switch (self.text[start_index - 1]) {
                    '@' => .{ .get_var = ident },
                    '$' => .{ .set_var = ident },
                    else => unreachable,
                };

                try token_list.append(self.arena, token);

                continue :state .start;
            },
            .end => {},
        }

        return token_list;
    }

    fn strToKeyword(str: []const u8) LexError!Token {
        const op = std.meta.stringToEnum(OpType, str) orelse return LexError.NotKeyword;
        // check so something like `not` does not get registered as `!`
        if (op.isOpSymbol()) return LexError.NotKeyword;
        return .{ .op = op };
    }

    fn isAtEnd(self: *Lexer) bool {
        return self.index >= self.text.len;
    }

    fn advance(self: *Lexer) u8 {
        self.index += 1;
        return self.text[self.index - 1];
    }

    fn previous(self: *Lexer) u8 {
        return self.text[self.index - 1];
    }

    fn peekAt(self: *Lexer, ahead: usize) u8 {
        return self.text[self.index + ahead];
    }

    fn matchAdvance(self: *Lexer, expected: u8) bool {
        if (self.peekAt(0) == expected) {
            self.index += 1;
            return true;
        } else return false;
    }
};

test "numbers and plus operator" {
    var lexer = Lexer{ .arena = std.testing.allocator };
    var token_list = try lexer.lex("3 4 +");
    defer token_list.deinit(std.testing.allocator);

    try std.testing.expectEqual(3, token_list.items.len);
    try std.testing.expectEqual(Token{ .int = 3 }, token_list.items[0]);
    try std.testing.expectEqual(Token{ .int = 4 }, token_list.items[1]);
    try std.testing.expectEqual(Token{ .op = .plus }, token_list.items[2]);
}

test "comment with no trailing newline doesn't run off the buffer" {
    var lexer = Lexer{ .arena = std.testing.allocator };
    var token_list = try lexer.lex("-5 ; rest is ignored");
    defer token_list.deinit(std.testing.allocator);

    try std.testing.expectEqual(1, token_list.items.len);
    try std.testing.expectEqual(Token{ .int = -5 }, token_list.items[0]);
}

test "errors on bad input" {
    var lexer = Lexer{ .arena = std.testing.allocator };

    try std.testing.expectError(LexError.UnsupportedCharacter, lexer.lex("?"));
    try std.testing.expectError(LexError.NotKeyword, lexer.lex("foo"));
    try std.testing.expectError(LexError.EqualWithoutSecondEqual, lexer.lex("="));
}

test "float literal" {
    var lexer = Lexer{ .arena = std.testing.allocator };
    var token_list = try lexer.lex("2.5");
    defer token_list.deinit(std.testing.allocator);

    try std.testing.expectEqual(1, token_list.items.len);
    try std.testing.expectEqual(Token{ .float = 2.5 }, token_list.items[0]);
}

test "negative float literal" {
    var lexer = Lexer{ .arena = std.testing.allocator };
    var token_list = try lexer.lex("-2.5");
    defer token_list.deinit(std.testing.allocator);

    try std.testing.expectEqual(1, token_list.items.len);
    try std.testing.expectEqual(Token{ .float = -2.5 }, token_list.items[0]);
}

test "mixed int and float" {
    var lexer = Lexer{ .arena = std.testing.allocator };
    var token_list = try lexer.lex("3 4.5 +");
    defer token_list.deinit(std.testing.allocator);

    try std.testing.expectEqual(3, token_list.items.len);
    try std.testing.expectEqual(Token{ .int = 3 }, token_list.items[0]);
    try std.testing.expectEqual(Token{ .float = 4.5 }, token_list.items[1]);
    try std.testing.expectEqual(Token{ .op = .plus }, token_list.items[2]);
}

test "error on decimal point without digits" {
    var lexer = Lexer{ .arena = std.testing.allocator };

    try std.testing.expectError(LexError.DecimalPointWithoutNumber, lexer.lex("3."));
}

test "error on set variable without proper identifier" {
    var lexer = Lexer{ .arena = std.testing.allocator };

    try std.testing.expectError(LexError.SetVarWithoutValidVar, lexer.lex("$"));
    try std.testing.expectError(LexError.SetVarWithoutValidVar, lexer.lex("$-"));
}

test "error on get variable without proper identifier" {
    var lexer = Lexer{ .arena = std.testing.allocator };

    try std.testing.expectError(LexError.GetVarWithoutValidVar, lexer.lex("@"));
    try std.testing.expectError(LexError.GetVarWithoutValidVar, lexer.lex("@+"));
}

test "set var and get var operations" {
    var arena_instance = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_instance.deinit();
    var lexer = Lexer{ .arena = arena_instance.allocator() };

    const token_list = try lexer.lex("5 $x @x");

    try std.testing.expectEqual(3, token_list.items.len);
    try std.testing.expectEqual(Token{ .int = 5 }, token_list.items[0]);

    try std.testing.expect(token_list.items[1] == .set_var);
    try std.testing.expectEqualStrings("x", token_list.items[1].set_var);

    try std.testing.expect(token_list.items[2] == .get_var);
    try std.testing.expectEqualStrings("x", token_list.items[2].get_var);
}

test "less than and less than or equal operators" {
    var lexer = Lexer{ .arena = std.testing.allocator };
    var token_list = try lexer.lex("< <=");
    defer token_list.deinit(std.testing.allocator);

    try std.testing.expectEqual(2, token_list.items.len);
    try std.testing.expectEqual(Token{ .op = .less }, token_list.items[0]);
    try std.testing.expectEqual(Token{ .op = .less_equal }, token_list.items[1]);
}

test "greater than and greater than or equal operators" {
    var lexer = Lexer{ .arena = std.testing.allocator };
    var token_list = try lexer.lex("> >=");
    defer token_list.deinit(std.testing.allocator);

    try std.testing.expectEqual(2, token_list.items.len);
    try std.testing.expectEqual(Token{ .op = .greater }, token_list.items[0]);
    try std.testing.expectEqual(Token{ .op = .greater_equal }, token_list.items[1]);
}

test "equal and not equal operators" {
    var lexer = Lexer{ .arena = std.testing.allocator };
    var token_list = try lexer.lex("== !=");
    defer token_list.deinit(std.testing.allocator);

    try std.testing.expectEqual(2, token_list.items.len);
    try std.testing.expectEqual(Token{ .op = .equal }, token_list.items[0]);
    try std.testing.expectEqual(Token{ .op = .not_equal }, token_list.items[1]);
}

test "not equal operator without =" {
    var lexer = Lexer{ .arena = std.testing.allocator };
    var token_list = try lexer.lex("!");
    defer token_list.deinit(std.testing.allocator);

    try std.testing.expectEqual(1, token_list.items.len);
    try std.testing.expectEqual(Token{ .op = .not }, token_list.items[0]);
}
