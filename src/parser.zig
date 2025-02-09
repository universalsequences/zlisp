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

fn parseList(parser: *Parser, allocator: std.mem.Allocator) anyerror!lisp.LispVal {
    var list = std.ArrayList(lisp.LispVal).init(std.heap.page_allocator);
    // Note: In a production interpreter, eventually deinit/free the list.
    parser.skipWhitespace();
    while (true) {
        if (parser.peek() == null) return error.UnexpectedEOF;
        if (parser.peek().? == ')') {
            _ = parser.next(); // consume ')'
            break;
        }
        const expr = try parseExpr(parser, allocator);
        try list.append(expr);
        parser.skipWhitespace();
    }
    return lisp.LispVal{ .List = try list.toOwnedSlice() };
}

/// parseNumber is updated to handle negatives and floats.
fn parseNumber(parser: *Parser) anyerror!lisp.LispVal {
    const start = parser.pos;
    if (parser.peek().? == '-') {
        _ = parser.next();
    }
    while (true) {
        const ch = parser.peek();
        if (ch == null or !isDigit(ch.?)) break;
        _ = parser.next();
    }
    if (parser.peek() != null and parser.peek().? == '.') {
        _ = parser.next();
        while (true) {
            const ch = parser.peek();
            if (ch == null or !isDigit(ch.?)) break;
            _ = parser.next();
        }
    }
    const numStr = parser.input[start..parser.pos];
    const value = try std.fmt.parseFloat(f64, numStr);
    return lisp.LispVal{ .Number = value };
}

fn parseSymbol(parser: *Parser) anyerror!lisp.LispVal {
    const start = parser.pos;
    while (true) {
        const ch = parser.peek();
        if (ch == null or ch.? == ' ' or ch.? == '\t' or ch.? == '\n' or ch.? == ')' or ch.? == '(' or ch.? == '}') break;
        _ = parser.next();
    }
    const sym = parser.input[start..parser.pos];
    return lisp.LispVal{ .Symbol = sym };
}

fn parseObject(parser: *Parser, allocator: std.mem.Allocator) anyerror!lisp.LispVal {
    // We'll accumulate object entries in an ArrayList.
    var entries = std.ArrayList(lisp.ObjectEntry).init(std.heap.page_allocator);
    defer entries.deinit();

    parser.skipWhitespace();
    while (true) {
        if (parser.peek() == null) return error.UnexpectedEOF;
        if (parser.peek().? == '}') {
            _ = parser.next(); // consume '}'
            break;
        }
        parser.skipWhitespace();

        // Check for spread operator.
        // We assume the spread operator is given exactly as the symbol "..."
        const token = try parseSymbol(parser); // This returns a Symbol.
        if (@as(std.meta.Tag(lisp.LispVal), token) == .Symbol and
            std.mem.eql(u8, token.Symbol, "..."))
        {
            // This is a spread entry.
            parser.skipWhitespace();
            const spreadExpr = try parseExpr(parser, allocator);
            try entries.append(lisp.ObjectEntry{ .Spread = spreadExpr });
        } else {
            // Not a spread; treat token as a key.
            if (@as(std.meta.Tag(lisp.LispVal), token) != .Symbol) {
                return error.InvalidObjectKey;
            }
            const key = token.Symbol;
            parser.skipWhitespace();
            // Parse the value corresponding to this key.
            const value_expr = try parseExpr(parser, allocator);
            try entries.append(lisp.ObjectEntry{ .Pair = .{ .key = key, .value = value_expr } });
        }
        parser.skipWhitespace();
    }
    // Convert the entries to an owned slice.
    const owned_entries = try entries.toOwnedSlice();
    return lisp.LispVal{ .ObjectLiteral = owned_entries };
}

/// parseString: parses a string literal with double quotes.
/// Supports basic escape sequences: \" \\ \/ \n \t \r.
fn parseString(parser: *Parser, allocator: std.mem.Allocator) anyerror!lisp.LispVal {
    // Consume the opening double quote.
    if (parser.next() != '"') return error.UnexpectedEOF;

    // We'll accumulate characters in a dynamic array.
    var buffer = std.ArrayList(u8).init(std.heap.page_allocator);
    defer buffer.deinit();

    while (true) {
        const ch = parser.peek();
        if (ch == null) {
            return error.UnexpectedEOF;
        }
        if (ch.? == '"') {
            // Found closing quote.
            _ = parser.next(); // consume the closing quote
            break;
        } else if (ch.? == '\\') {
            // Handle escape sequences.
            _ = parser.next(); // consume the backslash
            const esc = parser.next();
            if (esc == null) return error.UnexpectedEOF;
            const escChar = esc.?;
            // Handle common escapes.
            if (escChar == '"' or escChar == '\\' or escChar == '/') {
                try buffer.append(escChar);
            } else if (escChar == 'n') {
                try buffer.append('\n');
            } else if (escChar == 't') {
                try buffer.append('\t');
            } else if (escChar == 'r') {
                try buffer.append('\r');
            } else {
                // Unknown escape: for now, simply append the character.
                try buffer.append(escChar);
            }
        } else {
            try buffer.append(ch.?);
            _ = parser.next();
        }
    }
    // Duplicate the contents of the buffer into persistent memory.
    const result_str = try allocator.dupe(u8, try buffer.toOwnedSlice());
    return lisp.LispVal{ .String = result_str };
}

/// parseExpr now also recognizes object literals.
pub fn parseExpr(parser: *Parser, allocator: std.mem.Allocator) anyerror!lisp.LispVal {
    parser.skipWhitespace();
    const ch = parser.peek();
    if (ch == null) return error.UnexpectedEOF;
    if (ch.? == '"') {
        return parseString(parser, allocator);
    } else if (ch.? == '(') {
        _ = parser.next(); // consume '('
        return parseList(parser, allocator);
    } else if (ch.? == '{') {
        _ = parser.next(); // consume '{'
        return parseObject(parser, allocator);
    } else if (isDigit(ch.?) or (ch.? == '-' and parser.pos + 1 < parser.input.len and
        (isDigit(parser.input[parser.pos + 1]) or parser.input[parser.pos + 1] == '.')))
    {
        return parseNumber(parser);
    } else {
        return parseSymbol(parser);
    }
}
