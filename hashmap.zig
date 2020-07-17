const std = @import("std");
const debug = std.debug;
const assert = debug.assert;
const warn = debug.warn;
const math = std.math;
const mem = std.mem;
const Allocator = mem.Allocator;
const builtin = @import("builtin");
const ceilPowerOfTwo = std.math.ceilPowerOfTwo;

pub fn hashInt(comptime HashInt: type, i: anytype) HashInt {
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

pub fn hashu32(x: u32) u64 {
    return @call(.{ .modifier = .always_inline }, hashInt, .{ u64, x });
}

pub fn eqlu32(x: u32, y: u32) bool {
    return x == y;
}

pub fn isPowerOfTwo(i: anytype) bool {
    return i & (i - 1) == 0;
}

/// A HashMap based on open addressing and linear probing.
pub fn HashMap(comptime K: type, comptime V: type, hashFn: fn (key: K) u64, eqlFn: fn (a: K, b: K) bool) type {
    return struct {
        const Self = @This();

        // TODO at least one slice is unnecessary
        entries: []KV,
        buckets: []Bucket,
        size: Size,
        allocator: *Allocator,

        const Size = u32;
        const Hash = u64;

        const KV = struct {
            key: K,
            value: V,
        };

        const Bucket = packed struct {
            const FingerPrint = u6;

            used: u1 = 0,
            tombstone: u1 = 0,
            fingerprint: FingerPrint = 0,

            pub fn isUsed(self: Bucket) bool {
                return self.used == 1;
            }

            pub fn isTombstone(self: Bucket) bool {
                return self.tombstone == 1;
            }

            pub fn takeFingerprint(hash: Hash) FingerPrint {
                const hash_bits = @typeInfo(Hash).Int.bits;
                const fp_bits = @typeInfo(FingerPrint).Int.bits;
                return @truncate(FingerPrint, hash >> (hash_bits - fp_bits));
            }

            pub fn continueProbing(self: Bucket) bool {
                return self.isUsed() or self.isTombstone();
            }

            pub fn fill(self: *Bucket, fp: FingerPrint) void {
                self.used = 1;
                self.tombstone = 0;
                self.fingerprint = fp;
            }

            pub fn clear(self: *Bucket) void {
                self.used = 0;
                self.tombstone = 1;
                self.fingerprint = 0;
            }
        };

        comptime {
            assert(@sizeOf(Bucket) == 1);
        }

        const Iterator = struct {
            hm: *const Self,
            count: Size = 0,
            index: Size = 0,

            pub fn next(it: *Iterator) ?*KV {
                assert(it.count <= it.hm.size);
                if (it.count == it.hm.size) return null;

                while (true) : (it.index += 1) {
                    const bucket = &it.hm.buckets[it.index];
                    if (bucket.isUsed()) {
                        const entry = &it.hm.entries[it.index];
                        it.index += 1;
                        it.count += 1;
                        return entry;
                    }
                }
            }
        };

        pub fn init(allocator: *Allocator) Self {
            return Self{
                .allocator = allocator,
                .entries = &[0]KV{},
                .buckets = &[0]Bucket{},
                .size = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buckets);
            self.allocator.free(self.entries);
            self.* = undefined;
        }

        fn capacityForSize(new_size: Size) Size {
            var new_cap = ceilPowerOfTwo(Size, new_size) catch unreachable;
            if (!isUnderMaxLoadFactor(new_size, new_cap)) {
                new_cap *= 2;
            }
            return new_cap;
        }

        pub fn reserve(self: *Self, new_size: Size) !void {
            if (new_size <= self.capacity()) {
                assert(isUnderMaxLoadFactor(self.size, self.capacity()));
                return;
            }

            // Get a new capacity that satisfies the constraint of the maximum load factor.
            const new_capacity = capacityForSize(new_size);
            if (self.capacity() == 0) {
                try self.setCapacity(new_capacity);
            } else {
                try self.grow(new_capacity);
            }
        }

        pub fn clear(self: *Self) void {
            self.size = 0;
            self.initBuckets();
        }

        pub fn count(self: *const Self) Size {
            return self.size;
        }

        pub fn capacity(self: *const Self) Size {
            return @intCast(Size, self.buckets.len);
        }

        pub fn iterator(self: *const Self) Iterator {
            return .{ .hm = self };
        }

        fn internalPut(self: *Self, key: K, value: V, hash: Hash) void {
            const mask = self.buckets.len - 1;
            var idx = hash & mask;

            var bucket = &self.buckets[idx];
            while (bucket.isUsed()) {
                idx = (idx + 1) & mask;
                bucket = &self.buckets[idx];
            }

            const fingerprint = Bucket.takeFingerprint(hash);
            bucket.fill(fingerprint);
            self.entries[idx] = KV{ .key = key, .value = value };

            self.size += 1;
        }

        /// Insert an entry in the map with precomputed hash. Assumes it is not already present.
        pub fn putHashed(self: *Self, key: K, value: V, hash: Hash) !void {
            assert(hash == hashFn(key));
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

            const hash = hashFn(key);
            self.internalPut(key, value, hash);
        }

        /// Insert an entry in the map. Assumes it is not already present,
        /// and that no allocation is needed.
        pub fn putNoGrow(self: *Self, key: K, value: V) void {
            assert(!self.contains(key));
            assert(self.buckets.len >= 0);
            assert(isPowerOfTwo(self.buckets.len));

            const hash = hashFn(key);
            self.internalPut(key, value, hash);
        }

        /// Insert an entry if the associated key is not already present, otherwise update preexisting value.
        /// Returns true if the key was already present.
        pub fn putOrUpdate(self: *Self, key: K, value: V) !bool {
            try self.ensureCapacity(); // Should this go after the 'get' part, at the cost of complicating the code ? Would it even be an actual optimization ?

            const hash = hashFn(key);
            const mask = @truncate(Size, self.buckets.len - 1);
            const fingerprint = Bucket.takeFingerprint(hash);
            var idx = @truncate(Size, hash & mask);

            var first_tombstone_idx: ?Size = null;
            var bucket = &self.buckets[idx];
            while (bucket.continueProbing()) {
                if (first_tombstone_idx == null and bucket.isTombstone()) {
                    first_tombstone_idx = idx;
                }

                if (bucket.fingerprint == fingerprint) {
                    const entry = &self.entries[idx];
                    if (eqlFn(entry.key, key)) {
                        entry.value = value;
                        return true;
                    }
                }
                idx = (idx + 1) & mask;
                bucket = &self.buckets[idx];
            }

            // Cheap try to lower probing lengths after deletions.
            if (first_tombstone_idx) |i| {
                bucket = &self.buckets[i];
            }

            self.size += 1;

            bucket.fill(fingerprint);
            self.entries[idx] = KV{ .key = key, .value = value };

            return false;
        }

        fn internalGet(self: *const Self, key: K, hash: Hash) ?*V {
            const mask = self.buckets.len - 1;
            const fingerprint = Bucket.takeFingerprint(hash);
            var idx = hash & mask;

            var bucket = &self.buckets[idx];
            while (bucket.continueProbing()) {
                if (!bucket.isTombstone() and bucket.fingerprint == fingerprint) {
                    const entry = &self.entries[idx];
                    if (eqlFn(entry.key, key)) {
                        return &entry.value;
                    }
                }
                idx = (idx + 1) & mask;
                bucket = &self.buckets[idx];
            }

            return null;
        }

        /// Get an optional pointer to the value associated with key and precomputed hash, if present.
        pub fn getHashed(self: *const Self, key: K, hash: Hash) ?*V {
            assert(hash == hashFn(key));
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

        pub fn getOrPut(self: *Self, key: K, value: V) !*V {
            try self.ensureCapacity(); // Should this go after the 'get' part, at the cost of complicating the code ? Would it even be an actual optimization ?

            const hash = hashFn(key);
            const mask = self.buckets.len - 1;
            const fingerprint = Bucket.takeFingerprint(hash);
            var idx = hash & mask;

            var bucket = &self.buckets[idx];
            while (bucket.continueProbing()) {
                if (!bucket.isTombstone() and bucket.fingerprint == fingerprint) {
                    const entry = &self.entries[idx];
                    if (eqlFn(entry.key, key)) {
                        return &entry.value;
                    }
                }
                idx = (idx + 1) & mask;
                bucket = &self.buckets[idx];
            }

            bucket.fill(fingerprint);
            const entry = &self.entries[idx];
            entry.* = .{ .key = key, .value = value };

            return &entry.value;
        }

        /// Return true if there is a value associated with key in the map.
        pub fn contains(self: *const Self, key: K) bool {
            return self.get(key) != null;
        }

        /// Remove the value associated with key, if present. Returns wether
        /// an element was removed.
        pub fn remove(self: *Self, key: K) bool {
            assert(self.size > 0);
            // assert(self.contains(key)); TODO make two versions of remove

            const hash = hashFn(key);
            const mask = self.buckets.len - 1;
            const fingerprint = Bucket.takeFingerprint(hash);
            var idx = hash & mask;

            var bucket = &self.buckets[idx];
            while (bucket.continueProbing()) {
                if (!bucket.isTombstone() and bucket.fingerprint == fingerprint) {
                    const entry = &self.entries[idx];
                    if (eqlFn(entry.key, key)) {
                        bucket.clear();
                        entry.* = undefined;
                        self.size -= 1;
                        return true;
                    }
                }
                idx = (idx + 1) & mask;
                bucket = &self.buckets[idx];
            }

            return false;
        }

        // Using u64 to avoid overflowing on big tables.
        fn isUnderMaxLoadFactor(size: u64, cap: u64) bool {
            return size * 5 < cap * 3;
        }

        fn ensureCapacity(self: *Self) !void {
            if (self.capacity() == 0) {
                try self.setCapacity(16);
            }

            const new_size = self.size + 1;
            if (!isUnderMaxLoadFactor(new_size, self.capacity())) {
                try self.grow(capacityForSize(new_size));
            }
        }

        fn setCapacity(self: *Self, cap: Size) !void {
            assert(self.capacity() == 0);
            assert(self.size == 0);
            self.entries = try self.allocator.alloc(KV, cap);
            self.buckets = try self.allocator.alloc(Bucket, cap);
            self.initBuckets();
            self.size = 0;
        }

        fn initBuckets(self: *Self) void {
            // TODO use other default values so that the memset can be faster ?
            std.mem.set(Bucket, self.buckets, Bucket{});
        }

        fn grow(self: *Self, new_capacity: Size) !void {
            assert(new_capacity > self.capacity());
            assert(isPowerOfTwo(new_capacity));

            const new_buckets = try self.allocator.alloc(Bucket, new_capacity);
            const new_entries = try self.allocator.alloc(KV, new_capacity);
            std.mem.set(Bucket, new_buckets, Bucket{});

            // Simple rehash implementation
            const old_entries = self.entries;
            const old_buckets = self.buckets;
            self.buckets = new_buckets;
            self.entries = new_entries;
            self.size = 0;

            for (old_buckets) |bucket, i| {
                if (bucket.isUsed()) {
                    const entry = old_entries[i];
                    self.putNoGrow(entry.key, entry.value);
                }
            }

            self.allocator.free(old_buckets);
            self.allocator.free(old_entries);
        }
    };
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const page_allocator = std.heap.page_allocator;

test "basic usage" {
    var map = HashMap(u32, u32, hashu32, eqlu32).init(page_allocator);
    defer map.deinit();

    const count = 5;
    var i: u32 = 0;
    var total: u32 = 0;
    while (i < count) : (i += 1) {
        try map.put(i, i);
        total += i;
    }

    var sum: u32 = 0;
    var it = map.iterator();
    while (it.next()) |kv| {
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
    var map = HashMap(u32, u32, hashu32, eqlu32).init(page_allocator);
    defer map.deinit();

    try map.reserve(9);
    expectEqual(map.capacity(), 16);
    try map.reserve(129);
    expectEqual(map.capacity(), 256);
    expectEqual(map.size, 0);
}

test "clear" {
    var map = HashMap(u32, u32, hashu32, eqlu32).init(page_allocator);
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
    var map = HashMap(u32, u32, hashu32, eqlu32).init(page_allocator);
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

// This test can only be run by removing the asserts checking hash consistency
// in putHashed and getHashed.
// test "put and get with long collision chain" {
//     var map = HashMap(u32, u32, hashu32, eqlu32).init(page_allocator);
//     defer map.deinit();
//     try map.reserve(32);

//     // Using a fixed arbitrary hash for every value, we force collisions.
//     var i: u32 = 0;
//     while (i < 16) : (i += 1) {
//         try map.putHashed(i, i, 0x12345678);
//     }

//     i = 0;
//     while (i < 16) : (i += 1) {
//         expectEqual(map.getHashed(i, 0x12345678).?.*, i);
//     }
// }

test "grow" {
    var map = HashMap(u32, u32, hashu32, eqlu32).init(page_allocator);
    defer map.deinit();

    const growTo = 12456;

    var i: u32 = 0;
    while (i < growTo) : (i += 1) {
        try map.put(i, i);
    }
    // this depends on the maximum load factor
    // warn("\ncap {} next {}\n", map.capacity(), ceilPowerOfTwo(u32, growTo));
    // expect(map.capacity() == ceilPowerOfTwo(u32, growTo));
    expectEqual(map.size, growTo);

    i = 0;
    var it = map.iterator();
    while (it.next()) |kv| {
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
    var map = HashMap(u32, u32, hashu32, eqlu32).init(page_allocator);
    defer map.deinit();

    try map.put(0, 0);
    expectEqual(map.size, 1);
    expectEqual(map.capacity(), 16);

    try map.reserve(65);
    expectEqual(map.size, 1);
    expectEqual(map.capacity(), 128);
}

test "reserve satisfies max load factor" {
    var map = HashMap(u32, u32, hashu32, eqlu32).init(page_allocator);
    defer map.deinit();

    try map.reserve(127);
    expectEqual(map.capacity(), 256);
}

test "remove" {
    var map = HashMap(u32, u32, hashu32, eqlu32).init(page_allocator);
    defer map.deinit();

    var i: u32 = 0;
    while (i < 16) : (i += 1) {
        try map.put(i, i);
    }

    i = 0;
    while (i < 16) : (i += 1) {
        if (i % 3 == 0) {
            _ = map.remove(i);
        }
    }
    expectEqual(map.size, 10);
    var it = map.iterator();
    while (it.next()) |kv| {
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
    var map = HashMap(u32, u32, hashu32, eqlu32).init(page_allocator);
    defer map.deinit();

    var i: u32 = 0;
    while (i < 16) : (i += 1) {
        try map.put(i, i);
    }

    i = 16;
    while (i > 0) : (i -= 1) {
        _ = map.remove(i - 1);
        expect(!map.contains(i - 1));
        var j: u32 = 0;
        while (j < i - 1) : (j += 1) {
            expectEqual(map.get(j).?.*, j);
        }
    }

    expectEqual(map.size, 0);
}

test "multiple removes on same buckets" {
    var map = HashMap(u32, u32, hashu32, eqlu32).init(page_allocator);
    defer map.deinit();

    var i: u32 = 0;
    while (i < 16) : (i += 1) {
        try map.put(i, i);
    }

    _ = map.remove(7);
    _ = map.remove(15);
    _ = map.remove(14);
    _ = map.remove(13);
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
    var map = HashMap(u32, u32, hashu32, eqlu32).init(page_allocator);
    defer map.deinit();

    var keys = std.ArrayList(u32).init(page_allocator);
    const size = 32;
    const iterations = 100;

    var i: u32 = 0;
    while (i < size) : (i += 1) {
        try keys.append(i);
    }
    var rng = std.rand.DefaultPrng.init(0);

    while (i < iterations) : (i += 1) {
        std.rand.Random.shuffle(&rng.random, u32, keys.items);

        for (keys.items) |key| {
            try map.put(key, key);
        }
        expectEqual(map.size, size);

        for (keys.items) |key| {
            _ = map.remove(key);
        }
        expectEqual(map.size, 0);
    }
}

test "remove one million elements in random order" {
    const Map = HashMap(u32, u32, hashu32, eqlu32);
    const n = 1000 * 1000;
    var map = Map.init(page_allocator);
    defer map.deinit();

    var keys = std.ArrayList(u32).init(page_allocator);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        keys.append(i) catch unreachable;
    }

    var rng = std.rand.DefaultPrng.init(0);
    std.rand.Random.shuffle(&rng.random, u32, keys.items);

    for (keys.items) |key| {
        map.put(key, key) catch unreachable;
    }

    std.rand.Random.shuffle(&rng.random, u32, keys.items);
    i = 0;
    while (i < n) : (i += 1) {
        const key = keys.items[i];
        _ = map.remove(key);
    }
}

test "putOrUpdate" {
    var map = HashMap(u32, u32, hashu32, eqlu32).init(page_allocator);
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

test "getOrPut" {
    var map = HashMap(u32, u32, hashu32, eqlu32).init(page_allocator);
    defer map.deinit();

    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        try map.put(i * 2, 2);
    }

    i = 0;
    while (i < 20) : (i += 1) {
        var n = try map.getOrPut(i, 1);
    }

    i = 0;
    var sum = i;
    while (i < 20) : (i += 1) {
        sum += map.get(i).?.*;
    }

    expectEqual(sum, 30);
}
