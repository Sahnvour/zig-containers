const std = @import("std");
const builtin = @import("builtin");
const assert = debug.assert;
const autoHash = std.hash.autoHash;
const debug = std.debug;
const warn = debug.warn;
const math = std.math;
const mem = std.mem;
const meta = std.meta;
const trait = meta.trait;
const Allocator = mem.Allocator;
const Wyhash = std.hash.Wyhash;

pub fn getAutoHashFn(comptime K: type) (fn (K) u64) {
    return struct {
        fn hash(key: K) u64 {
            if (comptime trait.hasUniqueRepresentation(K)) {
                return Wyhash.hash(0, std.mem.asBytes(&key));
            } else {
                var hasher = Wyhash.init(0);
                autoHash(&hasher, key);
                return hasher.final();
            }
        }
    }.hash;
}

pub fn getAutoEqlFn(comptime K: type) (fn (K, K) bool) {
    return struct {
        fn eql(a: K, b: K) bool {
            return meta.eql(a, b);
        }
    }.eql;
}

pub fn AutoHashMap(comptime K: type, comptime V: type) type {
    return HashMap(K, V, comptime getAutoHashFn(K), getAutoEqlFn(V), 80);
}

/// A HashMap based on open addressing and linear probing.
pub fn HashMap(
    comptime K: type,
    comptime V: type,
    hashFn: fn (key: K) u64,
    eqlFn: fn (a: K, b: K) bool,
    comptime MaxLoadPercentage: u64,
) type {
    return struct {
        const Self = @This();

        /// Pointer to the metadata.
        /// This is actually a midway pointer to the single buffer containing
        /// a `Header` field, the `Metadata`s and `Entry`s.
        /// At `-@sizeOf(Header)` is the Header field.
        /// At `sizeOf(Metadata) * capacity + offset` are the entries.
        metadata: ?[*]Metadata = null,

        /// Current number of elements in the hashmap.
        size: Size = 0,

        /// Number of available slots before a grow is needed to satisfy the
        /// `MaxLoadPercentage`.
        available: Size = 0,

        allocator: *Allocator,

        /// Capacity of the first grow when bootstrapping the hashmap.
        const MinimalCapacity = 8;
        const Size = u32;
        const Hash = u64;

        const Entry = struct {
            key: K,
            value: V,
        };

        const Header = packed struct {
            entries: [*]Entry,
            capacity: Size,
        };

        /// Metadata for a slot. It can be in three states: empty, used or
        /// tombstone. Tombstones indicate that an entry was previously used,
        /// they are a simple way to handle removal.
        /// To this state, we add 6 bits from the slot's key hash. These are
        /// used as a fast way to disambiguate between entries without
        /// having to use the equality function. If two fingerprints are
        /// different, we know that we don't have to compare the keys at all.
        /// The 6 bits are the highest ones from a 64 bit hash. This way, not
        /// only we use the `log2(capacity)` lowest bits from the hash to determine
        /// a slot index, but we use 6 more bits to quickly resolve collisions
        /// when multiple elements with different hashes end up wanting to be in / the same slot.
        const Metadata = packed struct {
            const FingerPrint = u6;

            used: u1 = 0,
            tombstone: u1 = 0,
            fingerprint: FingerPrint = 0,

            pub fn isUsed(self: Metadata) bool {
                return self.used == 1;
            }

            pub fn isTombstone(self: Metadata) bool {
                return self.tombstone == 1;
            }

            pub fn takeFingerprint(hash: Hash) FingerPrint {
                const hash_bits = @typeInfo(Hash).Int.bits;
                const fp_bits = @typeInfo(FingerPrint).Int.bits;
                return @truncate(FingerPrint, hash >> (hash_bits - fp_bits));
            }

            pub fn fill(self: *Metadata, fp: FingerPrint) void {
                self.used = 1;
                self.tombstone = 0;
                self.fingerprint = fp;
            }

            pub fn remove(self: *Metadata) void {
                self.used = 0;
                self.tombstone = 1;
                self.fingerprint = 0;
            }
        };

        comptime {
            assert(@sizeOf(Metadata) == 1);
            assert(@alignOf(Metadata) == 1);
        }

        const Iterator = struct {
            hm: *const Self,
            index: Size = 0,

            pub fn next(it: *Iterator) ?*Entry {
                assert(it.index <= it.hm.capacity());
                if (it.hm.size == 0) return null;

                const cap = it.hm.capacity();
                const end = it.hm.metadata.? + cap;
                var metadata = it.hm.metadata.? + it.index;

                while (metadata != end) : ({
                    metadata += 1;
                    it.index += 1;
                }) {
                    if (metadata[0].isUsed()) {
                        const entry = &it.hm.entries()[it.index];
                        it.index += 1;
                        return entry;
                    }
                }

                return null;
            }
        };

        pub const GetOrPutResult = struct {
            entry: *Entry,
            found_existing: bool,
        };

        fn isUnderMaxLoadPercentage(size: Size, cap: Size) bool {
            return size * 100 < MaxLoadPercentage * cap;
        }

        pub fn init(allocator: *Allocator) Self {
            return .{
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.deallocate();
            self.* = undefined;
        }

        fn deallocate(self: *Self) void {
            if (self.metadata == null) return;

            const cap = self.capacity();
            const meta_size = @sizeOf(Header) + cap * @sizeOf(Metadata);

            const alignment = @alignOf(Entry) - 1;
            const entries_size = @as(usize, cap) * @sizeOf(Entry) + alignment;

            const total_size = meta_size + entries_size;

            var slice: []u8 = undefined;
            slice.ptr = @intToPtr([*]u8, @ptrToInt(self.header()));
            slice.len = total_size;
            self.allocator.free(slice);

            self.metadata = null;
            self.available = 0;
        }

        fn capacityForSize(size: Size) Size {
            var new_cap = @truncate(u32, (@as(u64, size) * 100) / MaxLoadPercentage + 1);
            new_cap = math.ceilPowerOfTwo(u32, new_cap) catch unreachable;
            return new_cap;
        }

        pub fn reserve(self: *Self, new_size: Size) !void {
            if (!isUnderMaxLoadPercentage(new_size, self.capacity()))
                try self.grow(capacityForSize(new_size));
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            if (self.metadata) |_| {
                self.initMetadatas();
                self.size = 0;
                self.available = 0;
            }
        }

        pub fn clearAndFree(self: *Self, allocator: *Allocator) void {
            self.deallocate(allocator);
            self.size = 0;
            self.available = 0;
        }

        pub fn count(self: *const Self) Size {
            return self.size;
        }

        fn header(self: *const Self) *Header {
            return @ptrCast(*Header, @ptrCast([*]Header, self.metadata.?) - 1);
        }

        fn entries(self: *const Self) [*]Entry {
            return self.header().entries;
        }

        pub fn capacity(self: *const Self) Size {
            if (self.metadata == null) return 0;

            return self.header().capacity;
        }

        pub fn iterator(self: *const Self) Iterator {
            return .{ .hm = self };
        }

        /// Insert an entry in the map. Assumes it is not already present.
        pub fn putNoClobber(self: *Self, key: K, value: V) !void {
            assert(!self.contains(key));
            try self.ensureCapacity(1);

            self.putAssumeCapacityNoClobber(key, value);
        }

        /// Insert an entry in the map. Assumes it is not already present,
        /// and that no allocation is needed.
        pub fn putAssumeCapacityNoClobber(self: *Self, key: K, value: V) void {
            assert(!self.contains(key));

            const hash = hashFn(key);
            const mask = self.capacity() - 1;
            var idx = hash & mask;

            var metadata = self.metadata.? + idx;
            while (metadata[0].isUsed()) {
                idx = (idx + 1) & mask;
                metadata = self.metadata.? + idx;
            }

            if (!metadata[0].isTombstone()) {
                assert(self.available > 0);
                self.available -= 1;
            }

            const fingerprint = Metadata.takeFingerprint(hash);
            metadata[0].fill(fingerprint);
            self.entries()[idx] = Entry{ .key = key, .value = value };

            self.size += 1;
        }

        /// Insert an entry if the associated key is not already present, otherwise update preexisting value.
        /// Returns true if the key was already present.
        pub fn put(self: *Self, key: K, value: V) !void {
            const result = try self.getOrPut(key);
            result.entry.value = value;
        }

        /// Get an optional pointer to the value associated with key, if present.
        pub fn get(self: *const Self, key: K) ?V {
            if (self.size == 0) {
                return null;
            }

            const hash = hashFn(key);
            const mask = self.capacity() - 1;
            const fingerprint = Metadata.takeFingerprint(hash);
            var idx = hash & mask;

            var metadata = self.metadata.? + idx;
            while (metadata[0].isUsed() or metadata[0].isTombstone()) {
                if (metadata[0].isUsed() and metadata[0].fingerprint == fingerprint) {
                    const entry = &self.entries()[idx];
                    if (eqlFn(entry.key, key)) {
                        return entry.value;
                    }
                }
                idx = (idx + 1) & mask;
                metadata = self.metadata.? + idx;
            }

            return null;
        }

        pub fn getOrPut(self: *Self, key: K) !GetOrPutResult {
            try self.ensureCapacity(1); // Should this go after the 'get' part, at the cost of complicating the code ? Would it even be an actual optimization ?

            const hash = hashFn(key);
            const mask = self.capacity() - 1;
            const fingerprint = Metadata.takeFingerprint(hash);
            var idx = hash & mask;

            var metadata = self.metadata.? + idx;
            while (metadata[0].isUsed() or metadata[0].isTombstone()) {
                if (metadata[0].isUsed() and metadata[0].fingerprint == fingerprint) {
                    const entry = &self.entries()[idx];
                    if (eqlFn(entry.key, key)) {
                        return GetOrPutResult{ .entry = entry, .found_existing = true };
                    }
                }
                idx = (idx + 1) & mask;
                metadata = self.metadata.? + idx;
            }

            metadata[0].fill(fingerprint);
            const entry = &self.entries()[idx];
            entry.* = .{ .key = key, .value = undefined };
            self.size += 1;
            self.available -= 1;

            return GetOrPutResult{ .entry = entry, .found_existing = false };
        }

        pub fn getOrPutValue(self: *Self, key: K, value: V) !*Entry {
            const res = try self.getOrPut(key);
            if (!res.found_existing) res.entry.value = value;
            return res.entry;
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
            const mask = self.capacity() - 1;
            const fingerprint = Metadata.takeFingerprint(hash);
            var idx = hash & mask;

            var metadata = self.metadata.? + idx;
            while (metadata[0].isUsed() or metadata[0].isTombstone()) {
                if (metadata[0].isUsed() and metadata[0].fingerprint == fingerprint) {
                    const entry = &self.entries()[idx];
                    if (eqlFn(entry.key, key)) {
                        metadata[0].remove();
                        entry.* = undefined;
                        self.size -= 1;
                        return true;
                    }
                }
                idx = (idx + 1) & mask;
                metadata = self.metadata.? + idx;
            }

            return false;
        }

        fn initMetadatas(self: *Self) void {
            @memset(@ptrCast([*]u8, self.metadata.?), 0, @sizeOf(Metadata) * self.capacity());
        }

        fn load(self: *const Self) Size {
            const max_load = (self.capacity() * MaxLoadPercentage) / 100;
            assert(max_load >= self.available);
            return @truncate(Size, max_load - self.available);
        }

        fn ensureCapacity(self: *Self, new_count: Size) !void {
            if (new_count > self.available) {
                const new_cap = if (self.capacity() == 0) MinimalCapacity else capacityForSize(self.load() + new_count);
                try self.grow(new_cap);
            }
        }

        fn grow(self: *Self, new_capacity: Size) !void {
            assert(new_capacity > self.capacity());
            assert(std.math.isPowerOfTwo(new_capacity));

            var map = Self{ .allocator = self.allocator };
            defer map.deinit();
            try map.allocate(new_capacity);
            map.initMetadatas();
            map.available = @truncate(u32, (new_capacity * MaxLoadPercentage) / 100);

            if (self.size != 0) {
                const old_capacity = self.capacity();
                var i: Size = 0;
                var metadata = self.metadata.?;
                var entr = self.entries();
                while (i < old_capacity) : (i += 1) {
                    if (metadata[i].isUsed()) {
                        const entry = &entr[i];
                        map.putAssumeCapacityNoClobber(entry.key, entry.value);
                    }
                }
            }

            self.size = 0;
            std.mem.swap(Self, self, &map);
        }

        fn allocate(self: *Self, new_capacity: Size) !void {
            const meta_size = @sizeOf(Header) + new_capacity * @sizeOf(Metadata);

            const alignment = @alignOf(Entry) - 1;
            const entries_size = @as(usize, new_capacity) * @sizeOf(Entry) + alignment;

            const total_size = meta_size + entries_size;

            const slice = try self.allocator.alignedAlloc(u8, @alignOf(Header), total_size);
            const ptr = @ptrToInt(slice.ptr);

            const metadata = ptr + @sizeOf(Header);
            var entry_ptr = ptr + meta_size;
            entry_ptr = (entry_ptr + alignment) & ~@as(usize, alignment);
            assert(entry_ptr + @as(usize, new_capacity) * @sizeOf(Entry) <= ptr + total_size);

            const hdr = @intToPtr(*Header, ptr);
            hdr.entries = @intToPtr([*]Entry, entry_ptr);
            hdr.capacity = new_capacity;
            self.metadata = @intToPtr([*]Metadata, metadata);
        }
    };
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "basic usage" {
    var map = AutoHashMap(u32, u32).init(std.testing.allocator);
    comptime assert(@sizeOf(@TypeOf(map)) == 24);
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
        expectEqual(map.get(i).?, i);
        sum += map.get(i).?;
    }
    expectEqual(total, sum);
}

test "reserve" {
    var map = AutoHashMap(u32, u32).init(std.testing.allocator);
    defer map.deinit();

    try map.reserve(9);
    expectEqual(map.capacity(), 16);
    try map.reserve(129);
    expectEqual(map.capacity(), 256);
    expectEqual(map.size, 0);
}

test "clearRetainingCapacity" {
    var map = AutoHashMap(u32, u32).init(std.testing.allocator);
    defer map.deinit();

    map.clearRetainingCapacity();

    try map.put(1, 1);
    expectEqual(map.get(1).?, 1);
    expectEqual(map.size, 1);

    const cap = map.capacity();
    expect(cap > 0);

    map.clearRetainingCapacity();
    map.clearRetainingCapacity();
    expectEqual(map.size, 0);
    expectEqual(map.capacity(), cap);
    expect(!map.contains(1));
}

// test "put and get with precomputed hash" {
//     var map = AutoHashMap(u32, u32).init(std.testing.allocator);
//     defer map.deinit();

//     var i: u32 = 0;
//     while (i < 8) : (i += 1) {
//         try map.putHashed(i, i * 3 + 1, hashu32(i));
//     }

//     i = 0;
//     while (i < 8) : (i += 1) {
//         expectEqual(map.get(i).?.*, i * 3 + 1);
//     }

//     i = 0;
//     while (i < 8) : (i += 1) {
//         expectEqual(map.getHashed(i, hashu32(i)).?.*, i * 3 + 1);
//     }
// }

// This test can only be run by removing the asserts checking hash consistency
// in putHashed and getHashed.
// test "put and get with long collision chain" {
//     var map = AutoHashMap(u32, u32).init(std.testing.allocator);
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
    var map = AutoHashMap(u32, u32).init(std.testing.allocator);
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
        expectEqual(map.get(i).?, i);
    }
}

test "reserve with existing elements" {
    var map = AutoHashMap(u32, u32).init(std.testing.allocator);
    defer map.deinit();

    try map.put(0, 0);
    expectEqual(map.size, 1);
    expectEqual(map.capacity(), @TypeOf(map).MinimalCapacity);

    try map.reserve(65);
    expectEqual(map.size, 1);
    expectEqual(map.capacity(), 128);
}

test "reserve satisfies max load factor" {
    var map = AutoHashMap(u32, u32).init(std.testing.allocator);
    defer map.deinit();

    try map.reserve(127);
    expectEqual(map.capacity(), 256);
}

test "remove" {
    var map = AutoHashMap(u32, u32).init(std.testing.allocator);
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
            expectEqual(map.get(i).?, i);
        }
    }
}

test "reverse removes" {
    var map = AutoHashMap(u32, u32).init(std.testing.allocator);
    defer map.deinit();

    var i: u32 = 0;
    while (i < 16) : (i += 1) {
        try map.putNoClobber(i, i);
    }

    i = 16;
    while (i > 0) : (i -= 1) {
        _ = map.remove(i - 1);
        expect(!map.contains(i - 1));
        var j: u32 = 0;
        while (j < i - 1) : (j += 1) {
            expectEqual(map.get(j).?, j);
        }
    }

    expectEqual(map.size, 0);
}

test "multiple removes on same metadata" {
    var map = AutoHashMap(u32, u32).init(std.testing.allocator);
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
            expectEqual(map.get(i).?, i);
        }
    }

    try map.put(15, 15);
    try map.put(13, 13);
    try map.put(14, 14);
    try map.put(7, 7);
    i = 0;
    while (i < 16) : (i += 1) {
        expectEqual(map.get(i).?, i);
    }
}

test "put and remove loop in random order" {
    var map = AutoHashMap(u32, u32).init(std.testing.allocator);
    defer map.deinit();

    var keys = std.ArrayList(u32).init(std.testing.allocator);
    defer keys.deinit();

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
    const Map = AutoHashMap(u32, u32);
    const n = 1000 * 1000;
    var map = Map.init(std.heap.page_allocator);
    defer map.deinit();

    var keys = std.ArrayList(u32).init(std.heap.page_allocator);
    defer keys.deinit();

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

test "put" {
    var map = AutoHashMap(u32, u32).init(std.testing.allocator);
    defer map.deinit();

    var i: u32 = 0;
    while (i < 16) : (i += 1) {
        _ = try map.put(i, i);
    }

    i = 0;
    while (i < 16) : (i += 1) {
        expectEqual(map.get(i).?, i);
    }

    i = 0;
    while (i < 16) : (i += 1) {
        try map.put(i, i * 16 + 1);
    }

    i = 0;
    while (i < 16) : (i += 1) {
        expectEqual(map.get(i).?, i * 16 + 1);
    }
}

test "getOrPut" {
    var map = AutoHashMap(u32, u32).init(std.testing.allocator);
    defer map.deinit();

    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        try map.put(i * 2, 2);
    }

    i = 0;
    while (i < 20) : (i += 1) {
        var n = try map.getOrPutValue(i, 1);
    }

    i = 0;
    var sum = i;
    while (i < 20) : (i += 1) {
        sum += map.get(i).?;
    }

    expectEqual(sum, 30);
}
