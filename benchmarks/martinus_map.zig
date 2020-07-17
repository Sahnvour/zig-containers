const std = @import("std");
const assert = std.debug.assert;
const time = std.time;
const warn = std.debug.warn;
const Timer = time.Timer;
const Wyhash = std.heap.Wyhash;

// Copy of std.rand.Sfc64 with a public next() function. The random API is
// slower than just calling next() and these benchmarks only require getting
// consecutive u64's.
pub const Sfc64 = struct {
    random: std.rand.Random,

    a: u64 = undefined,
    b: u64 = undefined,
    c: u64 = undefined,
    counter: u64 = undefined,

    const Rotation = 24;
    const RightShift = 11;
    const LeftShift = 3;

    pub fn init(init_s: u64) Sfc64 {
        var x = Sfc64{
            .random = std.rand.Random{ .fillFn = fill },
        };

        x.seed(init_s);
        return x;
    }

    pub fn next(self: *Sfc64) u64 {
        const tmp = self.a +% self.b +% self.counter;
        self.counter += 1;
        self.a = self.b ^ (self.b >> RightShift);
        self.b = self.c +% (self.c << LeftShift);
        self.c = std.math.rotl(u64, self.c, Rotation) +% tmp;
        return tmp;
    }

    pub fn seed(self: *Sfc64, init_s: u64) void {
        self.a = init_s;
        self.b = init_s;
        self.c = init_s;
        self.counter = 1;
        var i: u32 = 0;
        while (i < 12) : (i += 1) {
            _ = self.next();
        }
    }

    fn fill(r: *std.rand.Random, buf: []u8) void {
        const self = @fieldParentPtr(Sfc64, "random", r);

        var i: usize = 0;
        const aligned_len = buf.len - (buf.len & 7);

        // Complete 8 byte segments.
        while (i < aligned_len) : (i += 8) {
            var n = self.next();
            comptime var j: usize = 0;
            inline while (j < 8) : (j += 1) {
                buf[i + j] = @truncate(u8, n);
                n >>= 8;
            }
        }

        // Remaining. (cuts the stream)
        if (i != buf.len) {
            var n = self.next();
            while (i < buf.len) : (i += 1) {
                buf[i] = @truncate(u8, n);
                n >>= 8;
            }
        }
    }
};
const FlatHashMap = @import("hashmap");

//const wyhash64 = std.hash_map.getAutoHashFn(u64);
//const wyhashi32 = std.hash_map.getAutoHashFn(i32);

fn wyhash64(n: u64) u64 {
    return std.hash.Wyhash.hash(0, std.mem.asBytes(&n));
}

fn wyhashi32(n: i32) u64 {
    return std.hash.Wyhash.hash(0, std.mem.asBytes(&n));
}

fn wyhashstr(s: []const u8) u32 {
    return @truncate(u32, Wyhash.hash(0, s));
}

inline fn eqlu64(a: u64, b: u64) bool {
    return a == b;
}

inline fn eqli32(a: i32, b: i32) bool {
    return a == b;
}

fn eqlstr(a: []const u8, b: []const u8) bool {
    if (a.ptr == b.ptr and a.len == b.len) return true;
    if (a.len != b.len) return false;

    for (a) |c, i| {
        if (c != b[i]) return false;
    }

    return true;
}

fn iterate(allocator: anytype) void {
    const num_iters = 50000;

    var result: u64 = 0;
    var map = FlatHashMap.HashMap(u64, u64, wyhash64, eqlu64).init(allocator);
    defer map.deinit();

    const seed = 123;
    var rng = Sfc64.init(seed);

    warn("iterate while adding", .{});
    var timer = Timer.start() catch unreachable;
    var i: u64 = 0;
    while (i < num_iters) : (i += 1) {
        const key = rng.random.int(u64);
        _ = map.putOrUpdate(key, i) catch unreachable;
        var it = map.iterator();
        while (it.next()) |kv| {
            result += kv.value;
        }
    }
    var elapsed = timer.read();
    if (result != 20833333325000) std.os.abort();
    warn(" {d:.3}s\n", .{@intToFloat(f64, elapsed) / time.ns_per_s});

    rng.seed(seed);
    warn("iterate while removing", .{});
    timer.reset();
    i = 0;
    while (i < num_iters) : (i += 1) {
        _ = map.remove(rng.next());
        var it = map.iterator();
        while (it.next()) |kv| {
            result += kv.value;
        }
    }
    elapsed = timer.read();
    assert(map.count() == 0);
    if (result != 62498750000000) std.os.abort();
    warn(" {d:.3}s\n", .{@intToFloat(f64, elapsed) / time.ns_per_s});
}

fn insert(allocator: anytype) void {
    const num_iters = 100 * 1000 * 1000;

    var rng = Sfc64.init(213);

    warn("insert 100M int", .{});
    var timer = Timer.start() catch unreachable;
    var map = FlatHashMap.HashMap(i32, i32, wyhashi32, eqli32).init(allocator);

    var i: i32 = 0;
    while (i < num_iters) : (i += 1) {
        const key = @bitCast(i32, @truncate(u32, rng.next()));
        _ = map.putOrUpdate(key, 0) catch unreachable;
    }
    var elapsed = timer.read();
    std.testing.expectEqual(map.count(), 98841586);
    warn(" {d:.3}s\n", .{@intToFloat(f64, elapsed) / time.ns_per_s});

    warn("clear 100M int", .{});
    timer.reset();
    map.clear();
    elapsed = timer.read();
    warn(" {d:.3}s\n", .{@intToFloat(f64, elapsed) / time.ns_per_s});

    const state = rng;
    warn("reinsert 100M int", .{});
    timer.reset();
    i = 0;
    while (i < num_iters) : (i += 1) {
        const key = @bitCast(i32, @truncate(u32, rng.next()));
        _ = map.putOrUpdate(key, 0) catch unreachable;
    }
    elapsed = timer.read();
    std.testing.expectEqual(map.count(), 98843646);
    warn(" {d:.3}s\n", .{@intToFloat(f64, elapsed) / time.ns_per_s});

    warn("remove 100M int", .{});
    rng = state;
    timer.reset();
    i = 0;
    while (i < num_iters) : (i += 1) {
        const key = @bitCast(i32, @truncate(u32, rng.next()));
        _ = map.remove(key);
    }
    elapsed = timer.read();
    std.testing.expectEqual(map.count(), 0);
    warn(" {d:.3}s\n", .{@intToFloat(f64, elapsed) / time.ns_per_s});

    warn("deinit map", .{});
    timer.reset();
    map.deinit();
    elapsed = timer.read();
    warn(" {d:.3}s\n", .{@intToFloat(f64, elapsed) / time.ns_per_s});
}

fn randomDistinct(allocator: anytype) void {
    const num_iters = 50 * 1000 * 1000;
    const _5distinct = num_iters / 20;
    const _25distinct = num_iters / 4;
    const _50distinct = num_iters / 2;

    var rng = Sfc64.init(123);
    var checksum: i32 = 0;

    {
        warn("5% distinct", .{});
        var timer = Timer.start() catch unreachable;
        var map = FlatHashMap.HashMap(i32, i32, wyhashi32, eqli32).init(allocator);
        defer map.deinit();
        var i: u32 = 0;
        while (i < num_iters) : (i += 1) {
            const key = @intCast(i32, rng.random.uintLessThan(u32, _5distinct));
            var n = map.getOrPut(key, 0) catch unreachable;
            n.* += 1;
            checksum += n.*;
        }
        const elapsed = timer.read();
        std.testing.expectEqual(checksum, 549980587);
        warn(" {d:.3}s\n", .{@intToFloat(f64, elapsed) / time.ns_per_s});
    }

    {
        warn("25% distinct", .{});
        var timer = Timer.start() catch unreachable;
        var map = FlatHashMap.HashMap(i32, i32, wyhashi32, eqli32).init(allocator);
        defer map.deinit();
        checksum = 0;
        var i: u32 = 0;
        while (i < num_iters) : (i += 1) {
            const key = @intCast(i32, rng.random.uintLessThan(u32, _25distinct));
            var n = map.getOrPut(key, 0) catch unreachable;
            n.* += 1;
            checksum += n.*;
        }
        const elapsed = timer.read();
        std.testing.expectEqual(checksum, 149995671);
        warn(" {d:.3}s\n", .{@intToFloat(f64, elapsed) / time.ns_per_s});
    }

    {
        warn("50% distinct", .{});
        var timer = Timer.start() catch unreachable;
        var map = FlatHashMap.HashMap(i32, i32, wyhashi32, eqli32).init(allocator);
        defer map.deinit();
        checksum = 0;
        var i: u32 = 0;
        while (i < num_iters) : (i += 1) {
            const key = @intCast(i32, rng.random.uintLessThan(u32, _50distinct));
            var n = map.getOrPut(key, 0) catch unreachable;
            n.* += 1;
            checksum += n.*;
        }
        const elapsed = timer.read();
        std.testing.expectEqual(checksum, 99996161);
        warn(" {d:.3}s\n", .{@intToFloat(f64, elapsed) / time.ns_per_s});
    }

    {
        warn("100% distinct", .{});
        var timer = Timer.start() catch unreachable;
        var map = FlatHashMap.HashMap(i32, i32, wyhashi32, eqli32).init(allocator);
        defer map.deinit();
        checksum = 0;
        var i: u32 = 0;
        while (i < num_iters) : (i += 1) {
            const key = @intCast(i32, @truncate(u32, rng.next()));
            var n = map.getOrPut(key, 0) catch unreachable;
            n.* += 1;
            checksum += n.*;
        }
        const elapsed = timer.read();
        std.testing.expectEqual(checksum, 50291772);
        warn(" {d:.3}s\n", .{@intToFloat(f64, elapsed) / time.ns_per_s});
    }
}

fn randomInsertRemove(allocator: anytype) void {
    var rng = Sfc64.init(999);

    const masks = [_]u64{
        0b1001000000000000000000000000000000000000000100000000000000001000,
        0b1001000000000010001100000000000000000000000101000000000000001000,
        0b1001000000000110001100000000000000010000000101100000000000001001,
        0b1001000000000110001100000001000000010000000101110000000100101001,
        0b1101100000000110001100001001000000010000000101110001000100101001,
        0b1101100000001110001100001001001000010000100101110001000100101011,
    };
    const bit_count = [_]u32{ 4, 8, 12, 16, 20, 24 };
    const expected_final_sizes = [_]u32{ 7, 141, 2303, 37938, 606489, 9783443 };
    const max_n = 50 * 1000 * 1000;

    var rnd_bit_idx: u32 = 0;

    var map = FlatHashMap.HashMap(u64, u64, wyhash64, eqlu64).init(allocator);
    defer map.deinit();

    var i: u32 = 0;
    while (i < 6) : (i += 1) {
        const bit_mask = masks[i];
        var verifier: u64 = 0;
        warn("{} bits, {}M cycles", .{ bit_count[i], u32(max_n / 1000000) });

        var timer = Timer.start() catch unreachable;
        var j: u32 = 0;
        while (j < max_n) : (j += 1) {
            _ = map.getOrPut(rng.next() & bit_mask, j) catch unreachable;
            map.remove(rng.next() & bit_mask);
        }
        const elapsed = timer.read();
        std.testing.expectEqual(map.count(), expected_final_sizes[i]);
        warn(" {d:.3}s\n", .{@intToFloat(f64, elapsed) / time.ns_per_s});
    }
}

/// /!\ Leaks big amounts of memory !!
fn randomInsertRemoveStrings(allocator: anytype, max_n: u64, length: u64, mask: u32, expected: u64) void {
    var rng = Sfc64.init(123);
    var verifier: u64 = 0;

    warn("{} bytes ", .{length});

    var str = allocator.alloc(u8, length) catch unreachable;
    for (str) |*c| c.* = 'x';
    const idx32 = (length / 4) - 1;
    const strData32 = @ptrToInt(@ptrCast(*u32, @alignCast(4, &str[0]))) + idx32 * @sizeOf(u32);

    var timer = Timer.start() catch unreachable;
    var map = FlatHashMap.HashMap([]const u8, []const u8, wyhashstr, eqlstr).init(allocator);
    defer map.deinit();

    var i: u32 = 0;
    while (i < max_n) : (i += 1) {
        @intToPtr(*u32, strData32).* = @truncate(u32, rng.next()) & mask;

        // This leaks because we never release the strings we insert in the map.
        const new_str = allocator.alloc(u8, length) catch unreachable;
        for (str) |c, j| {
            new_str[j] = c;
        }

        _ = map.getOrPut(new_str, []const u8{}) catch unreachable;
        @intToPtr(*u32, strData32).* = @truncate(u32, rng.next()) & mask;
        if (map.remove(str)) verifier += 1;
    }
    const elapsed = timer.read();
    std.testing.expectEqual(expected, verifier);
    warn(" {d:.3}s\n", .{@intToFloat(f64, elapsed) / time.ns_per_s});
}

fn randomFind(allocator: anytype, num_rand: u32, mask: u64, num_insert: u64, find_per_insert: u64, expected: u64) void {
    const total = 4;
    const sequential = total - num_rand;

    const find_per_iter = find_per_insert * total;

    warn("{}% success, {x} ", .{ (sequential * 100) / total, mask });
    var rng = Sfc64.init(123);

    var num_found: u64 = 0;
    var insert_random = [_]bool{false} ** 4;
    for (insert_random[0..num_rand]) |*b| b.* = true;

    var other_rng = Sfc64.init(987654321);
    const state = other_rng;
    var find_rng = state;

    {
        var map = FlatHashMap.HashMap(u64, u64, wyhash64, eqlu64).init(allocator);
        var i: u64 = 0;
        var find_count: u64 = 0;

        var timer = Timer.start() catch unreachable;
        while (i < num_insert) {
            // insert NumTotal entries: some random, some sequential.
            std.rand.Random.shuffle(&rng.random, bool, insert_random[0..]);
            for (insert_random) |isRandomToInsert| {
                const val = other_rng.next();
                if (isRandomToInsert) {
                    _ = map.putOrUpdate(rng.next() & mask, 1) catch unreachable;
                } else {
                    _ = map.putOrUpdate(val & mask, 1) catch unreachable;
                }
                i += 1;
            }

            var j: u64 = 0;
            while (j < find_per_iter) : (j += 1) {
                find_count += 1;
                if (find_count > i) {
                    find_count = 0;
                    find_rng = state;
                }
                const key = find_rng.next() & mask;
                if (map.get(key)) |val| num_found += val.*;
            }
        }

        const elapsed = timer.read();
        std.testing.expectEqual(expected, num_found);
        warn(" {d:.3}ns\n", .{@intToFloat(f64, elapsed) / @intToFloat(f64, num_insert * find_per_insert)});
    }
}

pub fn main() void {
    const allocator = std.heap.c_allocator;
    //const allocator = std.heap.page_allocator;

    iterate(allocator);
    insert(allocator);
    randomDistinct(allocator);

    const lower32bit = 0x00000000FFFFFFFF;
    const upper32bit = 0xFFFFFFFF00000000;

    {
        const num_inserts = 2000;
        const find_per_insert = 500000;
        randomFind(allocator, 4, lower32bit, num_inserts, find_per_insert, 0);
        randomFind(allocator, 4, upper32bit, num_inserts, find_per_insert, 0);
        randomFind(allocator, 3, lower32bit, num_inserts, find_per_insert, 249194555);
        randomFind(allocator, 3, upper32bit, num_inserts, find_per_insert, 249194555);
        randomFind(allocator, 2, lower32bit, num_inserts, find_per_insert, 498389111);
        randomFind(allocator, 2, upper32bit, num_inserts, find_per_insert, 498389111);
        randomFind(allocator, 1, lower32bit, num_inserts, find_per_insert, 747583667);
        randomFind(allocator, 1, upper32bit, num_inserts, find_per_insert, 747583667);
        randomFind(allocator, 0, lower32bit, num_inserts, find_per_insert, 996778223);
        randomFind(allocator, 0, upper32bit, num_inserts, find_per_insert, 996778223);
    }

    // This is not very interesting to compare against the C++ version of the
    // benchmarks since std::string is very different from []const u8.
    // It would at least need to use a SSO-enabled Zig version.
    // randomInsertRemoveStrings(allocator, 20000000, 7, 0xfffff, 10188986);
    // randomInsertRemoveStrings(allocator, 20000000, 8, 0xfffff, 10191449);
    // randomInsertRemoveStrings(allocator, 20000000, 13, 0xfffff, 10190593);
    // randomInsertRemoveStrings(allocator, 12000000, 100, 0x7ffff, 6144655);
    // randomInsertRemoveStrings(allocator, 6000000, 1000, 0x1ffff, 3109782);
}
