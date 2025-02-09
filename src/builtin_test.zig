// builtin_test.zig
const std = @import("std");
const value = @import("value.zig");
const builtin = @import("builtin.zig");
const vm = @import("vm.zig");

test "builtin cons, car, cdr, list" {
    const allocator = std.heap.page_allocator;

    // Short alias for our value types.
    const LispVal = value.LispVal;

    // Create some test LispVal numbers.
    const one = LispVal{ .Number = 1 };
    const two = LispVal{ .Number = 2 };
    const three = LispVal{ .Number = 3 };

    // === Test builtin_cons ===
    // (cons 1 2)
    var consArgs = [_]LispVal{ one, two };
    const cons_val = try builtin.builtin_cons(consArgs[0..], allocator);

    // Ensure the result is a cons cell.
    // (We check the tag using Zig’s built-in meta info.)
    try std.testing.expect(@as(std.meta.Tag(LispVal), cons_val) == .Cons);
    const cons_ptr = cons_val.Cons; // pointer to the cons cell
    // Check that car is 1 and cdr is 2.
    try std.testing.expect(cons_ptr.*.car.Number == one.Number);
    try std.testing.expect(cons_ptr.*.cdr.Number == two.Number);

    // === Test builtin_car ===
    // (car (cons 1 2)) should yield 1.
    var carArgs = [_]LispVal{cons_val};
    const car_val = try builtin.builtin_car(carArgs[0..], allocator);
    try std.testing.expect(@as(std.meta.Tag(LispVal), car_val) == .Number);
    try std.testing.expect(car_val.Number == one.Number);

    // === Test builtin_cdr ===
    // (cdr (cons 1 2)) should yield 2.
    var cdrArgs = [_]LispVal{cons_val};
    const cdr_val = try builtin.builtin_cdr(cdrArgs[0..], allocator);
    try std.testing.expect(@as(std.meta.Tag(LispVal), cdr_val) == .Number);
    try std.testing.expect(cdr_val.Number == two.Number);

    // === Test builtin_list ===
    // (list 1 2 3) should construct a proper list equivalent to:
    //   (cons 1 (cons 2 (cons 3 nil)))
    var listArgs = [_]LispVal{ one, two, three };
    const list_val = try builtin.builtin_list(listArgs[0..], allocator);

    // Traverse the list and check that we get 1, 2, 3 in order.
    var cur = list_val;
    // First cell:
    try std.testing.expect(@as(std.meta.Tag(LispVal), cur) == .Cons);
    var curCons = cur.Cons.*;
    try std.testing.expect(curCons.car.Number == one.Number);
    // Second cell:
    cur = curCons.cdr;
    try std.testing.expect(@as(std.meta.Tag(LispVal), cur) == .Cons);
    curCons = cur.Cons.*;
    try std.testing.expect(curCons.car.Number == two.Number);
    // Third cell:
    cur = curCons.cdr;
    try std.testing.expect(@as(std.meta.Tag(LispVal), cur) == .Cons);
    curCons = cur.Cons.*;
    try std.testing.expect(curCons.car.Number == three.Number);
    // The cdr of the third cell should be nil.
    cur = curCons.cdr;
    try std.testing.expect(@as(std.meta.Tag(LispVal), cur) == .Nil);
}
