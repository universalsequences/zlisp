const std = @import("std");
const lisp = @import("value.zig");
const vm = @import("vm.zig");

const Instruction = vm.Instruction;
const LispVal = lisp.LispVal;
const Env = lisp.Env;
const FnValue = lisp.FnValue;
const FunctionDef = lisp.FunctionDef;

////  Compiler
pub const CompileError = error{
    InvalidExpression,
    InvalidOperator,
    UnsupportedExpression,
};

pub fn compileObject(expr: LispVal, instructions: *std.ArrayList(vm.Instruction), allocator: std.mem.Allocator, currentEnv: *Env) anyerror!void {
    // We assume that 'expr' is a LispVal with tag Object.
    // First, push an empty object onto the stack.
    try instructions.append(vm.Instruction.PushEmptyObject);

    // Retrieve the slice of object entries.
    const entries = expr.ObjectLiteral;
    // Iterate over each object entry.
    for (entries) |entry| {
        switch (entry) {
            .Pair => |pair| {
                // For a key-value pair, first push the key as a constant symbol.
                try instructions.append(vm.Instruction{ .PushConstSymbol = pair.key });
                // Then compile the value expression.
                try compileExpr(pair.value, instructions, allocator, currentEnv);
                // Now update the object by calling the object-set operation.
                // We use CallObjSet with an argument count of 2 (the key and value).
                try instructions.append(vm.Instruction{ .CallObjSet = 2 });
            },
            .Spread => |spreadExpr| {
                // For a spread entry, compile the spread expression.
                try compileExpr(spreadExpr, instructions, allocator, currentEnv);
                // Then merge it into the current object.
                try instructions.append(vm.Instruction{ .CallObjMerge = 1 });
            },
        }
    }
}

pub fn compileExpr(expr: LispVal, instructions: *std.ArrayList(Instruction), allocator: std.mem.Allocator, currentEnv: *Env) anyerror!void {
    switch (expr) {
        .Number => |n| {
            // For a number, push it onto the stack.
            try instructions.append(Instruction{ .PushConst = n });
        },
        // A bare symbol is assumed to be a variable reference.
        .Symbol => {
            // For variable references, we compile a LoadVar instruction.
            // Duplicate the string so that it is persistent.
            const persistentName = try allocator.dupe(u8, expr.Symbol);
            try instructions.append(Instruction{ .LoadVar = persistentName });
        },
        .String => |n| {
            // For a number, push it onto the stack.
            try instructions.append(Instruction{ .PushConstString = n });
        },
        .Vector => {},
        .Quote => |quote| {
            try instructions.append(Instruction{ .PushQuote = quote.* });
        },
        .Function => {},
        .FunctionDef => {},
        .Native => {},
        .Object => {},
        .ObjectLiteral => {
            try compileObject(expr, instructions, allocator, currentEnv);
        },
        .Cons => {},
        .Nil => {},
        .List => {
            // For simple math, expect at least one operator and one operand.
            if (expr.List.len < 2) {
                return CompileError.InvalidExpression;
            }
            // The first element should be a symbol (the operator).
            const op = expr.List[0];
            switch (op) {
                .Symbol => {
                    // Compile all operands first (left-to-right).
                    // Now add the operator instruction.
                    const opStr = op.Symbol;
                    if (std.mem.eql(u8, opStr, "set")) {
                        // (set x expr) or (define x expr)
                        if (expr.List.len != 3) return CompileError.InvalidExpression;
                        const varExpr = expr.List[1];
                        switch (varExpr) {
                            .Symbol => {
                                const varName = varExpr.Symbol;
                                // Compile the expression whose value will be assigned.
                                const varNamePersistent = try allocator.dupe(u8, varName);
                                try compileExpr(expr.List[2], instructions, allocator, currentEnv);

                                // Duplicate the top stack element so that the stack has it's value after the store
                                try instructions.append(Instruction.Dup);
                                // Emit a StoreVar instruction to save the value.
                                try instructions.append(Instruction{ .StoreVar = varNamePersistent });
                            },
                            else => return CompileError.InvalidOperator,
                        }
                    } else if (std.mem.eql(u8, opStr, "defun")) {
                        const nameVal = expr.List[1];
                        if (@as(std.meta.Tag(LispVal), nameVal) != .Symbol) return error.InvalidFunctionDefinition;
                        const fnName = try allocator.dupe(u8, nameVal.Symbol);

                        // Extract the pattern list from paramsExpr
                        const patternExpr = expr.List[2];
                        if (@as(std.meta.Tag(LispVal), patternExpr) != .List) return error.InvalidPattern;
                        const patterns = patternExpr.List; // e.g., [Symbol("a"), Symbol("b")] or [Symbol("n")]

                        // Compile the body into instructions
                        const bodyExpr = expr.List[3];
                        var funcInstructions = std.ArrayList(Instruction).init(allocator);
                        defer funcInstructions.deinit();
                        try compileExpr(bodyExpr, &funcInstructions, allocator, currentEnv);
                        try funcInstructions.append(Instruction.Return);

                        // Create a FunctionDef with the list of patterns and compiled code
                        const funcDefPtr = try allocator.create(FunctionDef);
                        funcDefPtr.* = FunctionDef{
                            .patterns = patterns,
                            .code = try funcInstructions.toOwnedSlice(),
                        };

                        // Generate instructions to push the FunctionDef and define it
                        try instructions.append(Instruction{ .PushFuncDef = funcDefPtr });
                        try instructions.append(Instruction{ .DefineFuncDef = fnName });
                        return;
                    } else if (std.mem.eql(u8, opStr, "lambda")) {
                        // Extract the parameter list (e.g., (x y))
                        const paramsExpr = expr.List[1];
                        if (@as(std.meta.Tag(LispVal), paramsExpr) != .List) return error.InvalidLambda;
                        const paramsList = paramsExpr.List;

                        // Collect parameter names
                        var paramNames = try allocator.alloc([]const u8, paramsList.len);
                        for (paramsList, 0..) |param, i| {
                            if (@as(std.meta.Tag(LispVal), param) != .Symbol) return error.InvalidLambda;
                            paramNames[i] = try allocator.dupe(u8, param.Symbol);
                        }

                        // Compile the body (e.g., (+ x y))
                        const bodyExpr = expr.List[2];
                        var funcInstructions = std.ArrayList(Instruction).init(allocator);
                        defer funcInstructions.deinit();
                        try compileExpr(bodyExpr, &funcInstructions, allocator, currentEnv);
                        try funcInstructions.append(Instruction.Return);

                        // Create the lambda function value
                        const fnPtr = try allocator.create(FnValue);
                        fnPtr.* = FnValue{
                            .defs = std.ArrayList(FunctionDef).init(allocator),
                            .params = paramNames, // List of parameters (e.g., ["x", "y"])
                            .code = try funcInstructions.toOwnedSlice(), // Single compiled body
                            .env = currentEnv, // Captured environment
                        };

                        try instructions.append(Instruction{ .PushFunc = fnPtr });
                    } else if (std.mem.eql(u8, opStr, "let")) {
                        const bindings = expr.List[1];
                        if (@as(std.meta.Tag(LispVal), bindings) != .List) {
                            return CompileError.InvalidExpression;
                        }
                        var i: usize = 0;

                        try instructions.append(Instruction.EnterScope);

                        while (i < bindings.List.len) : (i += 1) {
                            // each element in let variable clause must a list
                            const elem = bindings.List[i];
                            if (@as(std.meta.Tag(LispVal), elem) != .List) {
                                return CompileError.InvalidExpression;
                            }
                            try compileExpr(elem.List[1], instructions, allocator, currentEnv);
                            try instructions.append(Instruction{ .StoreVar = elem.List[0].Symbol });
                        }
                        try compileExpr(expr.List[2], instructions, allocator, currentEnv);
                        try instructions.append(Instruction.ExitScope);
                    } else if (std.mem.eql(u8, opStr, "if")) {
                        // Compile the condition.
                        // (if condition then else)
                        try compileExpr(expr.List[1], instructions, allocator, currentEnv);

                        // Insert JumpIfFalse with a placeholder offset.
                        const jumpIfFalsePos: u32 = @intCast(instructions.items.len);
                        try instructions.append(Instruction{ .JumpIfFalse = 0 });

                        // Compile the then branch.
                        try compileExpr(expr.List[2], instructions, allocator, currentEnv);

                        // Insert an unconditional Jump to skip the else branch.
                        const jumpPos: u32 = @intCast(instructions.items.len);
                        try instructions.append(Instruction{ .Jump = 0 });

                        // Backpatch the JumpIfFalse to jump to the start of the else branch.
                        const elseStart: u32 = @intCast(instructions.items.len);
                        // The offset is relative to the JumpIfFalse instruction.
                        instructions.items[jumpIfFalsePos] = Instruction{ .JumpIfFalse = elseStart - jumpIfFalsePos };

                        // If an else branch is provided, compile it; otherwise, compile a literal nil.
                        if (expr.List.len >= 4) {
                            try compileExpr(expr.List[3], instructions, allocator, currentEnv);
                        } else {
                            // If no else is provided, you could compile a literal nil.
                            try instructions.append(Instruction{ .PushConst = 0 }); // Or a dedicated nil instruction/variant.
                        }

                        // Backpatch the unconditional Jump to jump to the end.
                        const afterElse: u32 = @intCast(instructions.items.len);
                        instructions.items[jumpPos] = Instruction{ .Jump = afterElse - jumpPos };
                        return;
                    } else {
                        // go through defined operations
                        if (std.mem.eql(u8, opStr, "+")) {
                            var i: usize = 1;
                            while (i < expr.List.len) : (i += 1) {
                                try compileExpr(expr.List[i], instructions, allocator, currentEnv);
                            }
                            try instructions.append(Instruction{ .Add = expr.List.len - 1 });
                        } else if (std.mem.eql(u8, opStr, "-")) {
                            var i: usize = 1;
                            while (i < expr.List.len) : (i += 1) {
                                try compileExpr(expr.List[i], instructions, allocator, currentEnv);
                            }
                            try instructions.append(Instruction{ .Sub = expr.List.len - 1 });
                        } else if (std.mem.eql(u8, opStr, "*")) {
                            var i: usize = 1;
                            while (i < expr.List.len) : (i += 1) {
                                try compileExpr(expr.List[i], instructions, allocator, currentEnv);
                            }
                            try instructions.append(Instruction{ .Mul = expr.List.len - 1 });
                        } else if (std.mem.eql(u8, opStr, "/")) {
                            var i: usize = 1;
                            while (i < expr.List.len) : (i += 1) {
                                try compileExpr(expr.List[i], instructions, allocator, currentEnv);
                            }
                            try instructions.append(Instruction{ .Div = expr.List.len - 1 });
                        } else {
                            // otherwise we handle function calls, with the Instruction.Call bytecode
                            // First, compile the function expression (i.e. LoadVar the symbol)
                            try compileExpr(expr.List[0], instructions, allocator, currentEnv);

                            // Then compile each argument.
                            for (expr.List[1..]) |arg| {
                                try compileExpr(arg, instructions, allocator, currentEnv);
                            }

                            // Finally, append the Call instruction with the argument count.
                            const argCount: u32 = @intCast(expr.List.len - 1);
                            std.log.debug("appending call\n", .{});
                            try instructions.append(Instruction{ .Call = argCount });
                        }
                    }
                },
                .List => {
                    try compileExpr(expr.List[0], instructions, allocator, currentEnv);
                    // Then compile each argument.
                    for (expr.List[1..]) |arg| {
                        try compileExpr(arg, instructions, allocator, currentEnv);
                    }

                    std.log.debug(".List call push\n", .{});
                    // Finally, append the Call instruction with the argument count.
                    const argCount: u32 = @intCast(expr.List.len - 1);
                    try instructions.append(Instruction{ .Call = argCount });
                },
                else => return CompileError.InvalidOperator,
            }
        },
    }
}
