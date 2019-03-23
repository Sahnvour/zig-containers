const std = @import("std");
const debug = std.debug;
const assert = debug.assert;
const warn = debug.warn;
const math = std.math;
const mem = std.mem;
const Allocator = mem.Allocator;
const builtin = @import("builtin");

pub fn hashInt(comptime HashInt: type, i: var) HashInt {
    var x: HashInt = i;

    if (HashInt.bit_count <= 32) {
        // Improved MurmurHash3 finalizer taken from https://nullprogram.com/blog/2018/07/31/
        x ^= x >> 16;
        x *%= 0x7feb352d;
        x ^= x >> 15;
        x *%= 0x846ca68b;
        x ^= x >> 16;
    } else if (HashInt.bit_count <= 64) {
        // Improved MurmurHash3 finalizer (Mix13) taken from http://zimbry.blogspot.com/2011/09/better-bit-mixing-improving-on.html
        x ^= x >> 30;
        x *%= 0xbf58476d1ce4e5b9;
        x ^= x >> 27;
        x *%= 0x94d049bb133111eb;
        x ^= x >> 31;
    } else @compileError("TODO");

    return x;
}

pub fn hashu32(x: u32) u32 {
    return @inlineCall(hashInt, u32, x);
}

pub fn eqlu32(x: u32, y: u32) bool {
    return x == y;
}

pub fn isPowerOfTwo(i: var) bool {
    return i & (i - 1) == 0;
}

pub fn roundToNextPowerOfTwo(comptime T: type, n: T) T {
    // TODO generate bit twiddling hacks with inline for based on type size
    if (T == u32) {
        var m = n;
        m -= 1;
        m |= m >> 1;
        m |= m >> 2;
        m |= m >> 4;
        m |= m >> 8;
        m |= m >> 16;
        m += 1;
        return m;
    } else @compileError("TODO");
}

pub fn HashMap(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();

        // TODO at least one slice is unnecessary
        entries: []KV,
        buckets: []Bucket,
        size: Size,
        allocator: *Allocator,

        const Size = u32;

        const KV = struct {
            key: K,
            value: V,
        };

        const Bucket = struct {
            hash: Size,
            index: Size,

            const Empty = 0xFFFFFFFF;
        };

        pub fn init(allocator: *Allocator) Self {
            return Self{
                .allocator = allocator,
                .entries = []KV{},
                .buckets = []Bucket{},
                .size = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buckets);
            self.allocator.free(self.entries);
            self.* = undefined;
        }

        pub fn reserve(self: *Self, cap: Size) !void {
            if (cap <= self.capacity()) {
                return;
            }

            const new_cap = roundToNextPowerOfTwo(Size, cap);
            if (self.size > 0) {
                unreachable; // TODO
            } else {
                try self.setCapacity(new_cap);
            }
        }

        pub fn clear(self: *Self) void {
            self.size = 0;
            self.initBuckets();
        }

        pub fn toSlice(self: *Self) []KV {
            return self.entries[0..self.size];
        }

        pub fn toSliceConst(self: *const Self) []const KV {
            return self.entries[0..self.size];
        }

        pub fn capacity(self: *const Self) Size {
            return @intCast(Size, self.buckets.len);
        }

        /// Result of a put operation.
        const PutResult = struct {
            /// Pointer to the new entry.
            kv: *KV,

            /// True if the key did not exist before put.
            inserted: bool,
        };

        /// Insert and entry in the map with precomputed hash. Assumes it is not already present.
        pub fn putHashed(self: *Self, key: K, value: V, hash: Size) !void {
            // TODO assert not contains
            try self.ensureCapacity();

            assert(self.buckets.len >= 0);
            assert(isPowerOfTwo(self.buckets.len));

            const mask = self.buckets.len - 1;
            var bucket_index = hash & mask;
            var bucket = &self.buckets[bucket_index];

            while (bucket.index != Bucket.Empty) : (bucket_index = (bucket_index + 1) & mask) {
                bucket = &self.buckets[bucket_index];
            }

            const index = self.size;
            self.size += 1;

            bucket.hash = hash;
            bucket.index = index;
            self.entries[index] = KV{ .key = key, .value = value };
        }

        /// Insert an entry in the map. Assumes it is not already present.
        pub fn put(self: *Self, key: K, value: V) !void {
            // TODO assert not contains
            try self.ensureCapacity();

            assert(self.buckets.len >= 0);
            assert(isPowerOfTwo(self.buckets.len));

            const hash = hashu32(key); // TODO hash &= 0x1, and bucket.hash==0 indicating empty bucket ?
            const mask = self.buckets.len - 1;
            var bucket_index = hash & mask;
            var bucket = &self.buckets[bucket_index];

            while (bucket.index != Bucket.Empty) : (bucket_index = (bucket_index + 1) & mask) {
                bucket = &self.buckets[bucket_index];
            }

            const index = self.size;
            self.size += 1;

            bucket.hash = hash;
            bucket.index = index;
            self.entries[index] = KV{ .key = key, .value = value };
        }

        /// Get an optional pointer to the value associated with key and precomputed hash, if present.
        pub fn getHashed(self: *const Self, key: K, hash: Size) ?*V {
            if (self.size == 0) {
                return null; // TODO better without branch ?
            }

            const mask: Size = @intCast(Size, self.buckets.len) - 1;
            var bucket_index = hash & mask;
            var bucket = &self.buckets[bucket_index];

            while (bucket.hash != hash and bucket.index != Bucket.Empty) : (bucket_index = (bucket_index + 1) & mask) {
                bucket = &self.buckets[bucket_index];
            }

            var entry_index = bucket.index;
            var entry = &self.entries[entry_index];
            while (entry.key != key) {
                // The entry at the bucket is not the one we're looking for, now probe through the collision chain.
                entry_index = (entry_index + 1) & mask;
                entry = &self.entries[entry_index];
                if (bucket.hash != hash or bucket.index == Bucket.Empty) {
                    return null;
                }
            }

            // std.debug.warn("found {}\n", bucket);
            // std.debug.warn("{}\n", entry);
            return &entry.value;
        }

        /// Get an optional pointer to the value associated with key, if present.
        pub fn get(self: *const Self, key: K) ?*V {
            if (self.size == 0) {
                return null; // TODO better without branch ?
            }

            const mask = self.buckets.len - 1;
            const hash = hashu32(key);
            var bucket_index = hash & mask;
            var bucket = &self.buckets[bucket_index];

            while (bucket.hash != hash and bucket.index != Bucket.Empty) : (bucket_index = (bucket_index + 1) & mask) {
                bucket = &self.buckets[bucket_index];
            }

            const entry = &self.entries[bucket.index];
            if (entry.key != key) {
                return null;
            }

            // std.debug.warn("found {}\n", bucket);
            // std.debug.warn("{}\n", entry);
            return &entry.value;
        }

        /// Remove an element. Assumes it is present.
        pub fn remove(self: *Self, key: K) bool {
            assert(self.size > 0);

            const mask = self.buckets.len - 1;
            const hash = hashu32(key);
            var bucket_index = hash & mask;
            var bucket = &self.buckets[bucket_index];

            while (bucket.hash != hash) : (bucket_index = (bucket_index + 1) & mask) {
                bucket = &self.buckets[bucket_index];
            }

            var entry = &self.entries[bucket.index];
            while (entry.key != key) : (bucket_index = (bucket_index + 1) & mask) {
                bucket = &self.buckets[bucket_index];
                assert(bucket.index != Bucket.Empty);
                assert(bucket.hash == hash);
                entry = &self.entries[bucket.index];
            }

            self.size -= 1;
            const entry_index = bucket.index;
            if (entry_index != self.size) {
                entry.* = self.entries[self.size];
                // TODO update last entry bucket index
            }
        }

        fn ensureCapacity(self: *Self) !void {
            if (self.capacity() == 0) {
                try self.setCapacity(16);
            }

            if (self.size * 5 >= self.buckets.len * 3) {
                warn("size {} cap {}\n", self.size, self.buckets.len);
                unreachable; // TODO
                // TODO check we will not grow over u32 size
            }
        }

        fn setCapacity(self: *Self, cap: Size) !void {
            self.entries = try self.allocator.alloc(KV, cap);
            self.buckets = try self.allocator.alloc(Bucket, cap); // TODO only alloc 60% of capacity
            self.initBuckets();
            self.size = 0;
        }

        fn initBuckets(self: *Self) void {
            for (self.buckets) |*bucket| {
                bucket.index = Bucket.Empty; // TODO replace this with something actually bulletproof and perf
            }
        }

        fn grow(self: *Self) !void {
            const new_capacity = self.buckets.len * 2;
            const new_entries = try self.allocator.alloc(KV, new_capacity);
            const new_buckets = try self.allocator.alloc(Bucket, new_capacity); // TODO only alloc 60% of capacity

            mem.copy(KV, new_entries[0..self.size], self.entries[0..self.size]);
            self.allocator.free(self.entries);
            self.entries = new_entries;

            self.allocator.free(self.buckets);
            self.buckets = new_buckets;
            self.initBuckets();
            self.rehash();
        }

        fn rehash(self: *Self) void {
            for (self.entries[0..self.size]) |entry| {
                unreachable;
            }
        }
    };
}

const expect = std.testing.expect;
test "basic usage" {
    var direct_allocator = std.heap.DirectAllocator.init();
    defer direct_allocator.deinit();

    var map = HashMap(u32, u32).init(&direct_allocator.allocator);
    defer map.deinit();

    const count = 5;
    var i: u32 = 1;
    var total: u32 = 0;
    while (i < count) : (i += 1) {
        try map.put(i, i);
        total += i;
    }

    var sum: u32 = 0;
    for (map.toSliceConst()) |kv| {
        sum += kv.key;
    }
    expect(sum == total);

    i = 1;
    sum = 0;
    while (i < count) : (i += 1) {
        if (map.get(i)) |j| {
            expect(i == j.*);
            sum += j.*;
        } else unreachable;
    }
    expect(total == sum);
}

test "reserve" {
    var direct_allocator = std.heap.DirectAllocator.init();
    defer direct_allocator.deinit();

    var map = HashMap(u32, u32).init(&direct_allocator.allocator);
    defer map.deinit();

    try map.reserve(129);
    expect(map.capacity() == 256);
    expect(map.size == 0);
}

test "clear" {
    var direct_allocator = std.heap.DirectAllocator.init();
    defer direct_allocator.deinit();

    var map = HashMap(u32, u32).init(&direct_allocator.allocator);
    defer map.deinit();

    try map.put(1, 1);
    expect(map.get(1).?.* == 1);
    expect(map.size == 1);

    const cap = map.capacity();
    expect(cap > 0);

    map.clear();
    expect(map.size == 0);
    expect(map.capacity() == cap);
    expect(map.get(1) == null);
}

test "put and get with precomputed hash" {
    var direct_allocator = std.heap.DirectAllocator.init();
    defer direct_allocator.deinit();

    var map = HashMap(u32, u32).init(&direct_allocator.allocator);
    defer map.deinit();

    var i: u32 = 0;
    while (i < 8) : (i += 1) {
        try map.putHashed(i, i * 3 + 1, hashu32(i));
    }

    i = 0;
    while (i < 8) : (i += 1) {
        expect(map.get(i).?.* == i * 3 + 1);
    }

    i = 0;
    while (i < 8) : (i += 1) {
        expect(map.getHashed(i, hashu32(i)).?.* == i * 3 + 1);
    }
}

test "get with long collision chain" {
    var direct_allocator = std.heap.DirectAllocator.init();
    defer direct_allocator.deinit();

    var map = HashMap(u32, u32).init(&direct_allocator.allocator);
    defer map.deinit();
    try map.reserve(32);

    // Using a fixed arbitrary hash for every value, we force collisions.
    var i: u32 = 0;
    while (i < 16) : (i += 1) {
        try map.putHashed(i, i, 0x12345678);
    }

    i = 0;
    while (i < 16) : (i += 1) {
        expect(map.getHashed(i, 0x12345678).?.* == i);
    }
}
