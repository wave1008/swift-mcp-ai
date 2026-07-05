# simulator-mcp

iOS Simulator の画面を高速に取得・解析する MCP サーバー(Swift / macOS)。

- **capture_screenshot** — `simctl io screenshot` でデバイス画面バッファを直接取得。ホストアプリの UI やベゼルが写り込まず、ネイティブ解像度(例: 1179×2556)で、ウィンドウの表示状態に依存しない(最小化・ヘッドレス・背後でも可)。画面収録権限は不要
- **detect_objects** — Core ML 化した YOLO をプロセス内に常駐させて物体・UI 要素検出(ANE/GPU)。
  既定モデル(OmniParser v2 icon_detect)はボタン・アイコン等のインタラクティブ UI 要素を検出する
- **extract_text** — Vision OCR でテキストと位置(ピクセル座標・左上原点)を抽出
- **analyze_screen** — 1回のキャプチャに対して YOLO と OCR を並列実行。結果の `ui_elements` は
  検出要素と OCR テキストを位置照合した**ラベル付き UI マップ**(読み順ソート)。
  リスト行は「アイコン+右隣のテキスト」、カード型は「領域内の先頭テキスト」をラベルとして関連付ける。
  `annotate: true` で検出要素の bbox を赤枠+ラベルタグ、OCR テキストの bbox を緑枠で
  描画した画像を保存し `annotated_path` で返す
- **list_simulators** — 起動中 Simulator の一覧(名前・UDID・ランタイム)

すべての処理は単一プロセス内で完結し、キャプチャ画像はエンコードなしで解析エンジンへ
渡される。独立したリクエストは並列に処理される(1リクエストにつき対象 Simulator は1つ)。

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

- Xcode(`xcrun simctl`)がインストールされていること。キャプチャは `simctl io screenshot`
  でデバイス画面バッファから直接取得するため、**画面収録権限もウィンドウ表示も不要**
  (Simulator が最小化・ヘッドレス・他ウィンドウの背後でも取得できる)
- 対象 Simulator が起動(Booted)していること

## 検出モデルの用意

モデルは同梱していない。UI 解析には **OmniParser v2 icon_detect**(yolo11m ベース、
クラス `icon` 1種、imgsz 1280)を推奨:

```sh
curl -L -o Models/omniparser_icon_detect.pt \
  https://huggingface.co/microsoft/OmniParser-v2.0/resolve/main/icon_detect/model.pt
uv run scripts/export_yolo.py Models/omniparser_icon_detect.pt
# → Models/omniparser_icon_detect.mlpackage(imgsz はモデルのメタデータから自動)
```

写真・カメラ画面の中身など実世界の物体を検出したい場合は COCO 80 クラスの汎用モデル:

```sh
uv run scripts/export_yolo.py yolo11n   # Models/yolo11n.mlpackage を生成
```

検索順: `$YOLO_MODEL_PATH` → `./Models/` → 実行ファイル隣の `Models/`
(ディレクトリ内はファイル名ソートで最初の1つ)。複数モデルを置く場合は
`YOLO_MODEL_PATH` で明示するのが確実。`.mlpackage` は初回起動時にコンパイルされ
`~/Library/Caches/simulator-mcp/` にキャッシュされる。NMS 込み(`nms=True`)で
エクスポートすること。

ライセンス注意: OmniParser の icon_detect 重みは AGPL-3.0。

## 高速化の仕組み

| 施策 | 効果 |
|---|---|
| YOLO / OCR モデルの起動時ウォームアップ | 初回推論の遅延(OCR 日本語は約30秒)をバックグラウンドで吸収 |
| キャプチャ画像の直渡し | キャプチャ→解析間のエンコード往復なし |
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
