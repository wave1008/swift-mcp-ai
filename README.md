# simulator-mcp

iOS Simulator の画面を高速に取得・解析する MCP サーバー(Swift / macOS)。

- **capture_screenshot** — ScreenCaptureKit によるスクリーンショット。同一 Simulator への連続呼び出しは常駐 `SCStream` の最新フレームを返すため、ほぼゼロレイテンシ
- **detect_objects** — Core ML 化した YOLO をプロセス内に常駐させて物体検出(ANE/GPU)
- **extract_text** — Vision OCR でテキストと位置(ピクセル座標・左上原点)を抽出
- **analyze_screen** — 1回のキャプチャに対して YOLO と OCR を並列実行
- **list_simulators** — 起動中 Simulator の一覧と権限・ストリーム状態

すべての処理は単一プロセス内で完結し、キャプチャ画像は `CVPixelBuffer` のまま
エンコードなしで解析エンジンへ渡される。独立したリクエストは並列に処理される
(1リクエストにつき対象 Simulator は1つ)。

## ビルド

```sh
swift build -c release
# バイナリ: .build/release/SimulatorMCP
```

## MCP クライアント登録例(Claude Code)

```sh
claude mcp add simulator-mcp -- /path/to/swift-mcp-ai/.build/release/SimulatorMCP
```

または `.mcp.json`:

```json
{
  "mcpServers": {
    "simulator-mcp": {
      "command": "/path/to/swift-mcp-ai/.build/release/SimulatorMCP",
      "env": { "YOLO_MODEL_PATH": "/path/to/model.mlpackage" }
    }
  }
}
```

## 必要な権限・前提

- **画面収録権限(TCC)**: システム設定 > プライバシーとセキュリティ > 画面収録 で、
  MCP クライアントの親プロセス(ターミナル、Claude Desktop 等)を許可する。
  `list_simulators` の `screen_recording_permission` で確認できる
- Simulator のウィンドウが画面上に存在すること(他ウィンドウの背後は可、**最小化は不可**)
- Xcode(`xcrun simctl`)

## YOLO モデルの用意

モデルは同梱していない。`uv` があれば1コマンドで生成できる:

```sh
uv run scripts/export_yolo.py yolo11n   # Models/yolo11n.mlpackage を生成
```

検索順: `$YOLO_MODEL_PATH` → `./Models/` → 実行ファイル隣の `Models/`。
`.mlpackage` は初回起動時にコンパイルされ `~/Library/Caches/simulator-mcp/` に
キャッシュされる。NMS 込み(`nms=True`)でエクスポートすること。

## 高速化の仕組み

| 施策 | 効果 |
|---|---|
| 常駐 SCStream の最新フレーム返却 | 2回目以降のキャプチャ ≈0ms(アイドル30秒で自動解放) |
| ワンショットは SCScreenshotManager | 初回でも数十ms |
| YOLO / OCR モデルの起動時ウォームアップ | 初回推論の遅延(OCR 日本語は約30秒)をバックグラウンドで吸収 |
| CVPixelBuffer 直渡し | キャプチャ→解析間のエンコード往復なし |
| 画像はファイルパス返却(既定) | stdio への base64 転送を回避(`inline: true` で同梱も可) |
| analyze_screen | 1キャプチャに対し YOLO と OCR を並列実行 |

## 既知の制約

- OCR の `fast` オプションは受け付けるが、現環境(macOS 27)の Vision fast パスに
  クラッシュ不具合があるため常に accurate で実行される(ウォーム後 150〜300ms)
- 座標はすべてキャプチャ画像のピクセル座標(左上原点)。Simulator の表示倍率に
  応じて論理ポイントとは異なる場合がある

## 動作確認

```sh
(
  echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}'
  sleep 0.3
  echo '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_simulators","arguments":{}}}'
  sleep 3
) | .build/release/SimulatorMCP
```
