const lisp = @import("value.zig");
const std = @import("std");
const vm = @import("vm.zig");
const gc_mod = @import("gc.zig");

const LispVal = lisp.LispVal;
const NativeFunc = lisp.NativeFunc;
const Cons = lisp.Cons;

pub const ConsArgs = struct {
    args: []LispVal,
    allocator: std.mem.Allocator,
    gc: *gc_mod.GarbageCollector,
};

pub fn builtin_cons(args_struct: ConsArgs) anyerror!LispVal {
    const args = args_struct.args;
    const gc = args_struct.gc;

    if (args.len != 2) return vm.VMError.ArgumentCountMismatch;
    
    const consCell = try gc.createCons(args[0], args[1]);
    return LispVal{ .Cons = consCell };
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
pub fn builtin_list(list_args: ConsArgs) anyerror!LispVal {
    const args = list_args.args;
    const gc = list_args.gc;
    
    var result = LispVal{ .Nil = {} };

    // Build from right to left
    var i: usize = args.len;
    while (i > 0) {
        i -= 1;

        // Create temporary array for cons arguments
        var cons_args = [_]LispVal{ args[i], result };

        // Create new cons cell
        result = try builtin_cons(ConsArgs{
            .args = cons_args[0..],
            .allocator = list_args.allocator,
            .gc = gc,
        });
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

pub fn builtin_concat(concat_args: ConsArgs) anyerror!LispVal {
    // Check that exactly two arguments were provided.
    const args = concat_args.args;
    const allocator = concat_args.allocator;
    const gc = concat_args.gc;
    
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
        // We'll use std.mem.join with an empty separator.
        var parts = [_][]const u8{ str_a, str_b };
        const new_str = try gc.createString(try std.mem.join(allocator, "", &parts));
        return LispVal{ .String = new_str };
    }
    // Determine if both are cons-based lists.
    else if (@as(std.meta.Tag(LispVal), a) == .Cons and
        @as(std.meta.Tag(LispVal), b) == .Cons)
    {
        return try concatCons(a.Cons, b.Cons, gc);
    } else {
        return vm.VMError.NotANumber; // Or define a more descriptive type-mismatch error.
    }
}

/// Helper function to concatenate two cons-based lists.
/// It clones the first list (so as not to mutate it) and then sets the tail of the
/// clone to point to the second list.
fn concatCons(a: *Cons, b: *Cons, gc: *gc_mod.GarbageCollector) anyerror!LispVal {
    // We'll build a new copy of the first list.
    var head: ?*Cons = null;
    var tail: ?*Cons = null;
    var current = a;
    while (true) {
        // Allocate a new cons cell through the GC
        const newCell = try gc.createCons(
            current.car,
            LispVal{ .Nil = {} }
        );
        
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
        } else if (second == .Symbol) {
            return first.Object.table.get(second.Symbol) orelse LispVal.Nil;
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

pub fn builtin_vector(vector_args: ConsArgs) anyerror!LispVal {
    const args = vector_args.args;
    const gc = vector_args.gc;
    
    if (args.len == 0) return LispVal.Nil;
    
    const first = args[0];

    switch (first) {
        .Cons => {
            return LispVal.Nil;
        },
        .Number => {
            // otherwise we have a list of numbers maybe
            var f = try gc.createVector(args.len);
            @memset(f, 0);
            for (args, 0..args.len) |item, i| {
                switch (item) {
                    .Number => |x| {
                        f[i] = @floatCast(x);
                    },
                    else => {
                        return vm.VMError.TypeMismatch;
                    },
                }
            }
            return LispVal{ .Vector = f };
        },
        else => {
            return LispVal.Nil;
        },
    }
}

pub fn builtin_reduce(args: []LispVal, _: std.mem.Allocator) anyerror!LispVal {
    switch (args[0]) {
        .Symbol => |op| {
            switch (args[1]) {
                .Vector => |v| {
                    if (v.len == 0) return vm.VMError.TypeMismatch;

                    const Vector = @Vector(4, f32);
                    var result: f32 = undefined;

                    if (op[0] == '+') {
                        if (v.len >= 4) {
                            const first_chunk: Vector = @as(*const [4]f32, @ptrCast(v.ptr)).*;
                            result = @reduce(.Add, first_chunk);
                            var i: usize = 4;

                            while (i + 4 <= v.len) : (i += 4) {
                                const chunk: Vector = @as(*const [4]f32, @ptrCast(v.ptr + i)).*;
                                result += @reduce(.Add, chunk);
                            }

                            while (i < v.len) : (i += 1) {
                                result += v[i];
                            }
                        } else {
                            result = v[0];
                            for (v[1..]) |val| {
                                result += val;
                            }
                        }
                    } else if (op[0] == '*') {
                        if (v.len >= 4) {
                            const first_chunk: Vector = @as(*const [4]f32, @ptrCast(v.ptr)).*;
                            result = @reduce(.Mul, first_chunk);
                            var i: usize = 4;

                            while (i + 4 <= v.len) : (i += 4) {
                                const chunk: Vector = @as(*const [4]f32, @ptrCast(v.ptr + i)).*;
                                result *= @reduce(.Mul, chunk);
                            }

                            while (i < v.len) : (i += 1) {
                                result *= v[i];
                            }
                        } else {
                            result = v[0];
                            for (v[1..]) |val| {
                                result *= val;
                            }
                        }
                    } else if (std.mem.eql(u8, op, "min")) {
                        if (v.len >= 4) {
                            const first_chunk: Vector = @as(*const [4]f32, @ptrCast(v.ptr)).*;
                            result = @reduce(.Min, first_chunk);
                            var i: usize = 4;

                            while (i + 4 <= v.len) : (i += 4) {
                                const chunk: Vector = @as(*const [4]f32, @ptrCast(v.ptr + i)).*;
                                result = @min(result, @reduce(.Min, chunk));
                            }

                            while (i < v.len) : (i += 1) {
                                result = @min(result, v[i]);
                            }
                        } else {
                            result = v[0];
                            for (v[1..]) |val| {
                                result = @min(result, val);
                            }
                        }
                    } else if (std.mem.eql(u8, op, "max")) {
                        if (v.len >= 4) {
                            const first_chunk: Vector = @as(*const [4]f32, @ptrCast(v.ptr)).*;
                            result = @reduce(.Max, first_chunk);
                            var i: usize = 4;

                            while (i + 4 <= v.len) : (i += 4) {
                                const chunk: Vector = @as(*const [4]f32, @ptrCast(v.ptr + i)).*;
                                result = @max(result, @reduce(.Min, chunk));
                            }

                            while (i < v.len) : (i += 1) {
                                result = @max(result, v[i]);
                            }
                        } else {
                            result = v[0];
                            for (v[1..]) |val| {
                                result = @max(result, val);
                            }
                        }
                    } else {
                        return vm.VMError.NotAFunction;
                    }

                    return LispVal{ .Number = result };
                },
                else => {
                    return vm.VMError.TypeMismatch;
                },
            }
        },
        else => {
            return vm.VMError.TypeMismatch;
        },
    }
}

pub fn builtin_stride(stride_args: ConsArgs) anyerror!LispVal {
    // Check arguments: (stride vector stride_size offset)
    const args = stride_args.args;
    const gc = stride_args.gc;
    
    if (args.len != 3) return vm.VMError.ArgumentCountMismatch;

    switch (args[0]) {
        .Vector => |input| {
            switch (args[1]) {
                .Number => |stride_size| {
                    switch (args[2]) {
                        .Number => |offset_size| {
                            const stride = @as(usize, @intFromFloat(stride_size));
                            const offset = @as(usize, @intFromFloat(offset_size));

                            if (stride <= 0) return vm.VMError.TypeMismatch;
                            if (offset >= input.len) return vm.VMError.TypeMismatch;
                            if (stride > input.len) return vm.VMError.TypeMismatch;

                            // Calculate size of output vector
                            const out_len = (input.len - offset + stride - 1) / stride;
                            var result = try gc.createVector(out_len);

                            // Fill the output vector
                            var out_idx: usize = 0;
                            var in_idx: usize = offset;
                            while (in_idx < input.len) : ({
                                in_idx += stride;
                                out_idx += 1;
                            }) {
                                result[out_idx] = input[in_idx];
                            }

                            return LispVal{ .Vector = result };
                        },
                        else => return vm.VMError.TypeMismatch,
                    }
                },
                else => return vm.VMError.TypeMismatch,
            }
        },
        else => return vm.VMError.TypeMismatch,
    }
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

// For storing GC pointers - keep this alive for the duration of the program
var global_gc_storage: ?gc_mod.GarbageCollector = null;
var global_gc: ?*gc_mod.GarbageCollector = null;

fn setGlobalGC(gc: *gc_mod.GarbageCollector) void {
    // Make a copy to ensure it lives for the duration of the program
    if (global_gc_storage == null) {
        global_gc_storage = gc_mod.GarbageCollector.init(gc.allocator);
        global_gc = &global_gc_storage.?;
    }
    // Just use the passed GC directly - safer if we keep the original reference
    global_gc = gc;
}

// Workaround for GC-enabled native functions
fn wrapConsWithGC() NativeFunc {
    return struct {
        fn wrapped(args_ptr: *anyopaque, len: usize, allocator: std.mem.Allocator) anyerror!*anyopaque {
            const args_array = @as([*]LispVal, @ptrCast(@alignCast(args_ptr)));
            const args = args_array[0..len];
            
            // Check if GC is initialized
            if (global_gc == null) {
                return error.GCNotInitialized;
            }

            // Create args struct with GC
            const args_struct = ConsArgs{
                .args = args,
                .allocator = allocator,
                .gc = global_gc.?,
            };
            
            // Call the function
            const result = try builtin_cons(args_struct);
            
            // Allocate space for the result and store it
            const result_ptr = try allocator.create(LispVal);
            result_ptr.* = result;
            return @ptrCast(result_ptr);
        }
    }.wrapped;
}

fn wrapListWithGC() NativeFunc {
    return struct {
        fn wrapped(args_ptr: *anyopaque, len: usize, allocator: std.mem.Allocator) anyerror!*anyopaque {
            const args_array = @as([*]LispVal, @ptrCast(@alignCast(args_ptr)));
            const args = args_array[0..len];
            
            // Check if GC is initialized
            if (global_gc == null) {
                return error.GCNotInitialized;
            }

            // Create args struct with GC
            const args_struct = ConsArgs{
                .args = args,
                .allocator = allocator,
                .gc = global_gc.?,
            };
            
            // Call the function
            const result = try builtin_list(args_struct);
            
            // Allocate space for the result and store it
            const result_ptr = try allocator.create(LispVal);
            result_ptr.* = result;
            return @ptrCast(result_ptr);
        }
    }.wrapped;
}

fn wrapConcatWithGC() NativeFunc {
    return struct {
        fn wrapped(args_ptr: *anyopaque, len: usize, allocator: std.mem.Allocator) anyerror!*anyopaque {
            const args_array = @as([*]LispVal, @ptrCast(@alignCast(args_ptr)));
            const args = args_array[0..len];
            
            // Check if GC is initialized
            if (global_gc == null) {
                return error.GCNotInitialized;
            }

            // Create args struct with GC
            const args_struct = ConsArgs{
                .args = args,
                .allocator = allocator,
                .gc = global_gc.?,
            };
            
            // Call the function
            const result = try builtin_concat(args_struct);
            
            // Allocate space for the result and store it
            const result_ptr = try allocator.create(LispVal);
            result_ptr.* = result;
            return @ptrCast(result_ptr);
        }
    }.wrapped;
}

fn wrapVectorWithGC() NativeFunc {
    return struct {
        fn wrapped(args_ptr: *anyopaque, len: usize, allocator: std.mem.Allocator) anyerror!*anyopaque {
            const args_array = @as([*]LispVal, @ptrCast(@alignCast(args_ptr)));
            const args = args_array[0..len];
            
            // Check if GC is initialized
            if (global_gc == null) {
                return error.GCNotInitialized;
            }

            // Create args struct with GC
            const args_struct = ConsArgs{
                .args = args,
                .allocator = allocator,
                .gc = global_gc.?,
            };
            
            // Call the function
            const result = try builtin_vector(args_struct);
            
            // Allocate space for the result and store it
            const result_ptr = try allocator.create(LispVal);
            result_ptr.* = result;
            return @ptrCast(result_ptr);
        }
    }.wrapped;
}

fn wrapStrideWithGC() NativeFunc {
    return struct {
        fn wrapped(args_ptr: *anyopaque, len: usize, allocator: std.mem.Allocator) anyerror!*anyopaque {
            const args_array = @as([*]LispVal, @ptrCast(@alignCast(args_ptr)));
            const args = args_array[0..len];
            
            // Check if GC is initialized
            if (global_gc == null) {
                return error.GCNotInitialized;
            }

            // Create args struct with GC
            const args_struct = ConsArgs{
                .args = args,
                .allocator = allocator,
                .gc = global_gc.?,
            };
            
            // Call the function
            const result = try builtin_stride(args_struct);
            
            // Allocate space for the result and store it
            const result_ptr = try allocator.create(LispVal);
            result_ptr.* = result;
            return @ptrCast(result_ptr);
        }
    }.wrapped;
}

pub fn init(globalEnv: *lisp.Env, gc: *gc_mod.GarbageCollector) !void {
    // Store GC pointer globally
    setGlobalGC(gc);
    
    // Functions that need GC access
    try globalEnv.put("cons", LispVal{ .Native = wrapConsWithGC() });
    try globalEnv.put("list", LispVal{ .Native = wrapListWithGC() });
    try globalEnv.put("concat", LispVal{ .Native = wrapConcatWithGC() });
    try globalEnv.put("#", LispVal{ .Native = wrapVectorWithGC() });
    
    // Functions that don't need GC access
    try globalEnv.put("car", LispVal{ .Native = @as(lisp.NativeFunc, wrapNative(builtin_car)) });
    try globalEnv.put("cdr", LispVal{ .Native = @as(lisp.NativeFunc, wrapNative(builtin_cdr)) });
    try globalEnv.put("nil?", LispVal{ .Native = @as(lisp.NativeFunc, wrapNative(builtin_isnil)) });
    try globalEnv.put("<", LispVal{ .Native = @as(lisp.NativeFunc, wrapNative(builtin_lt)) });
    try globalEnv.put("==", LispVal{ .Native = @as(lisp.NativeFunc, wrapNative(builtin_eq)) });
    try globalEnv.put("@reduce", LispVal{ .Native = @as(lisp.NativeFunc, wrapNative(builtin_reduce)) });
    try globalEnv.put("@stride", LispVal{ .Native = wrapStrideWithGC() });
    try globalEnv.put("len", LispVal{ .Native = @as(lisp.NativeFunc, wrapNative(builtin_len)) });
    try globalEnv.put("nil", LispVal.Nil);
    try globalEnv.put("get", LispVal{ .Native = @as(lisp.NativeFunc, wrapNative(builtin_get)) });
}
