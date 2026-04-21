# zretry

[![API Docs](https://img.shields.io/badge/API%20Docs-GitHub%20Pages-blue)](https://dot96gal.github.io/zretry/)
[![test](https://github.com/dot96gal/zretry/actions/workflows/test.yml/badge.svg)](https://github.com/dot96gal/zretry/actions/workflows/test.yml)
[![release](https://github.com/dot96gal/zretry/actions/workflows/release.yml/badge.svg)](https://github.com/dot96gal/zretry/actions/workflows/release.yml)

Zig向けのシンプルなリトライ処理ライブラリです。指数関数バックオフ + Full Jitter によるリトライを1行で追加できます。

> **注意:** このリポジトリは個人的な興味・学習を目的としたホビーライブラリです。設計上の判断はすべて作者が個人で行っており、事前の告知なく破壊的変更が加わることがあります。安定した API を前提としたい場合は、任意のコミットやタグ時点でフォークし、独自に管理されることをおすすめします

## 要件
-  Zig 0.16.0 以上

---

## 利用者向け

### インストール

```sh
zig fetch --save https://github.com/dot96gal/zretry/archive/refs/tags/<version>.tar.gz
```

`build.zig` にモジュールを追加します。

```zig
const zretry = b.dependency("zretry", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zretry", zretry.module("zretry"));
```

### 基本的な使い方

リトライしたい操作を関数として定義し、一時的なエラーのときに `error.Retry` を返します。それ以外のエラーはそのまま返します。**何をリトライするかはユーザが関数内で決める**設計であり、ライブラリはバックオフ制御のみを担います。

```zig
const zretry = @import("zretry");

fn fetchData(url: []const u8) error{ Retry, InvalidInput }![]u8 {
    return httpGet(url) catch |err| switch (err) {
        error.Timeout => return error.Retry,           // 一時的なエラー → リトライ
        error.InvalidInput => return error.InvalidInput, // 恒久的なエラー → そのまま返す
    };
}

pub fn main(env: std.process.Init) !void {
    // .{} だけでデフォルト設定（maxAttempts=3、指数バックオフ+ジッター）が使える
    const data = zretry.retry(env.io, .{}, fetchData, .{"https://example.com"}) catch |err| switch (err) {
        error.RetriesExhausted => {
            std.log.err("max retries reached", .{});
            return err;
        },
        error.InvalidInput => {
            std.log.err("invalid input", .{});
            return err;
        },
        else => return err,
    };
    defer env.gpa.free(data);
}
```

### カスタム設定

```zig
const config = zretry.Config{
    .maxAttempts = 5,
    .strategy = .{ .exponentialJitter = .{
        .baseDelayMs = 200,
        .maxDelayMs  = 10_000,
    }},
};

const data = zretry.retry(env.io, config, fetchData, .{"https://example.com"}) catch |err| switch (err) {
    error.RetriesExhausted => ...,
    else => return err,
};
```

### API リファレンス

#### `retry`

```zig
pub fn retry(
    io:            std.Io,
    config:        Config,
    comptime func: anytype,
    args:          anytype,
) anyerror!T
```

バックオフ付きでリトライを実行します。`func` が `error.Retry` を返したときのみリトライし、それ以外のエラーは即座に呼び出し元に伝播します。`config.maxAttempts` 回すべて `error.Retry` だった場合は `error.RetriesExhausted` を返します。`func` はエラーユニオンを返す関数でなければなりません。

#### `Config`

| フィールド | 型 | デフォルト | 説明 |
|---|---|---|---|
| `maxAttempts` | `u32` | `3` | リトライを含む最大試行回数 |
| `strategy` | `Strategy` | `exponentialJitter` デフォルト値 | バックオフアルゴリズム |

#### `Strategy`

| ケース | 説明 |
|---|---|
| `.exponentialJitter` | 指数関数バックオフ + Full Jitter |

#### `ExponentialJitterConfig`

| フィールド | 型 | デフォルト | 説明 |
|---|---|---|---|
| `baseDelayMs` | `u64` | `100` | 基準遅延（ミリ秒） |
| `maxDelayMs` | `u64` | `30_000` | 遅延上限（ミリ秒） |
| `multiplier` | `f64` | `2.0` | 試行ごとの乗数 |
| `jitterFactor` | `f64` | `0.5` | ランダム幅の割合（0.0〜1.0） |

#### エラー

| エラー | 説明 |
|---|---|
| `error.RetriesExhausted` | `maxAttempts` 回すべてリトライしても成功しなかった |

---

## 開発者向け

### 前提ツール

- [mise](https://mise.jdx.dev/) — Zig のバージョン管理と開発タスクの実行に使用

### セットアップ

```sh
git clone https://github.com/dot96gal/zretry
cd zretry
mise install
```

### 開発タスク

| コマンド | 説明 |
|---|---|
| `mise run build` | コンパイルチェック |
| `mise run test` | テスト実行 |
| `mise run fmt` | コードフォーマット |
| `mise run fmt-check` | フォーマットチェック |
| `mise run example:basic` | サンプルコードの実行 |
| `mise run release <version>` | リリース |

### ファイル構成

```
src/
  root.zig      パブリック API の再エクスポート
  retry.zig     retry() 関数・Config・バックオフ計算の実装
  backoff.zig   Strategy union・ExponentialJitterConfig の型定義
example/
  basic.zig     基本的な使い方のサンプル
```

### 設計方針

- **リトライ判断はユーザの責務**: `error.Retry` をシグナルとして使用し、何をリトライするかはユーザの関数が決める。ライブラリはバックオフ制御のみを担う。
- **`anyerror` の採用**: `func` の返すエラー集合から `error.Retry` を型レベルで除去する手段が Zig 0.16.0 では存在しないため、戻り値型は `anyerror` を使用している。
- **外部依存なし**: Zig 標準ライブラリ（`std`）のみを使用する。

### テスト方針

- `backoff` 関連テストは `src/retry.zig` 内にあり、`nextDelayMs` をプライベート関数として直接テストする。
- スリープを伴うテストは `baseDelayMs = 0` で遅延をゼロにして回避する。
- `src/root.zig` の `test { _ = @import(...) }` ブロックによりすべてのテストが `zig build test` で実行される。

### リリース手順

```sh
mise run release <version>  # 例: mise run release 1.0.0
```

---

## ライセンス

[MIT](LICENSE)
