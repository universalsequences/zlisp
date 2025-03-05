const std = @import("std");
const lisp = @import("value.zig");
const vm = @import("vm.zig");
const parser = @import("parser.zig");
const builtin = @import("builtin.zig");
const compiler = @import("compile.zig");
const gc_mod = @import("gc.zig");

const LispVal = lisp.LispVal;

pub fn main() anyerror!void {
    var allocator = std.heap.page_allocator;
    var stdout = std.io.getStdOut().writer();
    var stdin = std.io.getStdIn().reader();

    // Initialize garbage collector but don't use it for now
    var gc = gc_mod.GarbageCollector.init(allocator);
    defer gc.deinit();

    // Create the global environment directly - don't use GC yet
    var globalEnv = lisp.Env.init(allocator, null);
    const globalEnv_ptr = &globalEnv;
    defer globalEnv.deinit();

    // Pass the GC so it's available, but we won't use it actively yet
    try builtin.init(globalEnv_ptr, &gc);

    while (true) {
        try stdout.print("> ", .{});
        const line = stdin.readUntilDelimiterAlloc(allocator, '\n', 1024) catch |err| {
            if (err == error.EndOfStream) {
                break; // End REPL if we hit EOF
            }
            try stdout.print("Input error: {}\n", .{err});
            continue;
        };
        defer allocator.free(line);

        if (line.len == 0) continue; // Skip empty line, don't exit

        var parsed = parser.Parser.init(line);
        const expr = parser.parseExpr(&parsed, allocator) catch |err| {
            try stdout.print("Parse error: {}\n", .{err});
            continue;
        };

        var instructions = std.ArrayList(vm.Instruction).init(allocator);
        defer instructions.deinit();

        compiler.compileExpr(expr, &instructions, allocator, globalEnv_ptr) catch |err| {
            try stdout.print("Compile error: {}\n", .{err});
            continue;
        };

        var stack = std.ArrayList(LispVal).init(allocator);
        defer stack.deinit();

        const result = vm.executeInstructions(try instructions.toOwnedSlice(), globalEnv_ptr, allocator) catch |err| {
            try stdout.print("Execution error: {}\n", .{err});
            continue;
        };

        try stdout.print("Result: {!s}\n", .{result.toString(allocator)});
        try stdout.print("gc.objects: {d}\n", .{gc.objects.items.len});

        // Garbage collection disabled for now
        if (gc.objects.items.len > 0) {
            try gc.markRoots(globalEnv_ptr, null);
            try gc.collect();
        }
    }
}
