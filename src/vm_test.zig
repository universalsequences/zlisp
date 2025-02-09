// vm_test.zig
const std = @import("std");
const vm = @import("vm.zig");
const value = @import("value.zig");

// Short aliases for our types.
const Instruction = vm.Instruction;
const LispVal = value.LispVal;
const Env = value.Env;

test "VM arithmetic: 1 + 2 = 3" {
    const allocator = std.heap.page_allocator;

    // Create an ArrayList to hold our instructions.
    var instructions = std.ArrayList(Instruction).init(allocator);
    defer instructions.deinit();

    // Build the instruction sequence:
    //   PushConst 1
    //   PushConst 2
    //   Add
    //   Return
    try instructions.append(Instruction{ .PushConst = 1 });
    try instructions.append(Instruction{ .PushConst = 2 });
    try instructions.append(Instruction.Add);
    try instructions.append(Instruction.Return);

    // Create an empty environment (with no parent).
    var env = Env.init(allocator, null);
    defer env.deinit();

    // Execute the instructions.
    const result = try vm.executeInstructions(try instructions.toOwnedSlice(), &env, allocator);

    // Check that the result is a number and equals 3.
    // We assume that your LispVal union’s tag can be extracted using std.meta.Tag.
    try std.testing.expect(@as(std.meta.Tag(LispVal), result) == .Number);
    try std.testing.expect(result.Number == 3);
}

test "VM arithmetic: (1 + 2) * 4 = 12" {
    const allocator = std.heap.page_allocator;

    var instructions = std.ArrayList(Instruction).init(allocator);
    defer instructions.deinit();

    // Build a sequence for (1 + 2) * 4:
    //   PushConst 1
    //   PushConst 2
    //   Add         ; => computes 1 + 2, pushes 3
    //   PushConst 4
    //   Mul         ; => computes 3 * 4, pushes 12
    //   Return
    try instructions.append(Instruction{ .PushConst = 1 });
    try instructions.append(Instruction{ .PushConst = 2 });
    try instructions.append(Instruction.Add);
    try instructions.append(Instruction{ .PushConst = 4 });
    try instructions.append(Instruction.Mul);
    try instructions.append(Instruction.Return);

    var env = Env.init(allocator, null);
    defer env.deinit();

    const result = try vm.executeInstructions(try instructions.toOwnedSlice(), &env, allocator);

    try std.testing.expect(@as(std.meta.Tag(LispVal), result) == .Number);
    try std.testing.expect(result.Number == 12);
}
