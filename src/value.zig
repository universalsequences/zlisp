const std = @import("std");
const vm = @import("vm.zig");
const builtin = @import("builtin.zig");

/// Forward-declare Env so we can reference it.
pub const Env = struct {
    parent: ?*Env,
    vars: std.StringHashMap(LispVal),
    allocator: std.mem.Allocator,
    id: i32,

    pub fn init(allocator: std.mem.Allocator, parent: ?*Env) Env {
        return Env{ .parent = parent, .vars = std.StringHashMap(LispVal).init(allocator), .allocator = allocator, .id = if (parent) |p| p.id else 1 };
    }

    pub fn deinit(self: *Env) void {
        self.vars.deinit();
    }

    /// Look up a variable by key in the chain of environments.
    /// The chaining gives us closures
    pub fn get(self: Env, key: []const u8) ?LispVal {
        if (self.vars.get(key)) |value| {
            return value;
        }
        if (self.parent) |p| {
            return p.get(key);
        }
        return null;
    }

    /// Insert or update a variable in this environment.
    pub fn put(self: *Env, key: []const u8, value: LispVal) !void {
        try self.vars.put(key, value);
    }
};

pub const FunctionDef = struct {
    pattern: LispVal, // The pattern to match (e.g., Number(1) or Symbol("n"))
    code: []vm.Instruction, // Instructions to execute if the pattern matches
};

pub const FnValue = struct {
    defs: std.ArrayList(FunctionDef),
    params: ?[]const []const u8, // Parameter names for lambdas (null for named functions)
    code: ?[]vm.Instruction, // Single code block for lambdas (null for named functions)
    env: *Env, // The environment captured by the function
};

pub const Cons = struct {
    car: LispVal,
    cdr: LispVal,
};

pub const NativeFunc = *const fn (*anyopaque, len: usize, allocator: std.mem.Allocator) anyerror!*anyopaque;

pub const ObjectEntry = union(enum) {
    // A normal key-value pair.
    Pair: struct {
        key: []const u8,
        value: LispVal,
    },
    // A spread entry; the expression following "..." will be merged.
    Spread: LispVal,
};

pub const RuntimeObject = struct {
    table: std.StringHashMap(LispVal),
};

pub const LispVal = union(enum) {
    Number: f64,
    Symbol: []const u8,
    List: []LispVal,
    Function: *FnValue,
    FunctionDef: *FunctionDef,
    Cons: *Cons,
    Native: NativeFunc,
    Quote: *LispVal,
    Nil,
    String: []const u8,
    ObjectLiteral: []ObjectEntry,
    Object: *RuntimeObject,
    Vector: []f32,

    pub fn toString(self: LispVal, allocator: std.mem.Allocator) anyerror![]const u8 {
        return switch (self) {
            .Number => |n| {
                return try std.fmt.allocPrint(allocator, "{d}", .{n});
            },
            .String => |s| {
                return try std.fmt.allocPrint(allocator, "\"{!s}\"", .{s});
            },
            .FunctionDef => {
                return "";
            },
            .Symbol => |s| {
                return try std.fmt.allocPrint(allocator, "{!s}", .{s});
            },
            .Vector => |lst| {
                var parts = std.ArrayList([]const u8).init(allocator);
                defer parts.deinit();
                for (lst) |item| {
                    const part = try std.fmt.allocPrint(allocator, "{d}", .{item});
                    try parts.append(part);
                }
                const joined = try std.mem.join(allocator, " ", parts.items);
                return try std.fmt.allocPrint(allocator, "(vector {s})", .{joined});
            },
            .Quote => |quote| {
                return try std.fmt.allocPrint(allocator, "{!s}", .{quote.toString(allocator)});
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
            .Object => |objPtr| {
                var parts = std.ArrayList([]const u8).init(allocator);
                defer parts.deinit();
                defer {
                    // Free all the allocated strings we stored
                    for (parts.items) |part| {
                        allocator.free(part);
                    }
                }

                var iter = objPtr.table.iterator();
                while (iter.next()) |entry| {
                    const keyStr = entry.key_ptr.*;
                    const valStr = try entry.value_ptr.*.toString(allocator);
                    defer allocator.free(valStr);

                    const part = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ keyStr, valStr });
                    try parts.append(part);
                }

                const joined = try std.mem.join(allocator, ", ", parts.items);
                defer allocator.free(joined);

                return std.fmt.allocPrint(allocator, "{{{s}}}", .{joined});
            },
            .ObjectLiteral => |entries| {
                // For simplicity, print as {key1: val1, key2: val2, ...}
                var parts = std.ArrayList([]const u8).init(allocator);
                defer parts.deinit();
                for (entries) |entry| {
                    const part = switch (entry) {
                        .Pair => |pair| {
                            const keyStr = pair.key;
                            const valStr = try pair.value.toString(allocator);
                            return try std.fmt.allocPrint(allocator, "{s}: {s}", .{ keyStr, valStr });
                        },
                        .Spread => |spreadExpr| {
                            return try std.fmt.allocPrint(allocator, "...{s}", .{try spreadExpr.toString(allocator)});
                        },
                    };
                    try parts.append(part);
                }
                const joined = try std.mem.join(allocator, ", ", parts.items);
                return std.fmt.allocPrint(allocator, "< {s} >", .{joined});
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
