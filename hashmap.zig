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

pub fn roundToNextPowerOfTwo(n: var) u32 {
    const T = @typeOf(n);
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
    } else {
        return roundToNextPowerOfTwo(@intCast(u32, n)); // TODO
    }
}

pub fn HashMap(comptime K: type, comptime V: type, hashFn: fn (key: K) u32, eqlFn: fn (a: K, b: K) bool) type {
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
            const TombStone = Empty - 1;
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

        pub fn reserve(self: *Self, size: Size) !void {
            if (size <= self.capacity()) {
                assert(isUnderMaxLoadFactor(self.size, self.capacity()));
                return;
            }

            // Get a new capacity that satisfies the constraint of the maximum load factor.
            const new_capacity = blk: {
                var cap = roundToNextPowerOfTwo(size);
                if (!isUnderMaxLoadFactor(size, cap)) {
                    cap *= 2;
                }
                break :blk cap;
            };

            if (self.size == 0) {
                try self.setCapacity(new_capacity);
            } else {
                try self.grow(new_capacity);
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

        fn internalPut(self: *Self, key: K, value: V, hash: Size) void {
            const mask = self.buckets.len - 1;
            var bucket_index = hash & mask;
            var bucket = &self.buckets[bucket_index];

            while (bucket.index != Bucket.Empty and bucket.index != Bucket.TombStone) {
                bucket_index = (bucket_index + 1) & mask;
                bucket = &self.buckets[bucket_index];
            }

            const index = self.size;
            self.size += 1;

            bucket.hash = hash;
            bucket.index = index;
            self.entries[index] = KV{ .key = key, .value = value };
        }

        /// Insert an entry in the map with precomputed hash. Assumes it is not already present.
        pub fn putHashed(self: *Self, key: K, value: V, hash: Size) !void {
            assert(!self.contains(key));
            try self.ensureCapacity();

            assert(self.buckets.len >= 0);
            assert(isPowerOfTwo(self.buckets.len));

            self.internalPut(key, value, hash);
        }

        /// Insert an entry in the map. Assumes it is not already present.
        pub fn put(self: *Self, key: K, value: V) !void {
            assert(!self.contains(key));
            try self.ensureCapacity();

            assert(self.buckets.len >= 0);
            assert(isPowerOfTwo(self.buckets.len));

            const hash = hashFn(key); // TODO hash |= 0x1, and bucket.hash==0 indicating empty bucket ?
            self.internalPut(key, value, hash);
        }

        /// Insert an entry if the associated key is not already present, otherwise update preexisting value.
        /// Returns true if the key was already present.
        pub fn putOrUpdate(self: *Self, key: K, value: V) !bool {
            try self.ensureCapacity(); // TODO move after the get part

            // Same code as internalGet except we update the value if found.
            const mask: Size = @intCast(Size, self.buckets.len) - 1;
            const hash = hashFn(key);
            var bucket_index = hash & mask;
            var bucket = &self.buckets[bucket_index];
            while (bucket.index != Bucket.Empty) : ({
                bucket_index = (bucket_index + 1) & mask;
                bucket = &self.buckets[bucket_index];
            }) {
                if (bucket.hash == hash) {
                    const entry_index = bucket.index;
                    const entry = &self.entries[entry_index];
                    if (eqlFn(entry.key, key)) {
                        entry.value = value;
                        return true;
                    }
                }
            }

            // No existing key found, put it there.
            const index = self.size;
            self.size += 1;

            bucket.hash = hash;
            bucket.index = index;
            self.entries[index] = KV{ .key = key, .value = value };

            return false;
        }

        fn internalGet(self: *const Self, key: K, hash: Size) ?*V {
            const mask: Size = @intCast(Size, self.buckets.len) - 1;

            var bucket_index = hash & mask;
            var bucket = &self.buckets[bucket_index];
            while (bucket.index != Bucket.Empty) : ({
                bucket_index = (bucket_index + 1) & mask;
                bucket = &self.buckets[bucket_index];
            }) {
                if (bucket.hash == hash) {
                    const entry_index = bucket.index;
                    const entry = &self.entries[entry_index];
                    if (eqlFn(entry.key, key)) {
                        return &entry.value;
                    }
                }
            }

            return null;
        }

        /// Get an optional pointer to the value associated with key and precomputed hash, if present.
        pub fn getHashed(self: *const Self, key: K, hash: Size) ?*V {
            if (self.size == 0) {
                return null; // TODO better without branch ?
            }

            return self.internalGet(key, hash);
        }

        /// Get an optional pointer to the value associated with key, if present.
        pub fn get(self: *const Self, key: K) ?*V {
            if (self.size == 0) {
                return null; // TODO better without branch ?
            }

            const hash = hashFn(key);
            return self.internalGet(key, hash);
        }

        /// Return true if there is a value associated with key in the map.
        pub fn contains(self: *const Self, key: K) bool {
            return self.get(key) != null;
        }

        /// Remove the value associated with key. Assumes it is present.
        pub fn remove(self: *Self, key: K) void {
            assert(self.size > 0);
            assert(self.contains(key));

            const mask = @intCast(Size, self.buckets.len - 1);
            const hash = hashFn(key);
            var bucket_index = hash & mask;
            var bucket = &self.buckets[bucket_index];

            var entry: *KV = undefined;
            const entry_index = while (bucket.index != Bucket.Empty) : ({
                bucket_index = (bucket_index + 1) & mask;
                bucket = &self.buckets[bucket_index];
            }) {
                if (bucket.hash == hash) {
                    entry = &self.entries[bucket.index];
                    if (eqlFn(entry.key, key)) {
                        break bucket.index;
                    }
                }
            } else unreachable;

            bucket.index = Bucket.TombStone;
            bucket.hash = undefined;

            self.size -= 1;
            if (entry_index != self.size) {
                // Simply move the last element
                entry.* = self.entries[self.size];
                self.entries[self.size] = undefined;

                // And update its bucket accordingly.
                const moved_index = self.size;
                const moved_hash = hashFn(entry.key);
                bucket_index = moved_hash & mask;
                bucket = &self.buckets[bucket_index];
                while (bucket.index != moved_index) {
                    bucket_index = (bucket_index + 1) & mask;
                    bucket = &self.buckets[bucket_index];
                }
                assert(bucket.hash == moved_hash);
                bucket.index = entry_index;
            }
        }

        fn isUnderMaxLoadFactor(size: Size, cap: Size) bool {
            return size * 5 < cap * 3;
        }

        fn ensureCapacity(self: *Self) !void {
            if (self.capacity() == 0) {
                try self.setCapacity(16);
            }

            if (!isUnderMaxLoadFactor(self.size, self.capacity())) {
                assert(self.buckets.len < std.math.maxInt(Size) / 2);
                const new_capacity = @intCast(Size, self.buckets.len * 2);
                try self.grow(new_capacity);
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

        fn grow(self: *Self, new_capacity: Size) !void {
            assert(isPowerOfTwo(new_capacity));
            // We don't care about the old bucket data, so we can free it first to reduce memory pressure.
            self.allocator.free(self.buckets);

            const new_entries = try self.allocator.alloc(KV, new_capacity); // TODO only alloc 60% of capacity
            // If by any chance a realloc was successful in extending the already used memory, no need to copy and free.
            // TODO check that this is possible with the allocator interface
            if (new_entries.ptr != self.entries.ptr) {
                mem.copy(KV, new_entries[0..self.size], self.entries[0..self.size]);
                self.allocator.free(self.entries);
            }
            self.entries = new_entries;

            const new_buckets = try self.allocator.alloc(Bucket, new_capacity);
            self.buckets = new_buckets;
            self.initBuckets();
            self.rehash();
        }

        fn rehash(self: *Self) void {
            for (self.entries[0..self.size]) |entry, i| {
                const mask = self.buckets.len - 1;
                const hash = hashFn(entry.key);
                var bucket_index = hash & mask;
                var bucket = &self.buckets[bucket_index];

                while (bucket.index != Bucket.Empty) : (bucket_index = (bucket_index + 1) & mask) {
                    bucket = &self.buckets[bucket_index];
                }

                bucket.hash = hash;
                bucket.index = @intCast(Size, i);
            }
        }
    };
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "round to next power of two" {
    expectEqual(roundToNextPowerOfTwo(1), 1);
    expectEqual(roundToNextPowerOfTwo(2), 2);
    expectEqual(roundToNextPowerOfTwo(3), 4);
    expectEqual(roundToNextPowerOfTwo(4), 4);
    expectEqual(roundToNextPowerOfTwo(13), 16);
    expectEqual(roundToNextPowerOfTwo(17), 32);
}

test "basic usage" {
    var direct_allocator = std.heap.DirectAllocator.init();
    defer direct_allocator.deinit();

    var map = HashMap(u32, u32, hashu32, eqlu32).init(&direct_allocator.allocator);
    defer map.deinit();

    const count = 5;
    var i: u32 = 0;
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

    i = 0;
    sum = 0;
    while (i < count) : (i += 1) {
        expectEqual(map.get(i).?.*, i);
        sum += map.get(i).?.*;
    }
    expectEqual(total, sum);
}

test "reserve" {
    var direct_allocator = std.heap.DirectAllocator.init();
    defer direct_allocator.deinit();

    var map = HashMap(u32, u32, hashu32, eqlu32).init(&direct_allocator.allocator);
    defer map.deinit();

    try map.reserve(9);
    expectEqual(map.capacity(), 16);
    try map.reserve(129);
    expectEqual(map.capacity(), 256);
    expectEqual(map.size, 0);
}

test "clear" {
    var direct_allocator = std.heap.DirectAllocator.init();
    defer direct_allocator.deinit();

    var map = HashMap(u32, u32, hashu32, eqlu32).init(&direct_allocator.allocator);
    defer map.deinit();

    try map.put(1, 1);
    expectEqual(map.get(1).?.*, 1);
    expectEqual(map.size, 1);

    const cap = map.capacity();
    expect(cap > 0);

    map.clear();
    expectEqual(map.size, 0);
    expectEqual(map.capacity(), cap);
    expect(!map.contains(1));
}

test "put and get with precomputed hash" {
    var direct_allocator = std.heap.DirectAllocator.init();
    defer direct_allocator.deinit();

    var map = HashMap(u32, u32, hashu32, eqlu32).init(&direct_allocator.allocator);
    defer map.deinit();

    var i: u32 = 0;
    while (i < 8) : (i += 1) {
        try map.putHashed(i, i * 3 + 1, hashu32(i));
    }

    i = 0;
    while (i < 8) : (i += 1) {
        expectEqual(map.get(i).?.*, i * 3 + 1);
    }

    i = 0;
    while (i < 8) : (i += 1) {
        expectEqual(map.getHashed(i, hashu32(i)).?.*, i * 3 + 1);
    }
}

test "put and get with long collision chain" {
    var direct_allocator = std.heap.DirectAllocator.init();
    defer direct_allocator.deinit();

    var map = HashMap(u32, u32, hashu32, eqlu32).init(&direct_allocator.allocator);
    defer map.deinit();
    try map.reserve(32);

    // Using a fixed arbitrary hash for every value, we force collisions.
    var i: u32 = 0;
    while (i < 16) : (i += 1) {
        try map.putHashed(i, i, 0x12345678);
    }

    i = 0;
    while (i < 16) : (i += 1) {
        expectEqual(map.getHashed(i, 0x12345678).?.*, i);
    }
}

test "grow" {
    var direct_allocator = std.heap.DirectAllocator.init();
    defer direct_allocator.deinit();

    var map = HashMap(u32, u32, hashu32, eqlu32).init(&direct_allocator.allocator);
    defer map.deinit();

    const growTo = 12456;

    var i: u32 = 0;
    while (i < growTo) : (i += 1) {
        try map.put(i, i);
    }
    // this depends on the maximum load factor
    // warn("\ncap {} next {}\n", map.capacity(), roundToNextPowerOfTwo(growTo));
    // expect(map.capacity() == roundToNextPowerOfTwo(growTo));
    expectEqual(map.size, growTo);

    i = 0;
    for (map.toSliceConst()) |kv| {
        expectEqual(kv.key, kv.value);
        i += 1;
    }
    expectEqual(i, growTo);

    i = 0;
    while (i < growTo) : (i += 1) {
        expectEqual(map.get(i).?.*, i);
    }
}

test "reserve with existing elements" {
    var direct_allocator = std.heap.DirectAllocator.init();
    defer direct_allocator.deinit();

    var map = HashMap(u32, u32, hashu32, eqlu32).init(&direct_allocator.allocator);
    defer map.deinit();

    try map.put(0, 0);
    expectEqual(map.size, 1);
    expectEqual(map.capacity(), 16);

    try map.reserve(65);
    expectEqual(map.size, 1);
    expectEqual(map.capacity(), 128);
}

test "reserve satisfies max load factor" {
    var direct_allocator = std.heap.DirectAllocator.init();
    defer direct_allocator.deinit();

    var map = HashMap(u32, u32, hashu32, eqlu32).init(&direct_allocator.allocator);
    defer map.deinit();

    try map.reserve(127);
    expectEqual(map.capacity(), 256);
}

test "remove" {
    var direct_allocator = std.heap.DirectAllocator.init();
    defer direct_allocator.deinit();

    var map = HashMap(u32, u32, hashu32, eqlu32).init(&direct_allocator.allocator);
    defer map.deinit();

    var i: u32 = 0;
    while (i < 16) : (i += 1) {
        try map.put(i, i);
    }

    i = 0;
    while (i < 16) : (i += 1) {
        if (i % 3 == 0) {
            map.remove(i);
        }
    }
    expectEqual(map.size, 10);
    for (map.toSliceConst()) |kv, j| {
        expectEqual(kv.key, kv.value);
        expect(kv.key % 3 != 0);
    }

    i = 0;
    while (i < 16) : (i += 1) {
        if (i % 3 == 0) {
            expect(!map.contains(i));
        } else {
            expectEqual(map.get(i).?.*, i);
        }
    }
}

test "reverse removes" {
    var direct_allocator = std.heap.DirectAllocator.init();
    defer direct_allocator.deinit();

    var map = HashMap(u32, u32, hashu32, eqlu32).init(&direct_allocator.allocator);
    defer map.deinit();

    var i: u32 = 0;
    while (i < 16) : (i += 1) {
        try map.put(i, i);
    }

    i = 16;
    while (i > 0) : (i -= 1) {
        map.remove(i - 1);
        expect(!map.contains(i - 1));
        var j: u32 = 0;
        while (j < i - 1) : (j += 1) {
            expectEqual(map.get(j).?.*, j);
        }
    }

    expectEqual(map.size, 0);
}

test "multiple removes on same buckets" {
    var direct_allocator = std.heap.DirectAllocator.init();
    defer direct_allocator.deinit();

    var map = HashMap(u32, u32, hashu32, eqlu32).init(&direct_allocator.allocator);
    defer map.deinit();

    var i: u32 = 0;
    while (i < 16) : (i += 1) {
        try map.put(i, i);
    }

    map.remove(7);
    map.remove(15);
    map.remove(14);
    map.remove(13);
    expect(!map.contains(7));
    expect(!map.contains(15));
    expect(!map.contains(14));
    expect(!map.contains(13));

    i = 0;
    while (i < 13) : (i += 1) {
        if (i == 7) {
            expect(!map.contains(i));
        } else {
            expectEqual(map.get(i).?.*, i);
        }
    }

    try map.put(15, 15);
    try map.put(13, 13);
    try map.put(14, 14);
    try map.put(7, 7);
    i = 0;
    while (i < 16) : (i += 1) {
        expectEqual(map.get(i).?.*, i);
    }
}

test "put and remove loop in random order" {
    var direct_allocator = std.heap.DirectAllocator.init();
    defer direct_allocator.deinit();

    var map = HashMap(u32, u32, hashu32, eqlu32).init(&direct_allocator.allocator);
    defer map.deinit();

    var keys = std.ArrayList(u32).init(&direct_allocator.allocator);
    const size = 32;
    const iterations = 100;

    var i: u32 = 0;
    while (i < size) : (i += 1) {
        try keys.append(i);
    }
    var rng = std.rand.DefaultPrng.init(0);

    while (i < iterations) : (i += 1) {
        std.rand.Random.shuffle(&rng.random, u32, keys.toSlice());

        for (keys.toSlice()) |key| {
            try map.put(key, key);
        }
        expectEqual(map.size, size);

        for (keys.toSlice()) |key| {
            map.remove(key);
        }
        expectEqual(map.size, 0);
    }
}

test "putOrUpdate" {
    var direct_allocator = std.heap.DirectAllocator.init();
    defer direct_allocator.deinit();

    var map = HashMap(u32, u32, hashu32, eqlu32).init(&direct_allocator.allocator);
    defer map.deinit();

    var i: u32 = 0;
    while (i < 16) : (i += 1) {
        _ = try map.putOrUpdate(i, i);
    }

    i = 0;
    while (i < 16) : (i += 1) {
        expectEqual(map.get(i).?.*, i);
    }

    i = 0;
    while (i < 16) : (i += 1) {
        expect(try map.putOrUpdate(i, i * 16 + 1));
    }

    i = 0;
    while (i < 16) : (i += 1) {
        expectEqual(map.get(i).?.*, i * 16 + 1);
    }
}
