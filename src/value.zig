const std = @import("std");
const vm = @import("vm.zig");
const builtin = @import("builtin.zig");

/// Forward-declare Env so we can reference it.
pub const Env = struct {
    parent: ?*Env,
    vars: std.StringHashMap(LispVal),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, parent: ?*Env) Env {
        return Env{
            .parent = parent,
            .vars = std.StringHashMap(LispVal).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Env) void {
        self.vars.deinit();
    }

    /// Look up a variable by key in the chain of environments.
    pub fn get(self: Env, key: []const u8) ?LispVal {
        if (self.vars.get(key)) |value| return value;
        if (self.parent) |p| return p.get(key);
        return null;
    }

    /// Insert or update a variable in this environment.
    pub fn put(self: *Env, key: []const u8, value: LispVal) !void {
        try self.vars.put(key, value);
    }
};

/// A function value: parameters, body, and the closure environment.
pub const FnValue = struct {
    /// The parameter names (each a persistent string).
    params: []const []const u8,
    /// The body expression (or perhaps a list of expressions).
    code: []vm.Instruction,
    /// The closure: the environment where the function was defined.
    env: *Env,
};

pub const Cons = struct {
    car: LispVal,
    cdr: LispVal,
};

pub const NativeFunc = *const fn (*anyopaque, len: usize, allocator: std.mem.Allocator) anyerror!*anyopaque;

pub const LispVal = union(enum) {
    Number: f64,
    Symbol: []const u8,
    List: []LispVal,
    Function: *FnValue,
    Cons: *Cons,
    Native: NativeFunc,
    Nil,

    pub fn toString(self: LispVal, allocator: std.mem.Allocator) anyerror![]const u8 {
        return switch (self) {
            .Number => |n| {
                return try std.fmt.allocPrint(allocator, "{d}", .{n});
            },
            .Symbol => |s| {
                return try std.fmt.allocPrint(allocator, "{!s}", .{s});
            },
            .List => |lst| {
                var parts = std.ArrayList([]const u8).init(allocator);
                defer parts.deinit();
                for (lst) |item| {
                    const part = try item.toString(allocator);
                    try parts.append(part);
                }
                const joined = try std.mem.join(allocator, " ", parts.items);
                return try std.fmt.allocPrint(allocator, "({s})", .{joined});
            },
            .Native => {
                return "*native";
            },
            .Cons => |consPtr| {
                // Debug print to see the actual values
                //std.debug.print("Printing cons cell - car: {any}, cdr: {any}\n", .{ consPtr.car, consPtr.cdr });

                const carStr = try consPtr.car.toString(allocator);
                //defer allocator.free(carStr);

                const cdrStr = try consPtr.cdr.toString(allocator);
                //defer allocator.free(cdrStr);

                return try std.fmt.allocPrint(allocator, "({s} . {s})", .{ carStr, cdrStr });
            },
            .Nil => return "nil",
            .Function => {
                return "*function*";
            },
        };
    }
};
