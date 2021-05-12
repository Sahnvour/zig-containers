const std = @import("std");
const builtin = @import("builtin");
const meta = std.meta;

const TypeId = builtin.TypeId;

const ArrayList = std.ArrayList;

const bench = @import("bench");
const benchmark = bench.benchmark;
const benchmarkArgs = bench.benchmarkArgs;
const clobberMemory = bench.clobberMemory;
const doNotOptimize = bench.doNotOptimize;
const Context = bench.Context;

const HashMap = @import("hashmap").HashMap;
const SliceableHashMap = @import("sliceable_hashmap").HashMap;

var heap = std.heap.HeapAllocator.init();
var allocator = &heap.allocator;

pub fn eqlu32(x: u32, y: u32) bool {
    return x == y;
}

fn putHelper(map: anytype, key: anytype, value: anytype) void {
    const put_type = @TypeOf(map.put);
    const return_type = @typeInfo(put_type).BoundFn.return_type.?;
    const payload_type = @typeInfo(return_type).ErrorUnion.payload;

    if (payload_type == void) {
        map.put(key, value) catch unreachable;
    } else {
        _ = map.put(key, value) catch unreachable;
    }
}

fn removeHelper(map: anytype, key: anytype) void {
    doNotOptimize(map.remove(key));
}

fn reserveHelper(map: anytype, size: u32) void {
    const Map = @TypeOf(map);

    if (comptime meta.trait.hasFn("reserve")(Map)) {
        map.reserve(size) catch unreachable;
    } else {
        var i: u32 = 0;
        while (i < size) : (i += 1) {
            putHelper(map, i, 0);
        }
        map.clear();
    }
}

const MapBenchFn = fn (c: *Context, n: u32) void;

/// Insert sequential integers from 0 to n-1.
fn insertSequential(comptime Map: type) MapBenchFn {
    const Closure = struct {
        pub fn bench(ctx: *Context, n: u32) void {
            while (ctx.runExplicitTiming()) {
                var map = Map.init(allocator);
                defer map.deinit();

                ctx.startTimer();
                defer ctx.stopTimer();

                var i: u32 = 0;
                while (i < n) : (i += 1) {
                    putHelper(&map, i, i);
                }
                clobberMemory();
            }
        }
    };

    return Closure.bench;
}

/// Insert sequential integers from 0 to n-1, and sequentially check if the map contains them.
fn successfulContains(comptime Map: type) MapBenchFn {
    const Closure = struct {
        pub fn bench(ctx: *Context, n: u32) void {
            var map = Map.init(allocator);
            defer map.deinit();

            {
                var i: u32 = 0;
                while (i < n) : (i += 1) {
                    putHelper(&map, i, i);
                }
            }

            while (ctx.run()) {
                var i: u32 = n;
                while (i > 0) : (i -= 1) {
                    doNotOptimize(map.contains(i));
                }
            }
        }
    };

    return Closure.bench;
}

/// Insert sequential integers from 0 to n-1, and check if the map contains sequential integers from n to 2n.
fn unsuccessfulContains(comptime Map: type) MapBenchFn {
    const Closure = struct {
        pub fn bench(ctx: *Context, n: u32) void {
            var map = Map.init(allocator);
            defer map.deinit();

            {
                var i: u32 = 0;
                while (i < n) : (i += 1) {
                    putHelper(&map, i, i);
                }
            }

            while (ctx.run()) {
                var i: u32 = n;
                while (i < 2 * n) : (i += 1) {
                    doNotOptimize(map.contains(i));
                }
            }
        }
    };

    return Closure.bench;
}

/// Insert sequential integers from 0 to n-1 and remove them in random order.
fn eraseRandomOrder(comptime Map: type) MapBenchFn {
    const Closure = struct {
        pub fn bench(ctx: *Context, n: u32) void {
            var map = Map.init(allocator);
            defer map.deinit();

            var keys = ArrayList(u32).init(allocator);
            {
                var i: u32 = 0;
                while (i < n) : (i += 1) {
                    keys.append(i) catch unreachable;
                }
            }

            var rng = std.rand.DefaultPrng.init(0);
            std.rand.Random.shuffle(&rng.random, u32, keys.items);

            while (ctx.runExplicitTiming()) {
                var i: u32 = 0;
                while (i < n) : (i += 1) {
                    putHelper(&map, i, i);
                }

                ctx.startTimer();
                defer ctx.stopTimer();
                for (keys.items) |key| {
                    removeHelper(&map, key);
                }
            }
        }
    };

    return Closure.bench;
}

/// Insert n integers and iterate through to sum them up.
fn iterate(comptime Map: type) MapBenchFn {
    const Closure = struct {
        pub fn bench(ctx: *Context, n: u32) void {
            var map = Map.init(allocator);
            defer map.deinit();

            var rng = std.rand.DefaultPrng.init(0);
            var keys = ArrayList(u32).init(allocator);
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                keys.append(i) catch unreachable;
            }

            for (keys.items) |key| {
                putHelper(&map, key, key);
            }

            while (ctx.run()) {
                var sum: u64 = 0;
                if (comptime meta.trait.hasFn("toSlice")(Map)) {
                    for (map.items) |kv| {
                        sum += kv.value;
                    }
                } else {
                    var it = map.iterator();
                    while (it.next()) |kv| {
                        sum += kv.value;
                    }
                }

                doNotOptimize(sum);
            }
        }
    };

    return Closure.bench;
}

const sizes = [_]u32{ 5, 25, 100, 500, 1000, 15000, 50000 };

const Flat = HashMap(u32, u32, wyhash, eqlu32, 80);
//const Sliceable = SliceableHashMap(u32, u32, wyhash, eqlu32);
const Std = std.HashMap(u32, u32, wyhash, eqlu32, 80);

const wyhash = std.hash_map.getAutoHashFn(u32);
const wyhash32 = struct {
    fn hash(key: u32) u64 {
        var hasher = std.hash.Wyhash.init(0);
        std.hash.autoHash(&hasher, key);
        return hasher.final();
    }
}.hash;

const BenchFn = @TypeOf(insertSequential);
fn compareFlatAndStd(comptime name: []const u8, comptime benchFn: BenchFn) void {
    //benchmarkArgs(name ++ " Flat", comptime benchFn(Flat), &sizes);
    //benchmarkArgs(name ++ " Slic", comptime benchFn(Sliceable), &sizes);
    benchmarkArgs(name ++ " Std ", comptime benchFn(Std), &sizes);
}

// TODO
// - use better allocators

pub fn main() void {
    compareFlatAndStd("insert", comptime insertSequential);
    compareFlatAndStd("contains", comptime successfulContains);
    compareFlatAndStd("!contains", comptime unsuccessfulContains);
    compareFlatAndStd("eraseRandomOrder", comptime eraseRandomOrder);
    compareFlatAndStd("iterate", comptime iterate);
}
