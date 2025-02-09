const std = @import("std");
const lisp = @import("value.zig");
const vm = @import("vm.zig");
const parser = @import("parser.zig");
const builtin = @import("builtin.zig");
const compiler = @import("compile.zig");

const LispVal = lisp.LispVal;

pub fn main() anyerror!void {
    var allocator = std.heap.page_allocator;
    var stdout = std.io.getStdOut().writer();
    var stdin = std.io.getStdIn().reader();

    var globalEnv = lisp.Env.init(allocator, null);
    defer globalEnv.deinit();
    try builtin.init(&globalEnv);

    while (true) {
        try stdout.print("> ", .{});
        const line = try stdin.readUntilDelimiterAlloc(allocator, '\n', 1024);
        if (line.len == 0) break;

        var p = parser.Parser.init(line);
        const expr = try parser.parseExpr(&p, allocator);

        var instructions = std.ArrayList(vm.Instruction).init(allocator);
        defer instructions.deinit();
        try compiler.compileExpr(expr, &instructions, allocator, &globalEnv);

        // Execute the bytecode.
        const result = try vm.executeInstructions(try instructions.toOwnedSlice(), &globalEnv, allocator);

        try stdout.print("Result: {!s}\n", .{result.toString(allocator)});

        allocator.free(line);
    }
}
