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
    const result: f64 = switch (args[0]) {
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
    const result: f64 = if (args[0].Number < args[1].Number) 1 else 0;
    return LispVal{ .Number = result };
}

pub fn builtin_eq(args: []LispVal, _: std.mem.Allocator) anyerror!LispVal {
    if (args.len != 2) return vm.VMError.ArgumentCountMismatch;
    // Assume both arguments are numbers:
    if (@as(std.meta.Tag(LispVal), args[0]) != .Number or
        @as(std.meta.Tag(LispVal), args[1]) != .Number)
    {
        return vm.VMError.NotANumber;
    }
    const result: f64 = if (args[0].Number == args[1].Number) 1 else 0;
    return LispVal{ .Number = result };
}

pub fn builtin_concat(args: []LispVal, allocator: std.mem.Allocator) anyerror!LispVal {
    // Check that exactly two arguments were provided.
    if (args.len != 2) return vm.VMError.ArgumentCountMismatch;
    const a = args[0];
    const b = args[1];

    // Determine if both are strings.
    if (@as(std.meta.Tag(LispVal), a) == .String and
        @as(std.meta.Tag(LispVal), b) == .String)
    {
        const str_a = a.String;
        const str_b = b.String;
        // Concatenate the two string slices.
        // We'll use std.mem.concat with an empty separator.
        var parts = [_][]const u8{ str_a, str_b };
        const new_str = try std.mem.join(allocator, "", &parts);
        return LispVal{ .String = new_str };
    }
    // Determine if both are cons-based lists.
    else if (@as(std.meta.Tag(LispVal), a) == .Cons and
        @as(std.meta.Tag(LispVal), b) == .Cons)
    {
        return try concatCons(a.Cons, b.Cons, allocator);
    } else {
        return vm.VMError.NotANumber; // Or define a more descriptive type-mismatch error.
    }
}

/// Helper function to concatenate two cons-based lists.
/// It clones the first list (so as not to mutate it) and then sets the tail of the
/// clone to point to the second list.
fn concatCons(a: *Cons, b: *Cons, allocator: std.mem.Allocator) anyerror!LispVal {
    // We'll build a new copy of the first list.
    var head: ?*Cons = null;
    var tail: ?*Cons = null;
    var current = a;
    while (true) {
        // Allocate a new cons cell.
        const newCell = try allocator.create(Cons);
        newCell.* = Cons{
            .car = current.car,
            // We'll fill in cdr later.
            .cdr = LispVal{ .Nil = {} },
        };
        if (head == null) {
            head = newCell;
        } else {
            // Link the new cell to the previous cell.
            tail.?.cdr = LispVal{ .Cons = newCell };
        }
        tail = newCell;
        // Check if current.cdr is a cons cell; if not, we've reached the end.
        if (@as(std.meta.Tag(LispVal), current.cdr) == .Cons) {
            current = current.cdr.Cons;
        } else {
            break;
        }
    }
    // Link the tail of the cloned list to the second list.
    tail.?.cdr = LispVal{ .Cons = b };
    // Return the newly built list.
    return LispVal{ .Cons = head.? };
}

pub fn builtin_len(args: []LispVal, _: std.mem.Allocator) anyerror!LispVal {
    if (args.len != 1) return vm.VMError.ArgumentCountMismatch;
    const arg = args[0];
    const tag = @as(std.meta.Tag(LispVal), arg);

    if (tag == .String) {
        // For a string, the length is the number of code units (bytes).
        const len = arg.String.len;
        return LispVal{ .Number = @floatFromInt(len) };
    } else if (tag == .List) {
        // For a literal list, use the length of the slice.
        const len: u32 = @intCast(arg.List.len);
        return LispVal{ .Number = @floatFromInt(len) };
    } else if (tag == .Cons) {
        // For cons-based lists, traverse the linked list until you reach Nil
        var count: usize = 0;
        var cur: LispVal = arg;
        while (true) {
            const curTag = @as(std.meta.Tag(LispVal), cur);
            if (curTag == .Cons) {
                count += 1;
                cur = cur.Cons.cdr;
            } else if (curTag == .Nil) {
                break;
            } else {
                // If it's an improper list, we simply stop here.
                break;
            }
        }
        return LispVal{ .Number = @floatFromInt(count) };
    } else {
        return vm.VMError.TypeMismatch;
    }
}

pub fn builtin_get(args: []LispVal, _: std.mem.Allocator) anyerror!LispVal {
    const first = args[0];
    const second = args[1];

    // Handle Object case
    if (first == .Object) {
        if (second == .String) {
            return first.Object.table.get(second.String) orelse LispVal.Nil;
        }
        return LispVal.Nil;
    }

    // Handle Cons case
    if (first == .Cons) {
        if (second != .Number) return LispVal.Nil;

        const n = second.Number;
        if (n < 0) return LispVal.Nil;

        var current = first.Cons;
        const index = @as(usize, @intFromFloat(n));

        for (0..index) |_| {
            if (current.car == LispVal.Nil) return LispVal.Nil;
            if (current.cdr != .Cons) return LispVal.Nil;
            current = current.cdr.Cons;
        }
        return current.car;
    }

    return LispVal.Nil;
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
    try globalEnv.put("==", LispVal{ .Native = @as(lisp.NativeFunc, wrapNative(builtin_eq)) });
    try globalEnv.put("concat", LispVal{ .Native = @as(lisp.NativeFunc, wrapNative(builtin_concat)) });
    try globalEnv.put("len", LispVal{ .Native = @as(lisp.NativeFunc, wrapNative(builtin_len)) });
    try globalEnv.put("nil", LispVal.Nil);
    try globalEnv.put("get", LispVal{ .Native = @as(lisp.NativeFunc, wrapNative(builtin_get)) });
}
