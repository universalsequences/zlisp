const std = @import("std");
const lisp = @import("value.zig");
const builtin = @import("builtin.zig");

const LispVal = lisp.LispVal;
const Env = lisp.Env;
const FnValue = lisp.FnValue;
const RuntimeObject = lisp.RuntimeObject;

//// Virtual Machine
////
////

pub const VMError = error{ StackUnderflow, InvalidResult, DivisionByZero, VariableNotFound, NotAFunction, ArgumentCountMismatch, NotANumber, NotACons, NotAnObject, InvalidKey, TypeMismatch };

/// Our simple bytecode instructions.
pub const Instruction = union(enum) {
    /// Push an integer constant onto the stack.
    PushConst: f64,
    PushConstString: []const u8,
    PushQuote: LispVal,
    Add,
    Sub,
    Mul,
    Div,
    Return,
    LoadVar: []const u8,
    StoreVar: []const u8,
    DefineFunc: []const u8,
    PushFunc: *FnValue,
    Call: u32, // the number of arguments
    Jump: u32, // Unconditional jump with relative offset.
    JumpIfFalse: u32, // Conditional jump: if condition is false, add offset to pc.
    PushEmptyObject,
    PushConstSymbol: []const u8,
    CallObjSet: u32,
    CallObjMerge: u32,
};

pub fn isArgsNumbers(a: LispVal, b: LispVal) bool {
    return switch (a) {
        .Number => switch (b) {
            .Number => true,
            else => false,
        },
        else => false,
    };
}

pub fn isArgsVectors(a: LispVal, b: LispVal) bool {
    return switch (a) {
        .Vector => switch (b) {
            .Vector => true,
            else => false,
        },
        else => false,
    };
}

const VectorOp = enum {
    Add,
    Sub,
    Mul,
    Div,
};

fn applyVectorOp(comptime op: VectorOp, allocator: std.mem.Allocator, v1: []f32, v2: []f32) ![]f32 {
    if (v1.len != v2.len) return error.VectorLengthMismatch;
    var result = try allocator.alloc(f32, v1.len);
    errdefer allocator.free(result);

    const Vector = @Vector(4, f32);
    var i: usize = 0;

    // Process in chunks of 4 using SIMD
    while (i + 4 <= v1.len) {
        const chunk1: Vector = @as(*const [4]f32, @ptrCast(v1.ptr + i)).*;
        const chunk2: Vector = @as(*const [4]f32, @ptrCast(v2.ptr + i)).*;

        // Apply the operation based on the enum
        const out = switch (op) {
            .Add => chunk1 + chunk2,
            .Sub => chunk1 - chunk2,
            .Mul => chunk1 * chunk2,
            .Div => chunk1 / chunk2,
        };

        @as(*[4]f32, @ptrCast(result.ptr + i)).* = @as([4]f32, out);
        i += 4;
    }

    // Handle remaining elements
    while (i < v1.len) : (i += 1) {
        result[i] = switch (op) {
            .Add => v1[i] + v2[i],
            .Sub => v1[i] - v2[i],
            .Mul => v1[i] * v2[i],
            .Div => v1[i] / v2[i],
        };
    }

    return result;
}

pub fn executeInstructions(instructions: []Instruction, env: *Env, allocator: std.mem.Allocator) anyerror!LispVal {
    std.log.debug("{any}", .{instructions});
    // Create a stack to hold i64 values.
    var stack = std.ArrayList(LispVal).init(allocator);

    defer stack.deinit();

    var pc: usize = 0;
    while (pc < instructions.len) {
        const instr = instructions[pc];
        switch (instr) {
            .PushConst => |c| {
                try stack.append(LispVal{ .Number = c });
                pc += 1;
            },
            .PushConstString => |s| {
                try stack.append(LispVal{ .String = s });
                pc += 1;
            },
            .PushQuote => |quote| {
                switch (quote) {
                    .List => |list| {
                        try stack.append(try builtin.builtin_list(list, allocator));
                    },
                    else => {
                        try stack.append(quote);
                    },
                }
                pc += 1;
            },
            .Add => {
                if (stack.items.len < 2) return VMError.StackUnderflow;
                const b = stack.items[stack.items.len - 1];
                stack.items.len -= 1;
                const a = stack.items[stack.items.len - 1];
                stack.items.len -= 1;
                if (isArgsVectors(a, b)) {
                    const sum = try applyVectorOp(.Add, allocator, a.Vector, b.Vector);
                    try stack.append(LispVal{ .Vector = sum });
                } else if (!isArgsNumbers(a, b)) {
                    return VMError.NotANumber;
                } else {
                    try stack.append(LispVal{ .Number = a.Number + b.Number });
                }
                pc += 1;
            },
            .Sub => {
                if (stack.items.len < 2) return VMError.StackUnderflow;
                const b = stack.items[stack.items.len - 1];
                stack.items.len -= 1;
                const a = stack.items[stack.items.len - 1];
                stack.items.len -= 1;
                if (isArgsVectors(a, b)) {
                    const sum = try applyVectorOp(.Sub, allocator, a.Vector, b.Vector);
                    try stack.append(LispVal{ .Vector = sum });
                } else if (!isArgsNumbers(a, b)) {
                    return VMError.NotANumber;
                } else {
                    try stack.append(LispVal{ .Number = a.Number - b.Number });
                }
                pc += 1;
            },
            .Mul => {
                if (stack.items.len < 2) return VMError.StackUnderflow;
                const b = stack.items[stack.items.len - 1];
                stack.items.len -= 1;
                const a = stack.items[stack.items.len - 1];
                stack.items.len -= 1;
                if (isArgsVectors(a, b)) {
                    const sum = try applyVectorOp(.Mul, allocator, a.Vector, b.Vector);
                    try stack.append(LispVal{ .Vector = sum });
                } else if (!isArgsNumbers(a, b)) {
                    return VMError.NotANumber;
                } else {
                    try stack.append(LispVal{ .Number = a.Number * b.Number });
                }
                pc += 1;
            },
            .Div => {
                if (stack.items.len < 2) return VMError.StackUnderflow;
                const b = stack.items[stack.items.len - 1];
                stack.items.len -= 1;
                const a = stack.items[stack.items.len - 1];
                stack.items.len -= 1;
                if (isArgsVectors(a, b)) {
                    const sum = try applyVectorOp(.Div, allocator, a.Vector, b.Vector);
                    try stack.append(LispVal{ .Vector = sum });
                } else if (!isArgsNumbers(a, b)) {
                    return VMError.NotANumber;
                } else if (b.Number == 0) {
                    return VMError.DivisionByZero;
                } else {
                    try stack.append(LispVal{ .Number = @divExact(a.Number, b.Number) });
                }
                pc += 1;
            },
            .LoadVar => {
                const varName: []const u8 = instr.LoadVar;
                // Look up the variable in the environment.
                if (env.get(varName)) |val| {
                    try stack.append(val);
                } else {
                    switch (varName[0]) {
                        '+', '-', '*', '/' => {
                            try stack.append(LispVal{ .Symbol = varName });
                        },
                        else => {
                            if (std.mem.startsWith(u8, varName, "max") or
                                std.mem.startsWith(u8, varName, "min"))
                            {
                                try stack.append(LispVal{ .Symbol = varName });
                            } else {
                                return VMError.VariableNotFound;
                            }
                        },
                    }
                }
                pc += 1;
            },
            .StoreVar => {
                if (stack.items.len < 1) return VMError.StackUnderflow;
                const val = stack.items[stack.items.len - 1];
                const varName = instr.StoreVar;
                // Insert or update the variable in the environment.
                try env.put(varName, val);
                pc += 1;
            },
            .DefineFunc => {
                // For DefineFunc, pop the function value from the stack and
                // bind it to the given function name in the environment.
                if (stack.items.len < 1) return VMError.StackUnderflow;
                const funcVal = stack.items[stack.items.len - 1];
                // Optionally, verify that funcVal.tag == .Function.
                try env.put(instr.DefineFunc, funcVal);
                // Optionally leave the function value on the stack.
                pc += 1;
            },
            .PushFunc => {
                // Push the function value (pointer) onto the stack.
                try stack.append(LispVal{ .Function = instr.PushFunc });
                pc += 1;
            },
            .Return => {
                // This could signal the end of a function execution frame.
                // (Implementation depends on how you structure your call frames.)
                // For now, you might simply break out.
                pc += 1;
                break;
            },
            .Call => {
                // The number of arguments is provided by the Call instruction.
                const argCount = instr.Call;
                // Ensure that there are at least (argCount + 1) items on the stack:
                // one for the function and argCount for the arguments.
                if (stack.items.len < argCount + 1) return VMError.StackUnderflow;

                // Extract the arguments. The order depends on your convention.
                // Suppose our convention is:
                //   [ ... , function, arg1, arg2, ..., argN ]
                // We need to collect the arguments in the proper order.
                var args = try allocator.alloc(LispVal, argCount);
                for (0..argCount) |i| {
                    // The top of the stack is the last argument.
                    args[argCount - 1 - i] = stack.pop();
                }
                // Now pop the function value.
                const funcVal = stack.pop();

                switch (funcVal) {
                    .Function => {
                        const fnPtr = funcVal.Function;
                        // Create a new local environment for the function call.
                        var localEnv = Env.init(allocator, fnPtr.env);
                        // Check that the number of arguments matches the number of parameters.
                        if (args.len != fnPtr.params.len) return VMError.ArgumentCountMismatch;
                        // Bind each parameter to the corresponding argument.
                        for (0..args.len) |i| {
                            try localEnv.put(fnPtr.params[i], args[i]);
                        }
                        // Now execute the function’s code.
                        // We assume that the function’s compiled code is a slice of instructions.
                        const retVal = try executeInstructions(fnPtr.code, &localEnv, allocator);
                        // Push the return value onto the current stack.
                        try stack.append(retVal);
                    },
                    .Native => |nativeFn| {
                        const args_ptr = @as(*anyopaque, @ptrCast(args.ptr));
                        const result_ptr = try nativeFn(args_ptr, args.len, allocator);
                        const result = @as(*const LispVal, @ptrCast(@alignCast(result_ptr))).*;
                        try stack.append(result);
                    },
                    else => {
                        return VMError.NotAFunction;
                    },
                }
                pc += 1;
            },
            .JumpIfFalse => {
                // Pop the condition value off the stack.
                if (stack.items.len < 1) return VMError.StackUnderflow;
                const cond = stack.pop();
                // We assume that a condition is a Number: nonzero means true, zero means false.
                if (@as(std.meta.Tag(LispVal), cond) != .Number or cond.Number == 0) {
                    pc += @intCast(instr.JumpIfFalse);
                } else {
                    pc += 1;
                }
            },
            .Jump => {
                pc += @intCast(instr.Jump);
            },
            .PushEmptyObject => {
                // Allocate a new runtime object.
                const obj_ptr = try allocator.create(RuntimeObject);
                obj_ptr.* = RuntimeObject{
                    .table = std.StringHashMap(LispVal).init(allocator),
                };
                try stack.append(LispVal{ .Object = obj_ptr });
                pc += 1;
            },
            .PushConstSymbol => {
                // Duplicate the symbol string so it lives persistently.
                const persistentKey = try allocator.dupe(u8, instr.PushConstSymbol);
                try stack.append(LispVal{ .Symbol = persistentKey });
                pc += 1;
            },
            .CallObjSet => {
                // Expect the stack order (from top):
                // [ value, key, object ]
                if (stack.items.len < 3) return VMError.StackUnderflow;
                const value_val = stack.pop();
                const key_val = stack.pop();
                const obj_val = stack.pop();
                if (@as(std.meta.Tag(LispVal), obj_val) != .Object) return VMError.NotAnObject;
                if (@as(std.meta.Tag(LispVal), key_val) != .Symbol) return VMError.InvalidKey;
                const obj_ptr = obj_val.Object;
                const key_str = key_val.Symbol;
                // Update the object's hash map.
                try obj_ptr.table.put(key_str, value_val);
                // Push the updated object back.
                try stack.append(LispVal{ .Object = obj_ptr });
                pc += 1;
            },
            .CallObjMerge => {
                std.log.debug("about to merge\n", .{});
                // For merging, expect two objects on the stack: source then destination.
                if (stack.items.len < 2) return VMError.StackUnderflow;
                const src_obj_val = stack.pop();
                const dst_obj_val = stack.pop();
                if (@as(std.meta.Tag(LispVal), dst_obj_val) != .Object) return VMError.NotAnObject;
                if (@as(std.meta.Tag(LispVal), src_obj_val) != .Object) return VMError.NotAnObject;
                const dst_ptr = dst_obj_val.Object;
                const src_ptr = src_obj_val.Object;
                var iter = src_ptr.table.iterator();
                while (iter.next()) |entry| {
                    try dst_ptr.table.put(entry.key_ptr.*, entry.value_ptr.*);
                }
                // Push the merged object back.
                try stack.append(LispVal{ .Object = dst_ptr });
                pc += 1;
            },
        }
    }
    // At the end, there should be exactly one value on the stack.
    if (stack.items.len != 1) return VMError.InvalidResult;
    return stack.items[0];
}
