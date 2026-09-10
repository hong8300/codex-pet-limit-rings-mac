# codex-pet-limit-rings-mac

Codex のペットの周囲に、Codex の 5 時間・週次残り容量をリングで表示する macOS 用コンパニオンアプリです。

Codex アプリ本体は変更しません。ペット画像の差し替えも、Codex の app bundle へのパッチも行いません。別プロセスの透明な常時前面ウィンドウとしてリングを描画し、Codex が表示しているペットの位置とサイズに追従します。

Apple Silicon Mac 向けです。

![Pro プランのペットと3本のリング（背景透過）](docs/assets/pro-pet-transparent-20260910.png)

Pro プランの実画面（2026年9月10日撮影）。掲載用に背景を透過処理しています。

**Plus プランはリング2本、Pro プランはリング3本**を表示します。内訳は次のとおりです。

| プラン | リング数 | 外側からの表示順 |
| --- | --- | --- |
| Plus | 2本 | 通常の週次（青）、通常の5時間（緑） |
| Pro | 3本 | 通常の週次（青）、Spark 週次（紫）、Spark 5時間（ピンク） |

表示本数は Codex が公開する利用枠に応じて変わります。上記の Pro 表示は通常の5時間枠がなく、Spark の2枠が取得できる場合です。取得できない枠のリングは表示しません。

## 表示プレビュー

現行アプリと同じ描画コードで生成したプレビューです（実画面のスクリーンショットではありません）。比較しやすいサンプル値を使い、中央のペットは省略しています。残り割合とリセット日時は表示例です。

| | Plus：リング2本 | Pro：リング3本 |
| --- | --- | --- |
| 通常表示 | ![Plus の通常表示：週次と5時間の2本のリング](docs/assets/plus-rings.png) | ![Pro の通常表示：週次と Spark 週次・5時間の3本のリング](docs/assets/pro-rings.png) |
| マウスオーバー時 | ![Plus の残り枠：週次80%、5時間65%、リセット日時を JST で表示](docs/assets/plus-hover.png) | ![Pro の残り枠：週次80%、Spark 週次55%、Spark 5時間40%、リセット日時を JST で表示](docs/assets/pro-hover.png) |

ペットまたはリングにマウスを重ねると、このように各枠の**残り割合と JST のリセット日時**が表示されます。文字サイズは初期値の `大`（2×）です。

## 表示内容

- 外側から通常の週次（青）、通常の5時間（緑・取得できる場合）、Spark 週次（紫）、Spark 5時間（ピンク）の順に表示します。通常の5時間枠がない Pro では3本になります。Spark の枠も取得できる場合だけ表示します。
- 通常枠は残り容量が少なくなるとアンバー、赤へ変わります。Spark は紫・ピンクを維持し、残量低下時は濃い色になります。
- ペットまたはリングにマウスを重ねると、通常枠・Spark 枠それぞれの正確な残り割合と JST のリセット日時を表示します。
- メニューバーの小さなアイコンから、リング表示の切り替え、ログイン時起動の切り替え、ホバー文字サイズの変更、再読み込み、終了ができます。
- ホバー時の文字サイズはメニューの `文字サイズ` から `小` / `中` / `大` / `特大` / `最大`（1×〜3×）で変更でき、選択は次回起動以降も保持されます。初期値は `大`（2×）です。

Codex のペットを閉じるとリングも消えます。ペットを再表示するとリングも戻ります。ペットのサイズを変更した場合も、`~/.codex/config.toml` の `avatar-overlay-mascot-width-px` を読んでリングサイズを追従させます。

## 最初に build は必要？

通常は不要です。

インストールする場合は、最初から次を実行してください。

```bash
tools/install-limit-rings.sh
```

このスクリプトが内部で build し、`~/Applications/CodexPetLimitRings.app` を作成して LaunchAgent に登録します。ログイン時起動はデフォルトで ON です。

開発用に一時起動する場合も、手動 build は不要です。

```bash
tools/run-limit-rings.sh
```

このスクリプトも内部で build して、`tmp/CodexPetLimitRings.app` を起動します。

手動で `tools/build-limit-rings.sh` を実行するのは、アプリ bundle だけを作りたい場合や、開発中に build 単体を検証したい場合です。

## 使い方

ログイン時に自動起動する形でインストール:

```bash
tools/install-limit-rings.sh
```

インストール後、macOS のメニューバーにリングのアイコンが出ます。`ログイン時に起動` は最初から ON です。そこから `Show Rings`、`ログイン時に起動`、`文字サイズ`、`Refresh Now`、終了操作ができます。

開発用に一時起動:

```bash
tools/run-limit-rings.sh
```

アンインストール:

```bash
tools/uninstall-limit-rings.sh
```

## 仕組み

このアプリは Codex の外側で動くコンパニオンアプリです。Codex 本体を変更しないため、Codex のアップデートで app bundle のパッチが壊れる問題を避けられます。

読み取る情報はローカルの Codex 状態ファイルと、ChatGPT の usage endpoint だけです。

- `~/.codex/auth.json`: ChatGPT usage endpoint を読むためのローカル bearer token
- `https://chatgpt.com/backend-api/wham/usage`: 5 時間・週次制限の live usage
- `~/.codex/.codex-global-state.json`: ペットの表示状態と位置
- `~/.codex/config.toml`: ペットサイズ `avatar-overlay-mascot-width-px`
- `~/.codex/logs_2.sqlite`: 古い `codex.rate_limits` イベントがある場合だけ legacy fallback として使用

OpenAI API key は不要です。ペット画像、スクリーンショット、プロンプト、リポジトリ内容は送信しません。

## プロジェクト構成

```text
tools/
  codex-pet-limit-rings.swift      macOS ネイティブアプリ本体
  install-limit-rings.sh           build してインストールし、ログイン時起動に登録
  uninstall-limit-rings.sh         アプリと LaunchAgent を削除
  run-limit-rings.sh               開発用に build して一時起動
  build-limit-rings.sh             .app bundle を作成
  install-codex-skill.sh           同梱 skill を ~/.codex/skills にコピー

skills/codex-pet-limit-rings/
  SKILL.md                         Codex agent 用の作業手順

docs/
  limit-rings.md                   実装契約とデータフロー
```

## 開発

README の表示プレビューを再生成（ローカルの認証情報・使用量は読み取りません）:

```bash
bash tools/render-readme-previews.sh
```

スクリプト構文を確認:

```bash
bash -n tools/*.sh
```

Swift を直接 build:

```bash
swiftc tools/codex-pet-limit-rings.swift -o tmp/codex-pet-limit-rings -framework AppKit -lsqlite3
```

使用量の読み取り・描画の回帰テスト:

```bash
bash tools/test-limit-rings.sh
```

静的プレビュー PNG を生成（`--size` はペット相当のサイズ。画像にはラベル用余白も含みます）:

```bash
tmp/codex-pet-limit-rings --preview tmp/limit-rings-preview.png --size 164
```

アプリ bundle を作成:

```bash
tools/build-limit-rings.sh
```

## Codex にこの workflow を渡す

このリポジトリには Codex agent 用の skill が同梱されています。

ローカル Codex に skill をインストール:

```bash
tools/install-codex-skill.sh
```

Codex に依頼する場合の例:

```text
このリポジトリの codex-pet-limit-rings skill を使って、Codex ペット用のリング companion をインストールし、LaunchAgent が動作していることと、リングがペットに追従することを確認してください。
```

## ライセンス

MIT. See `LICENSE`.
