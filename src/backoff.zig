/// 指数関数バックオフ + Full Jitter の設定を表す構造体。
/// `Strategy.exponentialJitter` に渡してバックオフの挙動を調整するために利用する。
pub const ExponentialJitterConfig = struct {
    /// リトライ間隔の基準値（ミリ秒）。
    baseDelayMs: u64 = 100,
    /// リトライ間隔の上限（ミリ秒）。
    maxDelayMs: u64 = 30_000,
    /// 試行ごとに間隔を拡大する乗数。
    multiplier: f64 = 2.0,
    /// ランダム幅の割合（0.0〜1.0）。0.0 にすると遅延が決定的になる。
    jitterFactor: f64 = 0.5,
};

/// バックオフアルゴリズムを選択するための union。
/// `Config.strategy` に設定して `retry` に渡すために利用する。
pub const Strategy = union(enum) {
    /// 指数関数バックオフ + Full Jitter。
    exponentialJitter: ExponentialJitterConfig,
};
