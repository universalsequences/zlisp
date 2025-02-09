// integrated_test.zig
const std = @import("std");
const value = @import("value.zig");
const parser = @import("parser.zig");
const vm = @import("vm.zig");

const LispVal = value.LispVal;
const Env = value.Env;

test "integrated test: arithmetic expression (+ 1 2) = 3" {
    const allocator = std.heap.page_allocator;

    // 3. Create an empty environment for execution.
    var env = Env.init(allocator, null);
    defer env.deinit();

    // Our input source text.
    const input: []const u8 = "(+ 1 2)";

    // 1. Parse the source text into a LispVal expression.
    var p = parser.Parser.init(input);
    const expr = try parser.parseExpr(&p);

    // 2. Compile the parse tree into bytecode.
    var instructions = std.ArrayList(vm.Instruction).init(allocator);
    defer instructions.deinit();
    // For expressions that don't modify the environment (like arithmetic), we can pass null as currentEnv.
    try vm.compileExpr(expr, &instructions, allocator, &env);

    // 4. Execute the bytecode.
    const code = try instructions.toOwnedSlice();
    const result = try vm.executeInstructions(code, &env, allocator);

    // 5. Check that the result is a number equal to 3.
    try std.testing.expect(@as(std.meta.Tag(LispVal), result) == .Number);
    try std.testing.expect(result.Number == 3);
}

test "integrated test: function definition and call" {
    const allocator = std.heap.page_allocator;
    var env = Env.init(allocator, null);
    defer env.deinit();

    // We will run two expressions in sequence.
    // Expression 1: Define a function: (defun sq (x) (* x x))
    const defun_input: []const u8 = "(defun sq (x) (* x x))";
    var p1 = parser.Parser.init(defun_input);
    const defun_expr = try parser.parseExpr(&p1);
    var instr1 = std.ArrayList(vm.Instruction).init(allocator);
    defer instr1.deinit();
    // Pass the current environment so that the function gets stored in it.
    try vm.compileExpr(defun_expr, &instr1, allocator, &env);
    const code1 = try instr1.toOwnedSlice();
    // Execute the function definition; this should bind "sq" in the environment.
    _ = try vm.executeInstructions(code1, &env, allocator);

    // Verify that "sq" is now bound in the environment.
    const maybeSq = env.get("sq");
    try std.testing.expect(maybeSq != null);
    const sq_val = maybeSq.?; // unwrap the optional value

    try std.testing.expect(@as(std.meta.Tag(LispVal), sq_val) == .Function);

    // Expression 2: Call the function: (sq 5)
    const call_input: []const u8 = "(sq 5)";
    var p2 = parser.Parser.init(call_input);
    const call_expr = try parser.parseExpr(&p2);
    var instr2 = std.ArrayList(vm.Instruction).init(allocator);
    defer instr2.deinit();
    // Use the same environment (with "sq" defined)
    try vm.compileExpr(call_expr, &instr2, allocator, &env);
    const code2 = try instr2.toOwnedSlice();
    const call_result = try vm.executeInstructions(code2, &env, allocator);

    // Check that the result is a number equal to 25.
    try std.testing.expect(@as(std.meta.Tag(LispVal), call_result) == .Number);
    try std.testing.expect(call_result.Number == 25);
}
