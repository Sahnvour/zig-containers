const builtin = @import("builtin");
const Builder = @import("std").build.Builder;
const tests = @import("tests.zig");

pub fn build(b: *Builder) void {
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addTest("hashmap.zig").step);

    const bench_exe = b.addExecutable("bench", "benchmarks/hashmap.zig");
    bench_exe.addPackagePath("bench", "deps/bench.zig");
    bench_exe.addPackagePath("wyhash", "deps/wyhash.zig");
    bench_exe.addPackagePath("hashmap", "hashmap.zig");
    bench_exe.setBuildMode(builtin.Mode.ReleaseFast);

    const bench_cmd = bench_exe.run();
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&bench_cmd.step);
}
