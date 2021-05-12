# A set of containers for Zig

May turn useful, or not.

This is mostly a testbed for a few containers, especially `hashmap.zig` which ended up in the standard library.

# Benchmarks

A couple benchmarks are available (and can be tinkered with):
```shell
zig build bench -Drelease-fast
```
and more interestingly, a simplified implementation in Zig of [this one](https://github.com/martinus/map_benchmark/) which ended up in [gotta go fast](https://github.com/ziglang/gotta-go-fast/tree/master/benchmarks/std-hash-map).
```shell
zig build martinus -Drelease-fast
```

The `martinus` benchmark directly uses the standard library's hashmap, and supports `-Doverride-lib-dir=path/to/lib` for in-place testing.
