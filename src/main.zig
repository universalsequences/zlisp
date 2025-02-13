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
        const line = stdin.readUntilDelimiterAlloc(allocator, '\n', 1024) catch |err| {
            try stdout.print("Input error: {}\n", .{err});
            continue;
        };
        defer allocator.free(line);

        if (line.len == 0) break;

        var parsed = parser.Parser.init(line);
        const expr = parser.parseExpr(&parsed, allocator) catch |err| {
            try stdout.print("Parse error: {}\n", .{err});
            continue;
        };

        var instructions = std.ArrayList(vm.Instruction).init(allocator);
        defer instructions.deinit();

        compiler.compileExpr(expr, &instructions, allocator, &globalEnv) catch |err| {
            try stdout.print("Compile error: {}\n", .{err});
            continue;
        };

        const result = vm.executeInstructions(try instructions.toOwnedSlice(), &globalEnv, allocator) catch |err| {
            try stdout.print("Execution error: {}\n", .{err});
            continue;
        };

        try stdout.print("Result: {!s}\n", .{result.toString(allocator)});
    }
}
