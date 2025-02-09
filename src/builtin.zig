const lisp = @import("value.zig");
const std = @import("std");
const vm = @import("vm.zig");

const LispVal = lisp.LispVal;
const NativeFunc = lisp.NativeFunc;
const Cons = lisp.Cons;

pub fn builtin_cons(args: []LispVal, allocator: std.mem.Allocator) anyerror!LispVal {
    if (args.len != 2) return vm.VMError.ArgumentCountMismatch;
    const consCell = try allocator.create(Cons);
    consCell.* = Cons{
        .car = args[0],
        .cdr = args[1],
    };
    const x = LispVal{ .Cons = consCell };
    return x;
}

/// car: (car lst)
pub fn builtin_car(args: []LispVal, _: std.mem.Allocator) anyerror!LispVal {
    if (args.len != 1) return vm.VMError.ArgumentCountMismatch;
    const cell = args[0];
    if (@as(std.meta.Tag(LispVal), cell) != .Cons) return vm.VMError.NotACons;
    return cell.Cons.car;
}

/// cdr: (cdr lst)
pub fn builtin_cdr(args: []LispVal, _: std.mem.Allocator) anyerror!LispVal {
    if (args.len != 1) return vm.VMError.ArgumentCountMismatch;
    const cell = args[0];
    if (@as(std.meta.Tag(LispVal), cell) != .Cons) return vm.VMError.NotACons;
    return cell.Cons.cdr;
}

/// list: (list a1 a2 ... an)
/// Constructs a list from the arguments. One common approach is to fold the arguments
/// into a chain of cons cells ending with nil.
pub fn builtin_list(args: []LispVal, allocator: std.mem.Allocator) anyerror!LispVal {
    var result = LispVal{ .Nil = {} };

    // Build from right to left
    var i: usize = args.len;
    while (i > 0) {
        i -= 1;

        // Create temporary array for cons arguments
        var cons_args = [_]LispVal{ args[i], result };

        // Create new cons cell
        result = try builtin_cons(cons_args[0..], allocator);
    }
    return result;
}

pub fn builtin_isnil(args: []LispVal, _: std.mem.Allocator) anyerror!LispVal {
    const result: u32 = switch (args[0]) {
        .Nil => 1,
        else => 0,
    };
    return LispVal{ .Number = result };
}

pub fn builtin_lt(args: []LispVal, _: std.mem.Allocator) anyerror!LispVal {
    if (args.len != 2) return vm.VMError.ArgumentCountMismatch;
    // Assume both arguments are numbers:
    if (@as(std.meta.Tag(LispVal), args[0]) != .Number or
        @as(std.meta.Tag(LispVal), args[1]) != .Number)
    {
        return vm.VMError.NotANumber;
    }
    const result: u32 = if (args[0].Number < args[1].Number) 1 else 0;
    return LispVal{ .Number = result };
}

pub fn wrapNative(comptime func: fn ([]LispVal, std.mem.Allocator) anyerror!LispVal) NativeFunc {
    return struct {
        fn wrapped(args_ptr: *anyopaque, len: usize, allocator: std.mem.Allocator) anyerror!*anyopaque {
            const args_array = @as([*]LispVal, @ptrCast(@alignCast(args_ptr)));
            const args = args_array[0..len];

            // Allocate space for the result and store it
            const result_ptr = try allocator.create(LispVal);
            result_ptr.* = try func(args, allocator);
            return @ptrCast(result_ptr);
        }
    }.wrapped;
}

pub fn init(globalEnv: *lisp.Env) !void {
    try globalEnv.put("cons", LispVal{ .Native = @as(lisp.NativeFunc, wrapNative(builtin_cons)) });
    try globalEnv.put("car", LispVal{ .Native = @as(lisp.NativeFunc, wrapNative(builtin_car)) });
    try globalEnv.put("cdr", LispVal{ .Native = @as(lisp.NativeFunc, wrapNative(builtin_cdr)) });
    try globalEnv.put("list", LispVal{ .Native = @as(lisp.NativeFunc, wrapNative(builtin_list)) });
    try globalEnv.put("nil?", LispVal{ .Native = @as(lisp.NativeFunc, wrapNative(builtin_isnil)) });
    try globalEnv.put("<", LispVal{ .Native = @as(lisp.NativeFunc, wrapNative(builtin_lt)) });
    try globalEnv.put("nil", LispVal.Nil);
}
