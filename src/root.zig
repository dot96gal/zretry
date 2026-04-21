pub const Config = @import("retry.zig").Config;
pub const Strategy = @import("backoff.zig").Strategy;
pub const ExponentialJitterConfig = @import("backoff.zig").ExponentialJitterConfig;
pub const retry = @import("retry.zig").retry;
pub const RetriesExhausted = error.RetriesExhausted;

test {
    _ = @import("backoff.zig");
    _ = @import("retry.zig");
}
