const builtin = @import("builtin");
const Builder = @import("std").build.Builder;
const tests = @import("tests.zig");

pub fn build(b: *Builder) void {
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addTest("hashmap.zig").step);

    const bench_exe = b.addExecutable("bench", "benchmarks/hashmap.zig");
    bench_exe.addPackagePath("bench", "deps/bench.zig");
    bench_exe.addPackagePath("sliceable_hashmap", "sliceable_hashmap.zig");
    bench_exe.addPackagePath("hashmap", "hashmap.zig");
    bench_exe.setBuildMode(.ReleaseFast);

    const bench_cmd = bench_exe.run();
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&bench_cmd.step);

    const martinus_exe = b.addExecutable("martinus", "benchmarks/martinus_map.zig");
    martinus_exe.override_lib_dir = b.option([]const u8, "override-lib-dir", "override lib dir");
    martinus_exe.addPackagePath("bench", "deps/bench.zig");
    martinus_exe.addPackagePath("sliceable_hashmap", "sliceable_hashmap.zig");
    martinus_exe.addPackagePath("hashmap", "hashmap.zig");
    martinus_exe.linkSystemLibrary("c");
    martinus_exe.setBuildMode(b.standardReleaseOptions());

    const martinus_cmd = martinus_exe.run();
    const martinus_step = b.step("martinus", "Run martinus map benchmarks");
    martinus_step.dependOn(&martinus_cmd.step);
}
