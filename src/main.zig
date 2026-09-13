const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Aligned = std.array_list.Aligned;

const lex = @import("./lexer.zig");
const Lexer = lex.Lexer;

const interp = @import("./interpreter.zig");
const Interpreter = interp.Interpreter;

const LexError = @import("./errors.zig").LexError;
const EvalError = @import("./errors.zig").EvalError;

fn repl(init: std.process.Init) !void {
    const arena: Allocator = init.arena.allocator();
    const io = init.io;
    // stdout
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    // stderr
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;
    // stdin
    var stdin_buffer: [1024]u8 = undefined;
    const stdin_file = Io.File.stdin();
    const is_tty = stdin_file.isTty(io) catch false;
    var stdin_file_reader: Io.File.Reader = .init(stdin_file, io, &stdin_buffer);
    const stdin = &stdin_file_reader.interface;

    var lexer = Lexer{ .arena = arena };
    var interpreter = try Interpreter.init(arena, stdout);

    loop: while (true) {
        // prompt part
        if (is_tty) try stdout.print("{s}", .{if (interpreter.block_level == 0) "# " else "< "});

        try stdout.flush();
        const prompt = try stdin.takeDelimiter('\n') orelse break :loop;

        // reading
        var token_list = lexer.lex(prompt) catch |err| {
            try switch (err) {
                LexError.UnsupportedCharacter => stderr.writeAll("Unsupported character found in line.\n"),
                LexError.NotKeyword => stderr.writeAll("The used identifier is not an already used keyword.\n"),
                LexError.Overflow => stderr.writeAll("The number was too big to store.\n"),
                LexError.OutOfMemory => stderr.writeAll("The token list ran out of memory.\n"),
                LexError.DecimalPointWithoutNumber => stderr.writeAll("The floating number must have at least 1 number after '.'\n"),
                LexError.GetVarWithoutValidVar => stderr.writeAll("The '@' symbol should have at least one alphabetic character.\n"),
                LexError.SetVarWithoutValidVar => stderr.writeAll("The '$' symbol should have at least one alphabetic character.\n"),
                LexError.CallVarWithoutValidVar => stderr.writeAll("The ':' symbol should have at least one alphabetic character.\n"),
                LexError.EqualWithoutSecondEqual => stderr.writeAll("The '=' symbol should have another '=' after itself.\n"),
            };
            try stderr.flush();
            continue :loop;
        };
        defer token_list.deinit(arena);

        // evaluating
        for (token_list.items) |token| {
            interpreter.eval(token) catch |err| {
                try switch (err) {
                    EvalError.DivisionByZero => stderr.writeAll("Division by zero is not allowed.\n"),
                    EvalError.StackUnderflow => stderr.writeAll("Stack underflow. Not enough arguments for the operation.\n"),
                    EvalError.OutOfMemory => stderr.writeAll("Stack has ran out of memory.\n"),
                    EvalError.WriteFailed => stderr.writeAll("Unable to write to stdout.\n"),
                    EvalError.OverflowOnCommand => stderr.writeAll("Number overflowed on command.\n"),
                    EvalError.InvalidFloat => stderr.writeAll("Command resulted in unrepresentable floating point number.\n"),
                    EvalError.UndefinedVariable => stderr.writeAll("There are no variables defined with that name.\n"),
                    EvalError.NotANumber => stderr.writeAll("Unable to use arithmetic operations with non-number arguments.\n"),
                    EvalError.NotAnInteger => stderr.writeAll("Unable to use arithmetic operations with non-integer arguments.\n"),
                    EvalError.NotAFloat => stderr.writeAll("Unable to use arithmetic operation on a non-float value.\n"),
                    EvalError.NotABoolean => stderr.writeAll("Unable to use boolean operation on a non-boolean value.\n"),
                    EvalError.NotABlock => stderr.writeAll("Unable to use block invoking operations with a non-block value.\n"),
                    EvalError.NonValueTokenInArray => stderr.writeAll("Unable to have array element have no value.\n"),
                    EvalError.UnmatchedRightBrace => stderr.writeAll("Found an unmatched '}' in code.\n"),
                    EvalError.UnmatchedRightBracket => stderr.writeAll("Found an unmatched ']' in code.\n"),
                    EvalError.CallStackOverflow => stderr.writeAll("Got over maximum allowed recursive calls.\n"),
                    EvalError.Quit => break :loop,
                };
                try stderr.flush();
                continue :loop;
            };
            try stdout.flush();
        }
    }
}

pub fn main(init: std.process.Init) !void {
    repl(init) catch |err| {
        std.log.err("Error occured: {s}\n", .{@errorName(err)});
    };
}

// made to invoke all tests within respective files
test "run tests" {
    _ = lex;
    _ = interp;
}
