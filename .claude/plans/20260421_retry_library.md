# zretry 実装計画

作成日: 2026-04-21
対象バージョン: Zig 0.16.0

---

## 概要

Zig 向けのリトライ処理ライブラリ。
- バックオフアルゴリズムを `union(enum)` で切り替え可能にする
- 最初の実装は **指数関数バックオフ + ジッター（Full Jitter）** のみ
- ユーザが任意の関数を渡してリトライ実行できる
- **`error.Retry` をリトライのシグナルとして使用する**。ユーザの関数が `error.Retry` を返したときのみリトライし、それ以外のエラーは即座に伝播する。リトライ判断・リトライ時の処理（ロギング等）はユーザの関数の責務とし、ライブラリはバックオフ制御のみを担う

---

## ファイル構成

```
src/
  root.zig      パブリック API の再エクスポート
  retry.zig     retry() 関数の実装
  backoff.zig   Strategy union + アルゴリズム計算
```

---

## 型設計

### `backoff.zig`

```zig
pub const ExponentialJitterConfig = struct {
    baseDelayMs:  u64 = 100,
    maxDelayMs:   u64 = 30_000,
    multiplier:   f64 = 2.0,
    jitterFactor: f64 = 0.5,   // 0.0〜1.0
};

pub const Strategy = union(enum) {
    exponentialJitter: ExponentialJitterConfig,
};

/// ライブラリ内部用。root.zig では再エクスポートしない。
pub fn nextDelayMs(strategy: Strategy, attempt: u32, rng: std.Random) u64 { ... }
```

#### Full Jitter の計算式

```
cap     = min(maxDelayMs, baseDelayMs * multiplier^attempt)
delayMs = random(0, cap * jitterFactor) + cap * (1 - jitterFactor)
```

乱数は引数の `std.Random` から取得する。`retry()` 側で `io.random(&buf)` を呼び出してシードを生成し、`std.Random.DefaultPrng` を初期化して渡す。

```zig
// retry.zig 内
var seedBuf: [8]u8 = undefined;
io.random(&seedBuf);
var prng = std.Random.DefaultPrng.init(std.mem.readInt(u64, &seedBuf, .little));
const delayMs = backoff.nextDelayMs(config.strategy, attempt, prng.random());
```

### `retry.zig`

```zig
pub const Config = struct {
    maxAttempts: u32      = 3,
    strategy:    Strategy = .{ .exponentialJitter = .{} },
};

/// func と args を受け取り、error.Retry が返された場合にリトライする。
/// error.Retry 以外のエラーは即座に伝播する。
/// maxAttempts 回すべて error.Retry だった場合は error.RetriesExhausted を返す。
///
/// func は必ずエラーユニオンを返す関数であること。
///   例: fn () error{Retry}!void
///       fn ([]const u8) error{Retry, InvalidInput}![]u8
pub fn retry(
    io:            std.Io,
    config:        Config,
    comptime func: anytype,
    args:          anytype,
) anyerror!PayloadType(@TypeOf(func)) { ... }

/// func の戻り値型からペイロード型（エラーでない側）を取り出す
fn PayloadType(comptime F: type) type {
    const R = @typeInfo(F).@"fn".return_type.?;
    return @typeInfo(R).error_union.payload;
}
```

#### comptime バリデーション

`retry()` の先頭で `func` の返値型を検査し、エラーユニオンでない場合は即座にコンパイルエラーを出す。

```zig
comptime {
    const returnType = @typeInfo(@TypeOf(func)).@"fn".return_type.?;
    if (@typeInfo(returnType) != .error_union) {
        @compileError("func must return an error union (e.g. error{Retry}!void)");
    }
}
```

これにより:
- `fn () void` を渡した場合 → **コンパイルエラー**
- `fn () error{Retry}!void` を渡した場合 → OK
- `fn ([]const u8) error{Retry, InvalidInput}![]u8` を渡した場合 → OK

### `root.zig`

```zig
pub const Config                  = @import("retry.zig").Config;
pub const Strategy                = @import("backoff.zig").Strategy;
pub const ExponentialJitterConfig = @import("backoff.zig").ExponentialJitterConfig;
pub const retry                   = @import("retry.zig").retry;
pub const RetriesExhausted        = error.RetriesExhausted;
// backoff.nextDelayMs は再エクスポートしない（内部実装）
```

---

## retry() の動作フロー

```
io.random(&seedBuf) → prng = DefaultPrng.init(seed)
attempt = 0
loop:
  result = func(args...)
  if ok  → return result
  if err != error.Retry → return err  ← error.Retry 以外は即伝播
  if attempt < maxAttempts - 1:
    delayMs = backoff.nextDelayMs(strategy, attempt, prng.random())
    if delayMs > 0:
      std.time.sleep(delayMs * std.time.ns_per_ms)
    attempt += 1
  else:
    return error.RetriesExhausted  ← maxAttempts 到達
```

---

## 使用例（利用者目線）

### デフォルト設定（最もシンプル）

```zig
const zretry = @import("zretry");

fn fetchData(url: []const u8) error{ Retry, InvalidInput }![]u8 {
    return httpGet(url) catch |err| switch (err) {
        error.Timeout => {
            std.log.warn("timeout, retrying...", .{});
            return error.Retry;       // リトライしたい → error.Retry を返す
        },
        error.InvalidInput => return error.InvalidInput,  // リトライしない
    };
}

pub fn main(env: std.process.Init) !void {
    // .{} だけで maxAttempts=3、指数バックオフ+ジッターのデフォルト設定が使える
    const data = zretry.retry(env.io, .{}, fetchData, .{"https://example.com"}) catch |err| switch (err) {
        error.RetriesExhausted => {
            std.log.err("max retries reached", .{});
            return err;
        },
        error.InvalidInput => {
            std.log.err("invalid input, will not retry", .{});
            return err;
        },
        else => return err,
    };
    defer env.gpa.free(data);
}
```

### カスタム設定

```zig
pub fn main(env: std.process.Init) !void {
    const config = zretry.Config{
        .maxAttempts = 5,
        .strategy = .{ .exponentialJitter = .{
            .baseDelayMs = 200,
            .maxDelayMs  = 10_000,
        }},
    };

    const data = zretry.retry(env.io, config, fetchData, .{"https://example.com"}) catch |err| switch (err) {
        error.RetriesExhausted => {
            std.log.err("max retries reached", .{});
            return err;
        },
        error.InvalidInput => {
            std.log.err("invalid input, will not retry", .{});
            return err;
        },
        else => return err,
    };
    defer env.gpa.free(data);
}
```

---

## テスト方針

### `backoff.zig`

`nextDelayMs` は `std.Random` を受け取るため、固定シードで決定的にテストできる。

```zig
var prng = std.Random.DefaultPrng.init(@as(u64, std.testing.random_seed));
const delay = backoff.nextDelayMs(strategy, 0, prng.random());
try std.testing.expectEqual(expected_ms, delay);  // 等値チェック可能
```

検証項目:
- **固定シードのテーブルドリブン**: `(attempt, config, expected_ms)` のペアで `expectEqual` を検証
- **`jitterFactor = 0.0` のとき delay = cap**: ランダム要素がゼロになるためシード不要で決定的。cap の計算式を直接確認できる
- **`attempt` が十分大きいとき delay が `maxDelayMs` に張り付くこと**: cap の上限クランプを確認
- **`baseDelayMs = 0` のとき delay = 0**: エッジケース

### `retry.zig`

`std.Io` を要するため `std.testing.io` を使用する。スリープは `baseDelayMs = 0` + `if (delayMs > 0)` ガードで回避される。

検証項目:
- 1回目で成功 → エラーなし、呼び出し回数 = 1
- N回 `error.Retry` 後に成功 → エラーなし、呼び出し回数 = N+1
- `error.Retry` 以外のエラー（1回目）→ 即座に伝播、呼び出し回数 = 1
- N回 `error.Retry` 後に `error.Retry` 以外のエラー → 即座に伝播、呼び出し回数 = N+1
- `maxAttempts` 回すべて `error.Retry` → `error.RetriesExhausted` を返す、呼び出し回数 = `maxAttempts`
- `maxAttempts = 1` のとき1回目が `error.Retry` → 待機なしで即 `error.RetriesExhausted`

---

## 設計メモ

### `retry()` の戻り値型に `anyerror` を採用した理由

**課題**: `func` が `error{Retry, InvalidInput}![]u8` を返す場合、`retry()` は内部で `error.Retry` を消費するが、型システム上は `error.Retry` が戻り値型に残る。

**Zig 0.16.0 の制約**: `@Type` が廃止され、エラー集合を生成する `@ErrorSet` 相当のビルトインも存在しない。エラー集合から特定のエラーを除去する comptime 型操作は実現困難。

**検討した案**:

| 案 | 内容 | 問題点 |
|---|---|---|
| A | `error.Retry` を戻り値型に残す | 呼び出し元で `unreachable` が必要、型シグニチャに混入 |
| B | `anyerror` を返す | 型安全は下がるが実害なし |
| C | `func` の設計を変えラップ型で表現 | API が複雑になる |

**決定: 案B（`anyerror`）**

呼び出し元の関心事は「`error.RetriesExhausted` への対処」と「`func` 固有のエラーへの対処」の2つのみ。`error.Retry` は `retry()` の内部プロトコルであり呼び出し元には無関係。ユーザは自分の関数がどんなエラーを返すか把握しているため、`anyerror` による型情報の損失は実害にならない。

```zig
// 呼び出し元のエラーハンドリング（anyerror の場合）
const data = zretry.retry(env.io, .{}, fetchData, .{"url"}) catch |err| switch (err) {
    error.RetriesExhausted => ..., // リトライ上限
    error.InvalidInput     => ..., // リトライしない失敗
    else                   => return err,
};
```

---

## 今後の拡張（実装対象外）

### バックオフアルゴリズム

`Strategy` union にケースを追加する。追加は破壊的変更（ライブラリ側が switch を網羅しているため、利用者への影響は軽微）。

| アルゴリズム | Strategy の追加ケース候補 |
|---|---|
| 固定遅延 | `constant: ConstantConfig` |
| 線形バックオフ | `linear: LinearConfig` |
| カスタム関数 | `custom: CustomFn` |

### エラーフィルタ・on-retry コールバック

`error.Retry` 設計により、これらはライブラリの責務ではなくユーザの関数の責務となる。
リトライ判断・リトライ時の処理（ロギング等）はユーザが `func` の中に実装する。

---

## 振り返り（実装後の差異）

### `nextDelayMs` の配置

**計画**: `backoff.zig` に `pub fn nextDelayMs` として定義し、`retry.zig` から呼び出す。

**実装**: `retry.zig` のプライベート関数（`fn nextDelayMs`）として定義。`backoff.zig` は型定義（`ExponentialJitterConfig`、`Strategy`）のみ。

**理由**: `nextDelayMs` を内部実装として隠蔽するため `pub` を外す方針になったが、別ファイルから呼ぶには `pub` が必要という制約があった。`nextDelayMs` は `retry.zig` からしか使われないため、同一ファイルに移動してプライベート化するのが最も自然な解決策だった。

---

### スリープ API

**計画**: `std.time.sleep(delayMs * std.time.ns_per_ms)`

**実装**: `std.Io.sleep(io, std.Io.Duration.fromNanoseconds(ns), .awake)`

**理由**: Zig 0.16.0 で `std.time.sleep` が廃止されており、スリープは `std.Io` 経由で行う設計に変わっていた。計画作成時点では把握できていなかった破壊的変更。

---

### 固定シードテスト

**計画**: `(attempt, config, expected_ms)` のペアで `expectEqual` による等値チェック。

**実装**: ランダム要素を含むケースは範囲チェック（`>= min and <= max`）で代替。`jitterFactor=0.0` のケースのみ `expectEqual` で等値チェック。

**理由**: PRNG の出力値は実行前に手計算が困難であり、初回実行で値を確認してから期待値を埋める作業が必要になる。`jitterFactor=0.0` にすれば乱数を使わないため決定的になり、それで cap 計算の正しさは十分に検証できる。ランダム要素を含むケースは範囲チェックで上下限のクランプを確認するアプローチが現実的だった。
