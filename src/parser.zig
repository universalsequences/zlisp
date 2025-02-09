const lisp = @import("value.zig");
const std = @import("std");

pub const Parser = struct {
    input: []const u8,
    pos: usize,

    pub fn init(input: []const u8) Parser {
        return Parser{ .input = input, .pos = 0 };
    }

    pub fn peek(self: *Parser) ?u8 {
        if (self.pos >= self.input.len) return null;
        return self.input[self.pos];
    }

    pub fn next(self: *Parser) ?u8 {
        if (self.pos >= self.input.len) return null;
        const ch = self.input[self.pos];
        self.pos += 1;
        return ch;
    }

    /// Skip spaces, tabs, newlines.
    pub fn skipWhitespace(self: *Parser) void {
        while (true) {
            const ch = self.peek();
            if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') {
                _ = self.next();
            } else {
                break;
            }
        }
    }
};

fn isDigit(ch: u8) bool {
    return ch >= '0' and ch <= '9';
}

/// parseNumber now supports negative numbers and floats.
fn parseNumber(parser: *Parser) anyerror!lisp.LispVal {
    const start = parser.pos;
    // Allow for a negative sign.
    if (parser.peek().? == '-') {
        _ = parser.next();
    }
    // Consume digits before any decimal point.
    while (true) {
        const ch = parser.peek();
        if (ch == null or !isDigit(ch.?)) break;
        _ = parser.next();
    }
    // If there is a decimal point, consume it and following digits.
    if (parser.peek() != null and parser.peek().? == '.') {
        _ = parser.next();
        while (true) {
            const ch = parser.peek();
            if (ch == null or !isDigit(ch.?)) break;
            _ = parser.next();
        }
    }
    // Optional: You can later add exponent handling here.
    const numStr = parser.input[start..parser.pos];
    // Parse the string into a floating-point value.
    const value = try std.fmt.parseFloat(f64, numStr);
    return lisp.LispVal{ .Number = value };
}

fn parseList(parser: *Parser) anyerror!lisp.LispVal {
    var list = std.ArrayList(lisp.LispVal).init(std.heap.page_allocator);
    // Note: In a production interpreter, eventually deinit/free the list.
    parser.skipWhitespace();
    while (true) {
        if (parser.peek() == null) return error.UnexpectedEOF;
        if (parser.peek().? == ')') {
            _ = parser.next(); // consume ')'
            break;
        }
        const expr = try parseExpr(parser);
        try list.append(expr);
        parser.skipWhitespace();
    }
    return lisp.LispVal{ .List = try list.toOwnedSlice() };
}

fn parseSymbol(parser: *Parser) anyerror!lisp.LispVal {
    const start = parser.pos;
    while (true) {
        const ch = parser.peek();
        if (ch == null or ch.? == ' ' or ch.? == '\t' or ch.? == '\n' or ch.? == ')' or ch.? == '(') break;
        _ = parser.next();
    }
    const sym = parser.input[start..parser.pos];
    return lisp.LispVal{ .Symbol = sym };
}

pub fn parseExpr(parser: *Parser) anyerror!lisp.LispVal {
    parser.skipWhitespace();
    const ch = parser.peek();
    if (ch == null) {
        return error.UnexpectedEOF;
    }
    // Decide if this is a number:
    // If the character is a digit, or it’s '-' followed by a digit or a '.'
    if (isDigit(ch.?) or
        (ch.? == '-' and parser.pos + 1 < parser.input.len and
        (isDigit(parser.input[parser.pos + 1]) or parser.input[parser.pos + 1] == '.')))
    {
        return parseNumber(parser);
    } else if (ch.? == '(') {
        _ = parser.next(); // consume '('
        return parseList(parser);
    } else {
        return parseSymbol(parser);
    }
}
