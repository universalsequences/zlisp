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

fn parseNumber(parser: *Parser) !lisp.LispVal {
    const start = parser.pos;
    // Allow for a negative sign.
    if (parser.peek().? == '-') {
        _ = parser.next();
    }
    while (true) {
        const ch = parser.peek();
        if (ch == null or !isDigit(ch.?)) break;
        _ = parser.next();
    }
    const numStr = parser.input[start..parser.pos];
    const value = try std.fmt.parseInt(i64, numStr, 10);
    return lisp.LispVal{ .Number = value };
}

fn isDigit(ch: u8) bool {
    return ch >= '0' and ch <= '9';
}

fn parseList(parser: *Parser) anyerror!lisp.LispVal {
    var list = std.ArrayList(lisp.LispVal).init(std.heap.page_allocator);
    // Note: In a production interpreter, ensure you eventually deinit/free the list.
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
    // For simplicity, we return a LispVal.List referring to the internal array.
    // (In a real interpreter, consider copying the list to a long-lived allocation.)
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
    if (ch.? == '(') {
        _ = parser.next(); // consume '('
        return parseList(parser);
    } else if (isDigit(ch.?) or ch.? == '-') {
        return parseNumber(parser);
    } else {
        return parseSymbol(parser);
    }
}
