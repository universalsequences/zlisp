# Garbage Collection in Simple Lisp

This document explains the mark and sweep garbage collection system implemented in Simple Lisp.

## Overview

The garbage collector is implemented as a mark-and-sweep collector which:
1. Tracks heap-allocated objects
2. Periodically scans for unreachable objects
3. Frees memory for objects that are no longer referenced

## Key Components

### GarbageCollector

The main GC structure that manages the lifecycle of allocated objects:

```zig
pub const GarbageCollector = struct {
    // All allocated objects
    objects: std.ArrayList(*anyopaque),
    // Object type tracking
    object_types: std.ArrayList(ObjectType),
    // Mark bits for each object
    marks: std.ArrayList(bool),
    // Allocator for the GC itself
    allocator: std.mem.Allocator,
    // Collection trigger threshold
    threshold: usize,
    // Collection in progress flag
    collecting: bool,
    
    // Methods for object creation, marking, and collection
    // ...
};
```

### Tracked Object Types

The GC tracks various types of allocated objects:

```zig
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
```

## Mark and Sweep Algorithm

The garbage collector implements a classic mark-and-sweep algorithm:

### Mark Phase

1. Clear all mark bits
2. Start from root objects (global environment, VM stack)
3. Recursively mark all objects reachable from roots
4. Marked objects are considered live and should not be collected

```zig
// Mark all roots (global environment, VM stack)
pub fn markRoots(self: *GarbageCollector, env: *Env, stack: ?std.ArrayList(LispVal)) !void {
    try self.markEnv(env);
    
    if (stack) |s| {
        try self.markVMStack(s);
    }
}
```

### Sweep Phase

1. Scan all tracked objects
2. Free any object that wasn't marked in the mark phase
3. Remove freed objects from tracking lists

```zig
// Sweep phase: free unmarked objects
var i: usize = 0;
while (i < self.objects.items.len) {
    if (!self.marks.items[i]) {
        // Object is not marked, free it
        // ...
        
        // Remove from tracking lists
        _ = self.objects.swapRemove(i);
        _ = self.object_types.swapRemove(i);
        _ = self.marks.swapRemove(i);
    } else {
        // Object is marked, keep it
        i += 1;
    }
}
```

## Memory Management

The GC provides helper functions to allocate and track various types of objects:

```zig
pub fn createCons(self: *GarbageCollector, car: LispVal, cdr: LispVal) !*Cons
pub fn createFunction(self: *GarbageCollector, env: *Env) !*FnValue
pub fn createEnv(self: *GarbageCollector, parent: ?*Env) !*Env
pub fn createObject(self: *GarbageCollector) !*RuntimeObject
pub fn createList(self: *GarbageCollector, size: usize) ![]LispVal
pub fn createVector(self: *GarbageCollector, size: usize) ![]f32
pub fn createString(self: *GarbageCollector, str: []const u8) ![]const u8
```

## Integration with VM

The GC is integrated with the virtual machine:

1. VM executes with access to the GC
2. Periodically runs collection during execution
3. Performs collection after each REPL iteration

```zig
// Periodically run garbage collection in VM
if (call_stack.items.len % 100 == 0) {
    try gc.markRoots(env, stack);
    try gc.collect();
}
```

## Best Practices

When extending the interpreter, follow these guidelines:

1. Use GC allocation methods instead of direct allocation
2. Ensure all heap-allocated objects are tracked
3. Make sure root objects are properly marked
4. Consider collection frequency based on memory usage patterns