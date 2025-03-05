const std = @import("std");
const lisp = @import("value.zig");
const vm = @import("vm.zig");

const LispVal = lisp.LispVal;
const Env = lisp.Env;
const Cons = lisp.Cons;
const FnValue = lisp.FnValue;
const RuntimeObject = lisp.RuntimeObject;

/// GarbageCollector manages heap-allocated Lisp values
pub const GarbageCollector = struct {
    // All allocated objects
    objects: std.ArrayList(*anyopaque),
    // Object type tracking
    object_types: std.ArrayList(ObjectType),
    // Mark bits for each object
    marks: std.ArrayList(bool),
    // Allocator for the GC itself
    allocator: std.mem.Allocator,
    // Collection trigger threshold (in number of objects)
    threshold: usize,
    // Is collection currently in progress?
    collecting: bool,

    pub fn init(allocator: std.mem.Allocator) GarbageCollector {
        return GarbageCollector{
            .objects = std.ArrayList(*anyopaque).init(allocator),
            .object_types = std.ArrayList(ObjectType).init(allocator),
            .marks = std.ArrayList(bool).init(allocator),
            .allocator = allocator,
            .threshold = 1000, // Default threshold
            .collecting = false,
        };
    }

    pub fn deinit(self: *GarbageCollector) void {
        // Final cleanup of all tracked objects
        self.freeAll();
        self.objects.deinit();
        self.object_types.deinit();
        self.marks.deinit();
    }

    fn freeAll(self: *GarbageCollector) void {
        for (self.objects.items, self.object_types.items) |obj, obj_type| {
            switch (obj_type) {
                .Cons => {
                    const cons = @as(*Cons, @ptrCast(@alignCast(obj)));
                    self.allocator.destroy(cons);
                },
                .FnValue => {
                    const fn_val = @as(*FnValue, @ptrCast(@alignCast(obj)));
                    fn_val.defs.deinit();
                    if (fn_val.params) |params| {
                        for (params) |param| {
                            self.allocator.free(param);
                        }
                        self.allocator.free(params);
                    }
                    if (fn_val.code) |code| {
                        self.allocator.free(code);
                    }
                    self.allocator.destroy(fn_val);
                },
                .Env => {
                    const env = @as(*Env, @ptrCast(@alignCast(obj)));
                    env.deinit();
                    self.allocator.destroy(env);
                },
                .RuntimeObject => {
                    const obj_ptr = @as(*RuntimeObject, @ptrCast(@alignCast(obj)));
                    obj_ptr.table.deinit();
                    self.allocator.destroy(obj_ptr);
                },
                .LispVal => {
                    const val = @as(*LispVal, @ptrCast(@alignCast(obj)));
                    self.allocator.destroy(val);
                },
                .List => {
                    const list = @as(*[]LispVal, @ptrCast(@alignCast(obj)));
                    self.allocator.free(list.*);
                    self.allocator.destroy(list);
                },
                .Vector => {
                    const vec = @as(*[]f32, @ptrCast(@alignCast(obj)));
                    self.allocator.free(vec.*);
                    self.allocator.destroy(vec);
                },
                .String => {
                    const str = @as(*[]const u8, @ptrCast(@alignCast(obj)));
                    self.allocator.free(str.*);
                    self.allocator.destroy(str);
                },
            }
        }
        self.objects.clearRetainingCapacity();
        self.object_types.clearRetainingCapacity();
        self.marks.clearRetainingCapacity();
    }

    const ObjectType = enum {
        Cons,
        FnValue,
        Env,
        RuntimeObject,
        LispVal,
        List,
        Vector,
        String,
    };

    // Allocate a Cons cell and track it for GC
    pub fn createCons(self: *GarbageCollector, car: LispVal, cdr: LispVal) !*Cons {
        try self.maybeCollect();

        const cons = try self.allocator.create(Cons);
        cons.* = Cons{
            .car = car,
            .cdr = cdr,
        };

        try self.trackObject(cons, .Cons);
        return cons;
    }

    // Allocate a FnValue and track it for GC
    pub fn createFunction(self: *GarbageCollector, env: *Env) !*FnValue {
        try self.maybeCollect();

        const fn_val = try self.allocator.create(FnValue);
        fn_val.* = FnValue{
            .defs = std.ArrayList(lisp.FunctionDef).init(self.allocator),
            .params = null,
            .code = null,
            .env = env,
        };

        try self.trackObject(fn_val, .FnValue);
        return fn_val;
    }

    // Allocate an Environment and track it for GC
    pub fn createEnv(self: *GarbageCollector, parent: ?*Env) !*Env {
        try self.maybeCollect();

        const env = try self.allocator.create(Env);
        env.* = Env.init(self.allocator, parent);

        try self.trackObject(env, .Env);
        return env;
    }

    // Allocate a RuntimeObject and track it for GC
    pub fn createObject(self: *GarbageCollector) !*RuntimeObject {
        try self.maybeCollect();

        const obj = try self.allocator.create(RuntimeObject);
        obj.* = RuntimeObject{
            .table = std.StringHashMap(LispVal).init(self.allocator),
        };

        try self.trackObject(obj, .RuntimeObject);
        return obj;
    }

    // Allocate a LispVal copy and track it for GC
    pub fn createLispVal(self: *GarbageCollector, val: LispVal) !*LispVal {
        try self.maybeCollect();

        const lv = try self.allocator.create(LispVal);
        lv.* = val;

        try self.trackObject(lv, .LispVal);
        return lv;
    }

    // Allocate a List and track it for GC
    pub fn createList(self: *GarbageCollector, size: usize) ![]LispVal {
        try self.maybeCollect();

        const list = try self.allocator.alloc(LispVal, size);

        // We need to box the slice to track it
        const list_ptr = try self.allocator.create([]LispVal);
        list_ptr.* = list;

        try self.trackObject(list_ptr, .List);
        return list;
    }

    // Allocate a Vector and track it for GC
    pub fn createVector(self: *GarbageCollector, size: usize) ![]f32 {
        try self.maybeCollect();

        const vec = try self.allocator.alloc(f32, size);

        // We need to box the slice to track it
        const vec_ptr = try self.allocator.create([]f32);
        vec_ptr.* = vec;

        try self.trackObject(vec_ptr, .Vector);
        return vec;
    }

    // Allocate a String and track it for GC
    pub fn createString(self: *GarbageCollector, str: []const u8) ![]const u8 {
        try self.maybeCollect();

        const new_str = try self.allocator.dupe(u8, str);

        // We need to box the slice to track it
        const str_ptr = try self.allocator.create([]const u8);
        str_ptr.* = new_str;

        try self.trackObject(str_ptr, .String);
        return new_str;
    }

    fn trackObject(self: *GarbageCollector, ptr: anytype, obj_type: ObjectType) !void {
        try self.objects.append(@ptrCast(ptr));
        try self.object_types.append(obj_type);
        try self.marks.append(false);
    }

    // Check if we should collect and run collection if needed
    fn maybeCollect(self: *GarbageCollector) !void {
        if (self.collecting) return; // Avoid recursive collection

        // Only collect if we have a reasonable number of objects
        if (self.objects.items.len >= 100 and self.objects.items.len >= self.threshold) {
            try self.collect();
        }
    }

    // Main garbage collection routine
    pub fn collect(self: *GarbageCollector) !void {
        if (self.collecting) return; // Prevent recursive collection
        self.collecting = true;
        defer self.collecting = false;

        // 1. Clear all mark bits
        for (self.marks.items) |*mark| {
            std.log.debug("marking {any}", .{mark});
            mark.* = false;
        }

        // 2. Mark phase: starts from root set (VM stack, global env)
        // This should be implemented separately and called before collection

        // 3. Sweep phase: free unmarked objects
        var i: usize = 0;
        while (i < self.objects.items.len) {
            if (!self.marks.items[i]) {
                // Object is not marked, free it
                const obj = self.objects.items[i];
                const obj_type = self.object_types.items[i];
                std.log.debug("freeing sweep {any}", .{obj});

                switch (obj_type) {
                    .Cons => {
                        const cons = @as(*Cons, @ptrCast(@alignCast(obj)));
                        self.allocator.destroy(cons);
                    },
                    .FnValue => {
                        const fn_val = @as(*FnValue, @ptrCast(@alignCast(obj)));
                        fn_val.defs.deinit();
                        if (fn_val.params) |params| {
                            for (params) |param| {
                                self.allocator.free(param);
                            }
                            self.allocator.free(params);
                        }
                        if (fn_val.code) |code| {
                            self.allocator.free(code);
                        }
                        self.allocator.destroy(fn_val);
                    },
                    .Env => {
                        const env = @as(*Env, @ptrCast(@alignCast(obj)));
                        env.deinit();
                        self.allocator.destroy(env);
                    },
                    .RuntimeObject => {
                        const obj_ptr = @as(*RuntimeObject, @ptrCast(@alignCast(obj)));
                        obj_ptr.table.deinit();
                        self.allocator.destroy(obj_ptr);
                    },
                    .LispVal => {
                        const val = @as(*LispVal, @ptrCast(@alignCast(obj)));
                        self.allocator.destroy(val);
                    },
                    .List => {
                        const list = @as(*[]LispVal, @ptrCast(@alignCast(obj)));
                        self.allocator.free(list.*);
                        self.allocator.destroy(list);
                    },
                    .Vector => {
                        const vec = @as(*[]f32, @ptrCast(@alignCast(obj)));
                        self.allocator.free(vec.*);
                        self.allocator.destroy(vec);
                    },
                    .String => {
                        const str = @as(*[]const u8, @ptrCast(@alignCast(obj)));
                        self.allocator.free(str.*);
                        self.allocator.destroy(str);
                    },
                }

                // Remove from the tracking lists by swapping with the last element
                _ = self.objects.swapRemove(i);
                _ = self.object_types.swapRemove(i);
                _ = self.marks.swapRemove(i);
            } else {
                // Object is marked, keep it
                i += 1;
            }
        }

        // Update threshold for next collection
        self.threshold = self.objects.items.len * 2;
    }

    // Mark a value and its descendants as reachable
    pub fn markValue(self: *GarbageCollector, val: LispVal) error{OutOfMemory}!void {
        switch (val) {
            .Cons => |cons| try self.markCons(cons),
            .Function => |fn_val| try self.markFnValue(fn_val),
            .Object => |obj| try self.markObject(obj),
            .Quote => |quote| try self.markValue(quote.*),
            .List => |list| {
                for (list) |item| {
                    try self.markValue(item);
                }
            },
            .ObjectLiteral => |entries| {
                for (entries) |entry| {
                    switch (entry) {
                        .Pair => |pair| try self.markValue(pair.value),
                        .Spread => |spread| try self.markValue(spread),
                    }
                }
            },
            .FunctionDef => |def| {
                for (def.patterns) |pattern| {
                    try self.markValue(pattern);
                }
            },
            // Simple values don't need marking
            .Number, .Symbol, .Nil, .String, .Vector, .Native => {},
        }
    }

    // Mark a Cons cell and its car/cdr
    fn markCons(self: *GarbageCollector, cons: *Cons) !void {
        // Find and mark the Cons cell
        for (self.objects.items, self.object_types.items, self.marks.items) |obj, obj_type, *mark| {
            if (obj_type == .Cons and obj == @as(*anyopaque, @ptrCast(cons))) {
                if (mark.*) return; // Already marked
                mark.* = true;
                break;
            }
        }

        // Recursively mark car and cdr
        try self.markValue(cons.car);
        try self.markValue(cons.cdr);
    }

    // Mark a Function value and its environment
    fn markFnValue(self: *GarbageCollector, fn_val: *FnValue) !void {
        // Find and mark the function
        for (self.objects.items, self.object_types.items, self.marks.items) |obj, obj_type, *mark| {
            if (obj_type == .FnValue and obj == @as(*anyopaque, @ptrCast(fn_val))) {
                if (mark.*) return; // Already marked
                mark.* = true;
                break;
            }
        }

        // Mark environment
        try self.markEnv(fn_val.env);

        // Mark function definitions
        for (fn_val.defs.items) |def| {
            for (def.patterns) |pattern| {
                try self.markValue(pattern);
            }
        }
    }

    // Mark an Environment and its variables
    fn markEnv(self: *GarbageCollector, env: *Env) !void {
        // Find and mark the environment
        var found = false;
        for (self.objects.items, self.object_types.items, self.marks.items) |obj, obj_type, *mark| {
            if (obj_type == .Env and obj == @as(*anyopaque, @ptrCast(env))) {
                if (mark.*) return; // Already marked
                mark.* = true;
                found = true;
                break;
            }
        }

        // If the environment is not tracked by the GC, we can still mark its contents
        // This can happen for the global environment that was created before GC was set up
        if (!found) {
            // Just mark its contents, don't try to mark the env itself
        }

        // Mark parent environment recursively
        if (env.parent) |parent| {
            try self.markEnv(parent);
        }

        // Mark all values in the environment
        var iter = env.vars.valueIterator();
        while (iter.next()) |val| {
            try self.markValue(val.*);
        }
    }

    // Mark an Object and its properties
    fn markObject(self: *GarbageCollector, obj: *RuntimeObject) !void {
        // Find and mark the object
        for (self.objects.items, self.object_types.items, self.marks.items) |obj_ptr, obj_type, *mark| {
            if (obj_type == .RuntimeObject and obj_ptr == @as(*anyopaque, @ptrCast(obj))) {
                if (mark.*) return; // Already marked
                mark.* = true;
                break;
            }
        }

        // Mark all values in the object
        var iter = obj.table.valueIterator();
        while (iter.next()) |val| {
            try self.markValue(val.*);
        }
    }

    // Mark all values in the VM stack
    pub fn markVMStack(self: *GarbageCollector, stack: std.ArrayList(LispVal)) !void {
        for (stack.items) |val| {
            try self.markValue(val);
        }
    }

    // Mark all roots (global environment, VM stack)
    pub fn markRoots(self: *GarbageCollector, env: *Env, stack: ?std.ArrayList(LispVal)) !void {
        try self.markEnv(env);

        if (stack) |s| {
            try self.markVMStack(s);
        }
    }
};
