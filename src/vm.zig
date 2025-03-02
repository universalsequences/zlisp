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

pub const VMError = error{ StackUnderflow, InvalidResult, DivisionByZero, VariableNotFound, NotAFunction, ArgumentCountMismatch, NotANumber, NotACons, NotAnObject, InvalidKey, TypeMismatch, NoParentScope };

const Frame = struct {
    code: []Instruction,
    pc: usize,
    env: *Env,
};

/// Our simple bytecode instructions.
pub const Instruction = union(enum) {
    /// Push an integer constant onto the stack.
    PushConst: f64,
    PushConstString: []const u8,
    PushQuote: LispVal,
    Add: usize, // arity
    Sub: usize, // arity
    Mul: usize, // arity
    Div: usize, // arity
    Dup, // duplicates
    EnterScope, // let statements
    ExitScope, // let statements
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
    std.log.debug("{any}\n", .{instructions});
    // Initialize operand stack
    var stack = std.ArrayList(LispVal).init(allocator);
    defer stack.deinit();

    // Initialize call stack
    var call_stack = std.ArrayList(Frame).init(allocator);
    defer call_stack.deinit();

    // Push the initial frame for top-level code
    try call_stack.append(Frame{
        .code = instructions,
        .pc = 0,
        .env = env,
    });

    // Main execution loop: continue while there are frames to process
    while (call_stack.items.len > 0) {
        // Get a mutable reference to the current frame (top of the call stack)
        var current_frame = &call_stack.items[call_stack.items.len - 1];

        // Check if we've reached the end of the current frame's code
        if (current_frame.pc >= current_frame.code.len) {
            if (call_stack.items.len == 1) {
                // Top-level frame finished: return the result
                if (stack.items.len != 1) return VMError.InvalidResult;
                return stack.items[0];
            } else {
                // Function frame finished: pop it and continue in the caller
                _ = call_stack.pop();
                continue;
            }
        }

        // Fetch the current instruction
        const instr = current_frame.code[current_frame.pc];

        // Process the instruction
        switch (instr) {
            // Push a constant number
            .PushConst => |c| {
                try stack.append(LispVal{ .Number = c });
                current_frame.pc += 1;
            },
            // Push a constant string
            .PushConstString => |s| {
                try stack.append(LispVal{ .String = s });
                current_frame.pc += 1;
            },
            // Push a quoted value (e.g., list or symbol)
            .PushQuote => |quote| {
                switch (quote) {
                    .List => |list| {
                        try stack.append(try builtin.builtin_list(list, allocator));
                    },
                    else => {
                        try stack.append(quote);
                    },
                }
                current_frame.pc += 1;
            },
            // Addition operation
            .Add => |arity| {
                if (stack.items.len < 2) return VMError.StackUnderflow;
                const b = stack.pop();
                const a = stack.pop();
                if (isArgsVectors(a, b)) {
                    const sum = try applyVectorOp(.Add, allocator, a.Vector, b.Vector);
                    try stack.append(LispVal{ .Vector = sum });
                } else if (!isArgsNumbers(a, b)) {
                    return VMError.NotANumber;
                } else {
                    var sum = a.Number + b.Number;
                    for (2..arity) |_| {
                        const elem = stack.pop();
                        if (@as(std.meta.Tag(LispVal), elem) != .Number) {
                            return VMError.NotANumber;
                        }
                        sum += elem.Number;
                    }
                    try stack.append(LispVal{ .Number = sum });
                }
                current_frame.pc += 1;
            },
            // Subtraction operation
            .Sub => {
                if (stack.items.len < 2) return VMError.StackUnderflow;
                const b = stack.pop();
                const a = stack.pop();
                if (isArgsVectors(a, b)) {
                    const diff = try applyVectorOp(.Sub, allocator, a.Vector, b.Vector);
                    try stack.append(LispVal{ .Vector = diff });
                } else if (!isArgsNumbers(a, b)) {
                    return VMError.NotANumber;
                } else {
                    try stack.append(LispVal{ .Number = a.Number - b.Number });
                }
                current_frame.pc += 1;
            },
            // Multiplication operation
            .Mul => |arity| {
                if (stack.items.len < 2) return VMError.StackUnderflow;
                const b = stack.pop();
                const a = stack.pop();
                if (isArgsVectors(a, b)) {
                    const prod = try applyVectorOp(.Mul, allocator, a.Vector, b.Vector);
                    try stack.append(LispVal{ .Vector = prod });
                } else if (!isArgsNumbers(a, b)) {
                    return VMError.NotANumber;
                } else {
                    var prod = a.Number * b.Number;
                    for (2..arity) |_| {
                        const elem = stack.pop();
                        if (@as(std.meta.Tag(LispVal), elem) != .Number) {
                            return VMError.NotANumber;
                        }
                        prod *= elem.Number;
                    }
                    try stack.append(LispVal{ .Number = prod });
                }
                current_frame.pc += 1;
            },
            // Division operation
            .Div => {
                if (stack.items.len < 2) return VMError.StackUnderflow;
                const b = stack.pop();
                const a = stack.pop();
                if (isArgsVectors(a, b)) {
                    const quot = try applyVectorOp(.Div, allocator, a.Vector, b.Vector);
                    try stack.append(LispVal{ .Vector = quot });
                } else if (!isArgsNumbers(a, b)) {
                    return VMError.NotANumber;
                } else if (b.Number == 0) {
                    return VMError.DivisionByZero;
                } else {
                    try stack.append(LispVal{ .Number = @divExact(a.Number, b.Number) });
                }
                current_frame.pc += 1;
            },
            .EnterScope => {
                // Create a new environment for the function
                var localEnv = Env.init(allocator, current_frame.env);
                current_frame.env = &localEnv;
                current_frame.pc += 1;
            },
            .ExitScope => {
                if (current_frame.env.parent) |parent| {
                    current_frame.env = parent;
                    current_frame.pc += 1;
                } else {
                    return VMError.NoParentScope;
                }
            },
            // Load a variable from the environment
            .LoadVar => |varName| {
                if (current_frame.env.get(varName)) |val| {
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
                current_frame.pc += 1;
            },
            // Store a value into the environment
            .StoreVar => |varName| {
                if (stack.items.len < 1) return VMError.StackUnderflow;
                const val = stack.pop();
                try current_frame.env.put(varName, val);
                current_frame.pc += 1;
            },
            .Dup => {
                if (stack.items.len < 1) return error.StackUnderflow;
                const val = stack.items[stack.items.len - 1];
                try stack.append(val);
                current_frame.pc += 1;
            },
            // Define a function in the environment
            .DefineFunc => |funcName| {
                if (stack.items.len < 1) return VMError.StackUnderflow;
                const funcVal = stack.items[stack.items.len - 1];
                try current_frame.env.put(funcName, funcVal);
                current_frame.pc += 1;
            },
            // Push a function pointer onto the stack
            .PushFunc => |fnPtr| {
                try stack.append(LispVal{ .Function = fnPtr });
                current_frame.pc += 1;
            },
            // Return from the current frame
            .Return => {
                if (call_stack.items.len == 1) {
                    // Top-level return: return the result
                    if (stack.items.len != 1) return VMError.InvalidResult;
                    return stack.items[0];
                } else {
                    // Function return: pop the frame, result stays on stack
                    _ = call_stack.pop();
                }
            },
            // Function call
            .Call => |argCount| {
                if (stack.items.len < argCount + 1) return VMError.StackUnderflow;
                // Pop arguments and function
                var args = try allocator.alloc(LispVal, argCount);
                for (0..argCount) |i| {
                    args[argCount - 1 - i] = stack.pop();
                }
                const funcVal = stack.pop();
                switch (funcVal) {
                    .Function => |fnPtr| {
                        if (args.len != fnPtr.params.len) return VMError.ArgumentCountMismatch;
                        // Create a new environment for the function
                        var localEnv = Env.init(allocator, fnPtr.env);
                        for (0..args.len) |i| {
                            try localEnv.put(fnPtr.params[i], args[i]);
                        }
                        // Advance the current frame's pc to the next instruction
                        current_frame.pc += 1;
                        // Push a new frame for the function
                        try call_stack.append(Frame{
                            .code = fnPtr.code,
                            .pc = 0,
                            .env = &localEnv,
                        });
                    },
                    .Native => |nativeFn| {
                        // Execute native function directly
                        const args_ptr = @as(*anyopaque, @ptrCast(args.ptr));
                        const result_ptr = try nativeFn(args_ptr, args.len, allocator);
                        const result = @as(*const LispVal, @ptrCast(@alignCast(result_ptr))).*;
                        try stack.append(result);
                        current_frame.pc += 1;
                    },
                    else => return VMError.NotAFunction,
                }
            },
            // Conditional jump if false
            .JumpIfFalse => |offset| {
                if (stack.items.len < 1) return VMError.StackUnderflow;
                const cond = stack.pop();
                if (@as(std.meta.Tag(LispVal), cond) != .Number or cond.Number == 0) {
                    current_frame.pc += offset;
                } else {
                    current_frame.pc += 1;
                }
            },
            // Unconditional jump
            .Jump => |offset| {
                current_frame.pc += offset;
            },
            // Push an empty object
            .PushEmptyObject => {
                const obj_ptr = try allocator.create(RuntimeObject);
                obj_ptr.* = RuntimeObject{
                    .table = std.StringHashMap(LispVal).init(allocator),
                };
                try stack.append(LispVal{ .Object = obj_ptr });
                current_frame.pc += 1;
            },
            // Push a constant symbol
            .PushConstSymbol => |sym| {
                const persistentKey = try allocator.dupe(u8, sym);
                try stack.append(LispVal{ .Symbol = persistentKey });
                current_frame.pc += 1;
            },
            // Set a property in an object
            .CallObjSet => {
                if (stack.items.len < 3) return VMError.StackUnderflow;
                const value_val = stack.pop();
                const key_val = stack.pop();
                const obj_val = stack.pop();
                if (@as(std.meta.Tag(LispVal), obj_val) != .Object) return VMError.NotAnObject;
                if (@as(std.meta.Tag(LispVal), key_val) != .Symbol) return VMError.InvalidKey;
                const obj_ptr = obj_val.Object;
                const key_str = key_val.Symbol;
                try obj_ptr.table.put(key_str, value_val);
                try stack.append(LispVal{ .Object = obj_ptr });
                current_frame.pc += 1;
            },
            // Merge two objects
            .CallObjMerge => {
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
                try stack.append(LispVal{ .Object = dst_ptr });
                current_frame.pc += 1;
            },
        }
    }

    // Should not reach here if code is well-formed
    return VMError.InvalidResult;
}
