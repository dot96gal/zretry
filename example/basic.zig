const std = @import("std");
const zretry = @import("zretry");

var callCount: u32 = 0;
var failsLeft: u32 = 0;

fn flakyOperation() error{ Retry, InvalidInput }!u32 {
    callCount += 1;
    std.debug.print("attempt {d}...\n", .{callCount});

    if (failsLeft > 0) {
        failsLeft -= 1;
        std.debug.print("  transient error, retrying\n", .{});
        return error.Retry;
    }

    std.debug.print("  success\n", .{});
    return 42;
}

pub fn main(env: std.process.Init) !void {
    const io = env.io;

    // デフォルト設定（maxAttempts=3、指数バックオフ+ジッター）
    // 2回失敗 → 3回目で成功
    std.debug.print("--- default config ---\n", .{});
    callCount = 0;
    failsLeft = 2;
    const result = zretry.retry(io, .{}, flakyOperation, .{}) catch |err| switch (err) {
        error.RetriesExhausted => {
            std.debug.print("max retries reached\n", .{});
            return err;
        },
        error.InvalidInput => {
            std.debug.print("invalid input\n", .{});
            return err;
        },
        else => return err,
    };
    std.debug.print("result: {d}\n", .{result});

    // カスタム設定（maxAttempts=5）
    // 4回失敗 → 5回目で成功。デフォルト設定では RetriesExhausted になるケース。
    std.debug.print("\n--- custom config (maxAttempts=5) ---\n", .{});
    callCount = 0;
    failsLeft = 4;
    const config = zretry.Config{
        .maxAttempts = 5,
        .strategy = .{ .exponentialJitter = .{
            .baseDelayMs = 100,
            .maxDelayMs = 5_000,
        } },
    };
    const result2 = zretry.retry(io, config, flakyOperation, .{}) catch |err| switch (err) {
        error.RetriesExhausted => {
            std.debug.print("max retries reached\n", .{});
            return err;
        },
        error.InvalidInput => {
            std.debug.print("invalid input\n", .{});
            return err;
        },
        else => return err,
    };
    std.debug.print("result: {d}\n", .{result2});
}
