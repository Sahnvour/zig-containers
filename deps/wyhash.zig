// Author: Jan Halsema
// Zig implementation of wyhash

const std = @import("std");
const mem = std.mem;

const primes = []u64{
    0xa0761d6478bd642f, 0xe7037ed1a0b428db,
    0x8ebc6af09c88c6e3, 0x589965cc75374cc3,
    0x1d8e4e27c47d124f, 0xeb44accab455d165,
};

fn read_bytes(comptime bytes: u8, data: []const u8) u64 {
    return mem.readVarInt(u64, data[0..bytes], @import("builtin").endian);
}

fn read_8bytes_swapped(data: []const u8) u64 {
    return (read_bytes(4, data) << 32 | read_bytes(4, data[4..]));
}

fn mum(a: u64, b: u64) u64 {
    var r: u128 = @intCast(u128, a) * @intCast(u128, b);
    r = (r >> 64) ^ r;
    return @truncate(u64, r);
}

pub fn hash(key: []const u8, initial_seed: u64) u64 {
    const len = key.len;

    var seed = initial_seed;

    var i: usize = 0;
    while (i + 32 <= key.len) : (i += 32) {
        seed = mum(seed                              ^ primes[0],
                   mum(read_bytes(8, key[i      ..]) ^ primes[1],
                       read_bytes(8, key[i +  8 ..]) ^ primes[2]) ^
                   mum(read_bytes(8, key[i + 16 ..]) ^ primes[3],
                       read_bytes(8, key[i + 24 ..]) ^ primes[4]));
    }
    seed ^= primes[0];

    const rem_len   = @truncate(u5, len);
    if (rem_len != 0) {
        const rem_bits  = @truncate(u3, rem_len % 8);
        const rem_bytes = @truncate(u2, (len - 1) / 8);
        const rem_key   = key[i + @intCast(usize, rem_bytes) * 8 ..];

        const rest = switch (rem_bits) {
            0 => read_8bytes_swapped(rem_key),
            1 => read_bytes(1, rem_key),
            2 => read_bytes(2, rem_key),
            3 => read_bytes(2, rem_key) <<  8 | read_bytes(1, rem_key[2..]),
            4 => read_bytes(4, rem_key),
            5 => read_bytes(4, rem_key) <<  8 | read_bytes(1, rem_key[4..]),
            6 => read_bytes(4, rem_key) << 16 | read_bytes(2, rem_key[4..]),
            7 => read_bytes(4, rem_key) << 24 | read_bytes(2, rem_key[4..]) << 8 | read_bytes(1, rem_key[6..]),
        } ^ primes[@intCast(usize, rem_bytes) + 1];

        seed = switch (rem_bytes) {
            0 => mum(seed, rest),
            1 => mum(read_8bytes_swapped(key[i      ..]) ^ seed, rest),
            2 => mum(read_8bytes_swapped(key[i      ..]) ^ seed,
                     read_8bytes_swapped(key[i +  8 ..]) ^ primes[2]) ^
                 mum(seed, rest),
            3 => mum(read_8bytes_swapped(key[i      ..]) ^ seed,
                     read_8bytes_swapped(key[i +  8 ..]) ^ primes[2]) ^
                 mum(read_8bytes_swapped(key[i + 16 ..]) ^ seed, rest),
        };
    }

    return mum(seed, len ^ primes[5]);
}

pub fn rng(initial_seed: u64) u64 {
    var seed = initial_seed +% primes[0];
    return mum(seed ^ primes[1], seed);
}

