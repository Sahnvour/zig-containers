const std = @import("std");
const meta = std.meta;

const ArrayList = std.ArrayList;

const bench = @import("bench");
const benchmark = bench.benchmark;
const benchmarkArgs = bench.benchmarkArgs;
const clobberMemory = bench.clobberMemory;
const doNotOptimize = bench.doNotOptimize;
const Context = bench.Context;

const FlatHashMap = @import("hashmap");

var direct_allocator = std.heap.DirectAllocator.init();
var arena = std.heap.ArenaAllocator.init(&direct_allocator.allocator);
const allocator = &direct_allocator.allocator;

fn putHelper(map: var, key: var, value: var) void {
    const put_type = @typeOf(map.put);
    const return_type = @typeInfo(put_type).BoundFn.return_type.?;

    if (return_type == void) {
        map.put(key, value) catch unreachable;
    } else {
        _ = map.put(key, value) catch unreachable;
    }
}

fn removeHelper(map: var, key: var) void {
    const put_type = @typeOf(map.remove);
    const return_type = @typeInfo(put_type).BoundFn.return_type.?;

    if (return_type == void) {
        map.remove(key);
    } else {
        _ = map.remove(key);
    }
}

fn reserveHelper(map: var, size: u32) void {
    const Map = @typeOf(map);

    if (comptime meta.trait.hasFn("reserve")(Map)) {
        map.reserve(size) catch unreachable;
    } else {
        var i: u32 = 0;
        while (i < size) : (i += 1) {
            putHelper(&map, i, 0);
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
            std.rand.Random.shuffle(&rng.random, u32, keys.toSlice());

            while (ctx.run()) {
                var i: u32 = 0;
                while (i < n) : (i += 1) {
                    putHelper(&map, i, i);
                }

                i = 0;
                while (i < n) : (i += 1) {
                    const key = keys.toSlice()[i];
                    removeHelper(&map, i);
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

            for (keys.toSlice()) |key| {
                putHelper(&map, key, key);
            }

            while (ctx.run()) {
                var sum: u64 = 0;
                if (comptime meta.trait.hasFn("toSlice")(Map)) {
                    for (map.toSlice()) |kv| {
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

const sizes = []u32{ 5, 10, 25, 50, 100, 500, 1000, 15000, 50000, 100000, 1000 * 1000 };

const hash = comptime FlatHashMap.hashu32;
const eql = comptime FlatHashMap.eqlu32;

const Flat = FlatHashMap.HashMap(u32, u32, hash, eql);
const FlatWy = FlatHashMap.HashMap(u32, u32, wyhash, eql);
const Std = std.HashMap(u32, u32, hash, eql);

fn stdHashVsMurmur() void {
    const AutoStd = comptime insertSequential(std.AutoHashMap(u32, u32));
    const StdMurmur = comptime insertSequential(std.HashMap(u32, u32, hash, eql));
    benchmarkArgs("std hash", AutoStd, sizes);
    benchmarkArgs("murmur3 ", StdMurmur, sizes);
}

fn wyhash(x: u32) u32 {
    const slice = std.mem.asBytes(&x);
    return @truncate(u32, @import("wyhash").rng(x));
}

fn wyhashVsMurmur() void {
    const WyMap = comptime insertSequential(FlatHashMap.HashMap(u32, u32, wyhash, eql));
    const MurmurMap = comptime insertSequential(FlatHashMap.HashMap(u32, u32, hash, eql));
    benchmarkArgs("wyhash", WyMap, sizes);
    benchmarkArgs("murmur", MurmurMap, sizes);
}

const BenchFn = @typeOf(insertSequential);
fn compareFlatAndStd(comptime name: []const u8, comptime benchFn: BenchFn) void {
    benchmarkArgs(name ++ " Flat", comptime benchFn(Flat), sizes);
    benchmarkArgs(name ++ " Std ", comptime benchFn(Std), sizes);
}

fn compareMurmurAndWy(comptime name: []const u8, comptime benchFn: BenchFn) void {
    benchmarkArgs(name ++ " Wy ", comptime benchFn(FlatWy), sizes);
    benchmarkArgs(name ++ " Mm3", comptime benchFn(Flat), sizes);
}

fn stdHashMapVsFlatHashMap() void {
    benchmarkArgs("insert Flat", comptime insertSequential(Flat), sizes);
    benchmarkArgs("insert Std ", comptime insertSequential(Std), sizes);
}

const Module = @This();

pub fn main() void {
    // stdHashVsMurmur();
    // wyhashVsMurmur();
    compareFlatAndStd("insert", comptime insertSequential);
    // compareFlatAndStd("contains", comptime successfulContains);
    // compareFlatAndStd("!contains", comptime unsuccessfulContains);
    // compareFlatAndStd("eraseRandomOrder", comptime eraseRandomOrder);
    // compareFlatAndStd("iterate", comptime iterate);

    // compareMurmurAndWy("insert", comptime insertSequential);
    // compareMurmurAndWy("contains", comptime successfulContains);
    // compareMurmurAndWy("!contains", comptime unsuccessfulContains);
    // compareMurmurAndWy("eraseRandomOrder", comptime eraseRandomOrder);
    // compareMurmurAndWy("iterate", comptime iterate);
}
