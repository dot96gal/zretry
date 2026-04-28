# zretry

[![API Docs](https://img.shields.io/badge/API%20Docs-GitHub%20Pages-blue)](https://dot96gal.github.io/zretry/)
[![CI](https://github.com/dot96gal/zretry/actions/workflows/ci.yml/badge.svg)](https://github.com/dot96gal/zretry/actions/workflows/ci.yml)
[![Release](https://github.com/dot96gal/zretry/actions/workflows/release.yml/badge.svg)](https://github.com/dot96gal/zretry/actions/workflows/release.yml)

Zig のシンプルなリトライ処理ライブラリ。

> **注意:** このリポジトリは個人的な興味・学習を目的としたホビーライブラリです。設計上の判断はすべて作者が個人で行っており、事前の告知なく破壊的変更が加わることがあります。安定した API を前提としたい場合は、任意のコミットやタグ時点でフォークし、独自に管理されることをおすすめします。

## 要件
-  Zig 0.16.0 以上

---

## 利用者向け

### インストール

#### 1. `build.zig.zon` に zretry を追加する。

最新のタグは [GitHub Releases](https://github.com/dot96gal/zretry/releases) で確認できる。

以下のコマンドを実行すると、`build.zig.zon` の `.dependencies` に自動的に追加される。

```sh
zig fetch --save https://github.com/dot96gal/zretry/archive/refs/tags/<version>.tar.gz
```

```zig
// build.zig.zon（自動追加される内容の例）
.dependencies = .{
    .zretry = .{
        .url = "https://github.com/dot96gal/zretry/archive/refs/tags/<version>.tar.gz",
        .hash = "<hash>",
    },
},
```

#### 2. `build.zig` で zretry モジュールをインポートする。

```zig
const zretry_dep = b.dependency("zretry", .{
    .target = target,
    .optimize = optimize,
});
const zretry_mod = zretry_dep.module("zretry");
exe.root_module.addImport("zretry", zretry_mod);
```

### 使い方

リトライしたい操作を関数として定義し、一時的なエラーのときに `error.Retry` を返す。それ以外のエラーはそのまま返す。**何をリトライするかはユーザが関数内で決める**設計であり、ライブラリはバックオフ制御のみを担う。

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

#### カスタム設定

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

バックオフ付きでリトライを実行する。`func` が `error.Retry` を返したときのみリトライし、それ以外のエラーは即座に呼び出し元に伝播する。`config.maxAttempts` 回すべて `error.Retry` だった場合は `error.RetriesExhausted` を返す。`func` はエラーユニオンを返す関数でなければならない。

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

### 必要なツール

| ツール | 説明 |
|-------|------|
| [mise](https://mise.jdx.dev/) | ツールバージョン管理（Zig・zls を自動インストール） |
| `zig-lint` | Zig 簡易リントスクリプト（`~/.local/bin/` にインストール済み） |
| `zig-release` | バージョン更新・タグ付けスクリプト（`~/.local/bin/` にインストール済み） |

### セットアップ

```sh
git clone https://github.com/dot96gal/zretry
cd zretry
mise install
```

### タスク一覧

| コマンド | 説明 |
|---|---|
| `mise run fmt` | フォーマット |
| `mise run fmt-check` | フォーマットチェック |
| `mise run lint` | リント |
| `mise run build` | ビルド |
| `mise run test` | テスト |
| `mise run example:basic` | サンプルコードの実行 |
| `mise run build-docs` | API ドキュメントのビルド |
| `mise run serve-docs` | API ドキュメントのサーブ |
| `mise run release <version>` | リリース |

### ファイル構成

```
build.zig        # ビルドスクリプト
build.zig.zon    # パッケージマニフェスト
src/
  root.zig       # パブリック API の再エクスポート
  retry.zig      # retry() 関数・Config・バックオフ計算の実装
  backoff.zig    # Strategy union・ExponentialJitterConfig の型定義
example/
  basic.zig      # 基本的な使い方のサンプル
```

### 設計方針

- **リトライ判断はユーザの責務**: `error.Retry` をシグナルとして使用し、何をリトライするかはユーザの関数が決める。ライブラリはバックオフ制御のみを担う。
- **`anyerror` の採用**: `func` の返すエラー集合から `error.Retry` を型レベルで除去する手段が Zig 0.16.0 では存在しないため、戻り値型は `anyerror` を使用している。
- **外部依存なし**: Zig 標準ライブラリ（`std`）のみを使用する。

### テスト

- `backoff` 関連テストは `src/retry.zig` 内にあり、`nextDelayMs` をプライベート関数として直接テストする。
- スリープを伴うテストは `baseDelayMs = 0` で遅延をゼロにして回避する。
- `src/root.zig` の `test { _ = @import(...) }` ブロックによりすべてのテストが `zig build test` で実行される。

---

## ライセンス

[MIT](LICENSE)
