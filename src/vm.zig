const std = @import("std");
const lisp = @import("value.zig");

const LispVal = lisp.LispVal;
const Env = lisp.Env;
const FnValue = lisp.FnValue;

//// Virtual Machine
////
////

pub const VMError = error{ StackUnderflow, InvalidResult, DivisionByZero, VariableNotFound, NotAFunction, ArgumentCountMismatch, NotANumber, NotACons };

/// Our simple bytecode instructions.
pub const Instruction = union(enum) {
    /// Push an integer constant onto the stack.
    PushConst: f64,
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

pub fn executeInstructions(instructions: []Instruction, env: *Env, allocator: std.mem.Allocator) anyerror!LispVal {
    // Create a stack to hold i64 values.
    var stack = std.ArrayList(LispVal).init(allocator);

    defer stack.deinit();

    var pc: usize = 0;
    while (pc < instructions.len) {
        const instr = instructions[pc];
        switch (instr) {
            .PushConst => {
                try stack.append(LispVal{ .Number = instr.PushConst });
                pc += 1;
            },
            .Add => {
                if (stack.items.len < 2) return VMError.StackUnderflow;
                const b = stack.items[stack.items.len - 1];
                stack.items.len -= 1;
                const a = stack.items[stack.items.len - 1];
                stack.items.len -= 1;
                if (!isArgsNumbers(a, b)) {
                    return VMError.NotANumber;
                }
                try stack.append(LispVal{ .Number = a.Number + b.Number });
                pc += 1;
            },
            .Sub => {
                if (stack.items.len < 2) return VMError.StackUnderflow;
                const b = stack.items[stack.items.len - 1];
                stack.items.len -= 1;
                const a = stack.items[stack.items.len - 1];
                stack.items.len -= 1;
                if (!isArgsNumbers(a, b)) {
                    return VMError.NotANumber;
                }
                try stack.append(LispVal{ .Number = a.Number - b.Number });
                pc += 1;
            },
            .Mul => {
                if (stack.items.len < 2) return VMError.StackUnderflow;
                const b = stack.items[stack.items.len - 1];
                stack.items.len -= 1;
                const a = stack.items[stack.items.len - 1];
                stack.items.len -= 1;
                if (!isArgsNumbers(a, b)) {
                    return VMError.NotANumber;
                }
                try stack.append(LispVal{ .Number = a.Number * b.Number });
                pc += 1;
            },
            .Div => {
                if (stack.items.len < 2) return VMError.StackUnderflow;
                const b = stack.items[stack.items.len - 1];
                stack.items.len -= 1;
                const a = stack.items[stack.items.len - 1];
                stack.items.len -= 1;
                if (!isArgsNumbers(a, b)) {
                    return VMError.NotANumber;
                }
                if (b.Number == 0) return VMError.DivisionByZero;
                try stack.append(LispVal{ .Number = @divExact(a.Number, b.Number) });
                pc += 1;
            },
            .LoadVar => {
                const varName = instr.LoadVar;
                // Look up the variable in the environment.
                if (env.get(varName)) |val| {
                    try stack.append(val);
                } else {
                    return VMError.VariableNotFound;
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
        }
    }
    // At the end, there should be exactly one value on the stack.
    if (stack.items.len != 1) return VMError.InvalidResult;
    return stack.items[0];
}
