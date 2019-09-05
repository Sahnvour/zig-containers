const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const mem = std.mem;
const os = std.os;
const w = os.windows;
const warn = std.debug.warn;

inline fn pageCountForSize(size: usize) usize {
    return (size + mem.page_size - 1) / mem.page_size;
}

/// Special array based on the plentiness of address space available to 64bit
/// processes.
/// Reserves enough memory pages from the OS to hold at most `max_count`
/// items. Pages are committed as needed when the array grows in size.
/// Advantages:
/// - item addresses are stable throughout the lifetime of the array
/// - no need to realloc, thus:
///   - no temporary 2n memory usage
///   - no need to copy items to their new storage when growing
/// - at most `page_size` memory overhead from unused items
/// Drawbacks:
/// - has to declare a maximum size upfront
/// - not suited to small arrays because of the page granularity
/// - no automatic geometric growth
pub fn MonolithicArray(comptime T: type) type {
    // TODO support big sizes and alignments.
    comptime assert(@alignOf(T) <= mem.page_size);
    comptime assert(@sizeOf(T) <= mem.page_size);

    return struct {
        /// Always hold the actual pointer and length to existing items.
        items: []T,

        /// Total number of pages reserved.
        reserved_pages: usize,

        /// Number of pages currently used.
        committed_pages: usize,

        const Self = @This();
        const ElementSize = @sizeOf(T);
        const ElementsPerPage = mem.page_size / ElementSize;

        inline fn pageCountForItems(count: usize) usize {
            return pageCountForSize(count * ElementSize);
        }

        pub fn init(max_count: usize) !Self {
            const page_count = pageCountForItems(max_count);
            const alloc_size = page_count * mem.page_size;
            const ptr = switch (builtin.os) {
                .windows => try w.VirtualAlloc(
                    null,
                    alloc_size,
                    w.MEM_RESERVE,
                    w.PAGE_READWRITE,
                ),
                else => @compileError("TODO"),
            };

            return Self{
                .items = @ptrCast([*]T, @alignCast(@alignOf(T), ptr))[0..0],
                .reserved_pages = page_count,
                .committed_pages = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            switch (builtin.os) {
                .windows => w.VirtualFree(self.items.ptr, 0, w.MEM_RELEASE),
                else => @compileError("TODO"),
            }
        }

        pub fn size(self: *Self) usize {
            return self.items.len;
        }

        pub fn capacity(self: *Self) usize {
            return self.committed_pages * ElementsPerPage;
        }

        pub fn toSlice(self: *Self) []T {
            return self.items;
        }

        pub fn toSliceConst(self: *Self) []const T {
            return self.items;
        }

        fn grow(self: *Self, page_count: usize) !void {
            // Start address of the first non-committed-yet page.
            const ptr = @ptrToInt(self.items.ptr) + self.committed_pages * mem.page_size;
            switch (builtin.os) {
                // Calling directly kernel32 to bypass unexpectedError that
                // prints a stack trace during tests.
                .windows => _ = w.kernel32.VirtualAlloc(
                    @intToPtr(*c_void, ptr),
                    page_count * mem.page_size,
                    w.MEM_COMMIT,
                    w.PAGE_READWRITE,
                ) orelse return error.OutOfMemory,
                else => @compileError("TODO"),
            }
            self.committed_pages += page_count;
        }

        pub fn reserve(self: *Self, wanted_capacity: usize) !void {
            const wanted_page_count = pageCountForItems(wanted_capacity);
            if (wanted_page_count > self.committed_pages) {
                try self.grow(wanted_page_count - self.committed_pages);
            }
        }

        pub fn append(self: *Self, item: T) !void {
            const s = self.size();
            if (self.capacity() == s) {
                try self.grow(1);
            }
            self.items.len += 1;
            self.items[s] = item;
        }

        pub fn appendAssumeCapacity(self: *Self, item: T) void {
            assert(self.size() < self.capacity());

            const s = self.items.len;
            self.items.len += 1;
            self.items[s] = item;
        }

        pub fn appendSlice(self: *Self, items: []const T) !void {
            const s = self.size();
            const wanted_size = s + items.len;
            const cap = self.capacity();
            if (wanted_size > cap) {
                try self.grow(pageCountForItems(wanted_size - cap));
            }
            self.items.len = wanted_size;
            mem.copy(T, self.items[s..], items);
        }

        pub fn remove(self: *Self, i: usize) T {
            assert(i < self.size());

            const s = self.items.len - 1;
            const removed_elem = self.at(i);
            if (i != s) {
                self.items[i] = self.items[s];
            }
            self.items[s] = undefined;
            self.items.len = s;

            return removed_elem;
        }

        pub fn orderedRemove(self: *Self, i: usize) T {
            assert(i < self.size());

            const s = self.items.len - 1;
            const removed_elem = self.at(i);
            if (i != s) {
                var j: usize = i;
                while (j < s) : (j += 1) {
                    self.items[j] = self.items[j + 1];
                }
            }
            self.items.len = s;

            return removed_elem;
        }

        pub fn set(self: *Self, i: usize, item: T) void {
            assert(i < self.size());

            self.items[i] = item;
        }

        pub fn setOrError(self: *Self, i: usize, item: T) !void {
            if (i >= self.size()) return error.OutOfBounds;
            self.items[i] = item;
        }

        pub fn insert(self: *Self, i: usize, item: T) !void {
            assert(i < self.size());

            const s = self.size();
            const new_size = s + 1;
            if (self.capacity() == s) {
                try self.grow(1);
            }

            self.items.len = new_size;
            mem.copyBackwards(
                T,
                self.items[i + 1 .. new_size],
                self.items[i..s],
            );
            self.items[i] = item;
        }

        pub fn insertSlice(self: *Self, items: []const T) !void {}

        pub fn at(self: *const Self, i: usize) T {
            return self.items[i];
        }
    };
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

test "init" {
    var arr = try MonolithicArray(u32).init(1 << 32);
    defer arr.deinit();

    expectEqual(arr.size(), 0);
    expectEqual(arr.capacity(), 0);
    expectEqual(arr.committed_pages, 0);
}

test "append" {
    var arr = try MonolithicArray(u32).init(1 << 32);
    defer arr.deinit();

    try arr.append(123);
    try arr.append(456);
    try arr.append(789);
    expectEqual(arr.size(), 3);
    expectEqual(arr.committed_pages, 1);
}

test "appendAssumeCapacity" {
    var arr = try MonolithicArray(u32).init(1 << 32);
    defer arr.deinit();

    try arr.reserve(1); // force reserve for at least one item
    var i: u32 = 0;
    while (i < arr.capacity()) : (i += 1) {
        arr.appendAssumeCapacity(i);
    }
    expectEqual(arr.size(), arr.capacity());
    expectEqual(arr.committed_pages, 1);
}

test "appendSlice" {
    var arr = try MonolithicArray(u32).init(1 << 32);
    defer arr.deinit();

    try arr.append(1);
    try arr.append(2);
    try arr.append(3);
    try arr.appendSlice([_]u32{ 4, 5, 6 });
    try arr.append(7);

    expectEqual(arr.size(), 7);
    for (arr.toSliceConst()) |i, j| {
        expectEqual(i, @intCast(u32, j + 1));
    }
}

test "at" {
    var arr = try MonolithicArray(u32).init(1 << 32);
    defer arr.deinit();

    try arr.append(123);
    try arr.append(456);
    try arr.append(789);
    expectEqual(arr.at(0), 123);
    expectEqual(arr.at(1), 456);
    expectEqual(arr.at(2), 789);
}

test "out of memory" {
    const cap = mem.page_size / @sizeOf(u32);
    var arr = try MonolithicArray(u32).init(cap);
    defer arr.deinit();

    var i: u32 = 0;
    while (i < cap) : (i += 1) {
        try arr.append(i);
    }
    expectError(error.OutOfMemory, arr.append(i));
}

test "reserve" {
    var arr = try MonolithicArray(u32).init(1 << 32);
    defer arr.deinit();

    try arr.reserve(145);
    expect(arr.capacity() >= 145);
    expectEqual(arr.committed_pages, 1);
    expectEqual(arr.committed_pages, 1);
    expectEqual(arr.size(), 0);
}

test "reserve multiple pages" {
    var arr = try MonolithicArray(u32).init(1 << 32);
    defer arr.deinit();

    const page_count = 3;

    const capacity = (page_count * mem.page_size) / @sizeOf(u32);
    try arr.reserve(capacity);
    expectEqual(arr.capacity(), capacity);
    expectEqual(arr.committed_pages, page_count);
    expectEqual(arr.size(), 0);
}

test "reserve more pages than physical memory" {
    // We can ask for 16TB and the OS will just comply.
    const memory_size = 16 * 1000 * 1000 * 1000 * 1000;
    const capacity = memory_size / @sizeOf(u32);
    const page_count = pageCountForSize(memory_size);

    var arr = try MonolithicArray(u32).init(capacity);
    defer arr.deinit();

    expectEqual(arr.capacity(), 0);
    expectEqual(arr.size(), 0);
    expectEqual(arr.reserved_pages, page_count);
}

test "grow" {
    var arr = try MonolithicArray(u32).init(1 << 32);
    defer arr.deinit();

    const size = 1000 * 1000;

    var i: u32 = 0;
    while (i < size) : (i += 1) {
        try arr.append(i);
    }

    expectEqual(arr.size(), size);
}

test "remove" {
    var arr = try MonolithicArray(u32).init(1 << 32);
    defer arr.deinit();

    try arr.append(123);
    try arr.append(456);
    try arr.append(789);
    try arr.append(147);
    try arr.append(258);
    try arr.append(369);

    expectEqual(arr.remove(5), 369);
    expectEqual(arr.remove(0), 123);
    expectEqual(arr.remove(2), 789);

    expectEqual(arr.size(), 3);
    expectEqual(arr.at(0), 258);
    expectEqual(arr.at(1), 456);
    expectEqual(arr.at(2), 147);
}

test "orderedRemove" {
    var arr = try MonolithicArray(u32).init(1 << 32);
    defer arr.deinit();

    try arr.append(123);
    try arr.append(456);
    try arr.append(789);
    try arr.append(147);
    try arr.append(258);
    try arr.append(369);

    expectEqual(arr.orderedRemove(5), 369);
    expectEqual(arr.orderedRemove(0), 123);
    expectEqual(arr.orderedRemove(0), 456);

    expectEqual(arr.size(), 3);
    expectEqual(arr.at(0), 789);
    expectEqual(arr.at(1), 147);
    expectEqual(arr.at(2), 258);
}

test "set" {
    var arr = try MonolithicArray(u32).init(1 << 32);
    defer arr.deinit();

    try arr.append(0);
    try arr.append(0);
    try arr.append(0);

    arr.set(0, 123);
    arr.set(1, 456);
    arr.set(2, 789);

    expectEqual(arr.at(0), 123);
    expectEqual(arr.at(1), 456);
    expectEqual(arr.at(2), 789);
}

test "setOrError" {
    var arr = try MonolithicArray(u32).init(1 << 32);
    defer arr.deinit();

    try arr.append(0);

    expectError(error.OutOfBounds, arr.setOrError(1, 0));
    expectError(error.OutOfBounds, arr.setOrError(2, 0));
    expectError(error.OutOfBounds, arr.setOrError(123456, 0));
}

test "insert" {
    var arr = try MonolithicArray(u32).init(1 << 32);
    defer arr.deinit();

    try arr.append(123);
    try arr.append(456);
    try arr.append(789);

    try arr.insert(1, 159);

    expectEqual(arr.size(), 4);
    expectEqual(arr.at(0), 123);
    expectEqual(arr.at(1), 159);
    expectEqual(arr.at(2), 456);
    expectEqual(arr.at(3), 789);
}
