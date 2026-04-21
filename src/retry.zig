const std = @import("std");
const backoff = @import("backoff.zig");

/// リトライ動作を制御する設定を表す構造体。
/// `retry` に渡してリトライ回数とバックオフアルゴリズムを指定するために利用する。
/// `.{}` とすることでデフォルト設定（最大3回、指数バックオフ+ジッター）が使える。
pub const Config = struct {
    /// リトライを含む最大試行回数。1 を指定すると初回失敗で即 `error.RetriesExhausted` を返す。
    maxAttempts: u32 = 3,
    /// 使用するバックオフアルゴリズム。
    strategy: backoff.Strategy = .{ .exponentialJitter = .{} },
};

fn PayloadType(comptime F: type) type {
    const R = @typeInfo(F).@"fn".return_type.?;
    return @typeInfo(R).error_union.payload;
}

// cap = min(maxDelayMs, baseDelayMs * multiplier^attempt)
// delayMs = random(0, cap * jitterFactor) + cap * (1 - jitterFactor)
fn nextDelayMs(strategy: backoff.Strategy, attempt: u32, rng: std.Random) u64 {
    switch (strategy) {
        .exponentialJitter => |cfg| {
            if (cfg.baseDelayMs == 0) return 0;

            const exp = std.math.pow(f64, cfg.multiplier, @floatFromInt(attempt));
            const rawCap = @as(f64, @floatFromInt(cfg.baseDelayMs)) * exp;
            const cap = @min(@as(f64, @floatFromInt(cfg.maxDelayMs)), rawCap);

            const jitterRange = cap * cfg.jitterFactor;
            const jitter = rng.float(f64) * jitterRange;
            const base = cap * (1.0 - cfg.jitterFactor);
            const total = jitter + base;

            return @floor(total);
        },
    }
}

/// バックオフ付きでリトライを実行する関数。
/// `func` が `error.Retry` を返したときのみリトライし、それ以外のエラーは即座に呼び出し元に伝播するために利用する。
/// `config.maxAttempts` 回すべて `error.Retry` だった場合は `error.RetriesExhausted` を返す。
/// `func` はエラーユニオンを返す関数でなければならない（例: `fn () error{Retry}!void`）。
pub fn retry(
    io: std.Io,
    config: Config,
    comptime func: anytype,
    args: anytype,
) anyerror!PayloadType(@TypeOf(func)) {
    comptime {
        const returnType = @typeInfo(@TypeOf(func)).@"fn".return_type.?;
        if (@typeInfo(returnType) != .error_union) {
            @compileError("func must return an error union (e.g. error{Retry}!void)");
        }
    }

    var seedBuf: [8]u8 = undefined;
    io.random(&seedBuf);
    var prng = std.Random.DefaultPrng.init(std.mem.readInt(u64, &seedBuf, .little));

    var attempt: u32 = 0;
    while (true) {
        const result = @call(.auto, func, args);
        if (result) |value| {
            return value;
        } else |err| {
            if (err != error.Retry) return err;
            if (attempt < config.maxAttempts - 1) {
                const delayMs = nextDelayMs(config.strategy, attempt, prng.random());
                if (delayMs > 0) {
                    const ns: i96 = @intCast(delayMs * std.time.ns_per_ms);
                    try std.Io.sleep(io, std.Io.Duration.fromNanoseconds(ns), .awake);
                }
                attempt += 1;
            } else {
                return error.RetriesExhausted;
            }
        }
    }
}

test "jitterFactor=0.0 returns cap deterministically" {
    var prng = std.Random.DefaultPrng.init(0);
    const cases = [_]struct {
        attempt: u32,
        cfg: backoff.ExponentialJitterConfig,
        expected: u64,
    }{
        .{ .attempt = 0, .cfg = .{ .baseDelayMs = 100, .multiplier = 2.0, .maxDelayMs = 30_000, .jitterFactor = 0.0 }, .expected = 100 },
        .{ .attempt = 1, .cfg = .{ .baseDelayMs = 100, .multiplier = 2.0, .maxDelayMs = 30_000, .jitterFactor = 0.0 }, .expected = 200 },
        .{ .attempt = 2, .cfg = .{ .baseDelayMs = 100, .multiplier = 2.0, .maxDelayMs = 30_000, .jitterFactor = 0.0 }, .expected = 400 },
    };
    for (cases) |tc| {
        const delay = nextDelayMs(.{ .exponentialJitter = tc.cfg }, tc.attempt, prng.random());
        try std.testing.expectEqual(tc.expected, delay);
    }
}

test "delay is clamped to maxDelayMs" {
    var prng = std.Random.DefaultPrng.init(0);
    const cfg = backoff.ExponentialJitterConfig{
        .baseDelayMs = 100,
        .maxDelayMs = 30_000,
        .multiplier = 2.0,
        .jitterFactor = 0.0,
    };
    const delay = nextDelayMs(.{ .exponentialJitter = cfg }, 20, prng.random());
    try std.testing.expectEqual(@as(u64, 30_000), delay);
}

test "baseDelayMs=0 returns 0" {
    var prng = std.Random.DefaultPrng.init(0);
    const cfg = backoff.ExponentialJitterConfig{ .baseDelayMs = 0 };
    const delay = nextDelayMs(.{ .exponentialJitter = cfg }, 0, prng.random());
    try std.testing.expectEqual(@as(u64, 0), delay);
}

test "delay is within expected range with jitter" {
    var prng = std.Random.DefaultPrng.init(42);
    const cfg = backoff.ExponentialJitterConfig{
        .baseDelayMs = 100,
        .maxDelayMs = 30_000,
        .multiplier = 2.0,
        .jitterFactor = 0.5,
    };
    // attempt=0: cap=100, range=[50, 100]
    const delay = nextDelayMs(.{ .exponentialJitter = cfg }, 0, prng.random());
    try std.testing.expect(delay >= 50 and delay <= 100);
}

const TestState = struct {
    var callCount: u32 = 0;
    var failsRemaining: u32 = 0;
    var otherErrorOnEmpty: bool = false;

    fn reset(fails: u32, otherError: bool) void {
        callCount = 0;
        failsRemaining = fails;
        otherErrorOnEmpty = otherError;
    }
};

fn testFunc() error{ Retry, Other }!void {
    TestState.callCount += 1;
    if (TestState.failsRemaining > 0) {
        TestState.failsRemaining -= 1;
        return error.Retry;
    }
    if (TestState.otherErrorOnEmpty) {
        return error.Other;
    }
}

const NO_SLEEP_CONFIG = Config{
    .maxAttempts = 3,
    .strategy = .{ .exponentialJitter = .{ .baseDelayMs = 0 } },
};

test "succeeds on first attempt" {
    TestState.reset(0, false);
    try retry(std.testing.io, NO_SLEEP_CONFIG, testFunc, .{});
    try std.testing.expectEqual(@as(u32, 1), TestState.callCount);
}

test "succeeds after N retries" {
    TestState.reset(2, false);
    try retry(std.testing.io, NO_SLEEP_CONFIG, testFunc, .{});
    try std.testing.expectEqual(@as(u32, 3), TestState.callCount);
}

test "non-Retry error propagates immediately on first attempt" {
    TestState.reset(0, true);
    const result = retry(std.testing.io, NO_SLEEP_CONFIG, testFunc, .{});
    try std.testing.expectError(error.Other, result);
    try std.testing.expectEqual(@as(u32, 1), TestState.callCount);
}

test "non-Retry error propagates after N retries" {
    TestState.reset(2, true);
    const result = retry(std.testing.io, NO_SLEEP_CONFIG, testFunc, .{});
    try std.testing.expectError(error.Other, result);
    try std.testing.expectEqual(@as(u32, 3), TestState.callCount);
}

test "returns RetriesExhausted when all attempts fail" {
    TestState.reset(99, false);
    const result = retry(std.testing.io, NO_SLEEP_CONFIG, testFunc, .{});
    try std.testing.expectError(error.RetriesExhausted, result);
    try std.testing.expectEqual(@as(u32, 3), TestState.callCount);
}

test "maxAttempts=1 returns RetriesExhausted immediately without sleep" {
    TestState.reset(99, false);
    const cfg = Config{
        .maxAttempts = 1,
        .strategy = .{ .exponentialJitter = .{ .baseDelayMs = 0 } },
    };
    const result = retry(std.testing.io, cfg, testFunc, .{});
    try std.testing.expectError(error.RetriesExhausted, result);
    try std.testing.expectEqual(@as(u32, 1), TestState.callCount);
}
