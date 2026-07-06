import Foundation

enum InteractionError: Error, CustomStringConvertible {
    case screenScaleUnavailable(udid: String, detail: String)

    var description: String {
        switch self {
        case .screenScaleUnavailable(let udid, let detail):
            return "画面スケールを取得できません(udid: \(udid)): \(detail)"
        }
    }
}

/// AXe CLI ラッパー。iOS Simulator への UI 操作(タップ・スワイプ・文字入力)を行う。
///
/// 座標は知覚系ツール(analyze_screen / extract_text 等)と同じ
/// 「キャプチャ画像のピクセル座標(左上原点)」で受け取り、AXe が要求する
/// point 座標へ画面スケール(SIMULATOR_MAINSCREEN_SCALE)で変換して渡す。
actor InteractionEngine {
    /// AXe 実行ファイルパス(環境変数 AXE_PATH)。nil なら PATH から解決
    private let axePath: String?
    /// udid → 画面スケール(例: 3.0)。プロセス生存中は不変なのでキャッシュ
    private var scaleCache: [String: Double] = [:]
    /// udid → 画面ピクセルサイズ。システムジェスチャ回避のクランプに使う
    private var screenSizeCache: [String: (width: Int, height: Int)] = [:]

    init(axePath: String?) {
        self.axePath = axePath.flatMap { $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath }
    }

    func cachedScreenSize(udid: String) -> (width: Int, height: Int)? {
        screenSizeCache[udid]
    }

    func cacheScreenSize(udid: String, width: Int, height: Int) {
        screenSizeCache[udid] = (width, height)
    }

    /// システムジェスチャ(通知センター/Spotlight/ホームインジケータ)の誤発動を防ぐため、
    /// 座標を安全な操作域へ収める(ピクセル)。
    /// - タップ: 下端のホームインジケータ帯だけ避ける
    /// - スワイプ: 上端(通知センター/Spotlight)と下端(ホーム/App スイッチャー)を避ける
    static func clampTap(x: Double, y: Double, width: Int, height: Int) -> (x: Double, y: Double) {
        (min(max(x, 8), Double(width) - 8), min(max(y, 8), Double(height) - 70))
    }

    static func clampSwipe(x: Double, y: Double, width: Int, height: Int) -> (x: Double, y: Double)
    {
        (min(max(x, 8), Double(width) - 8), min(max(y, 110), Double(height) - 130))
    }

    /// ピクセル→point 変換の除数(= デバイスの画面スケール)。
    func screenScale(udid: String) async throws -> Double {
        if let cached = scaleCache[udid] { return cached }
        let data: Data
        do {
            data = try await ShellRunner.run(
                "/usr/bin/xcrun", ["simctl", "getenv", udid, "SIMULATOR_MAINSCREEN_SCALE"])
        } catch {
            throw InteractionError.screenScaleUnavailable(udid: udid, detail: "\(error)")
        }
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let scale = Double(text), scale > 0 else {
            throw InteractionError.screenScaleUnavailable(udid: udid, detail: "'\(text)'")
        }
        scaleCache[udid] = scale
        return scale
    }

    /// ピクセル座標をタップする。実際にタップした point 座標を返す。
    func tap(udid: String, pixelX: Double, pixelY: Double) async throws -> (x: Double, y: Double) {
        let scale = try await screenScale(udid: udid)
        let x = round(pixelX / scale * 10) / 10
        let y = round(pixelY / scale * 10) / 10
        _ = try await runAxe(["tap", "-x", "\(x)", "-y", "\(y)", "--udid", udid])
        return (x, y)
    }

    /// ピクセル座標間をスワイプする。
    ///
    /// - duration 既定 0.8 秒: 速いフリックは慣性スクロールが大きく、観察時と
    ///   タップ時で行位置がずれる。ゆっくりドラッグして移動量を決定的にする
    /// - post-delay 1.0 秒: 残った慣性・バウンスが収まってから結果を返し、
    ///   直後の観察が動いている画面を撮らないようにする
    func swipe(
        udid: String, fromPixelX: Double, fromPixelY: Double,
        toPixelX: Double, toPixelY: Double, durationSeconds: Double?
    ) async throws {
        let scale = try await screenScale(udid: udid)
        let args = [
            "swipe",
            "--start-x", "\(round(fromPixelX / scale * 10) / 10)",
            "--start-y", "\(round(fromPixelY / scale * 10) / 10)",
            "--end-x", "\(round(toPixelX / scale * 10) / 10)",
            "--end-y", "\(round(toPixelY / scale * 10) / 10)",
            "--duration", "\(durationSeconds ?? 0.8)",
            "--post-delay", "1.0",
            "--udid", udid,
        ]
        _ = try await runAxe(args)
    }

    /// フォーカス中の入力欄へ文字を入力する。
    func typeText(udid: String, text: String) async throws {
        _ = try await runAxe(["type", text, "--udid", udid])
    }

    /// アプリを起動する(起動中なら終了してから起動 = 常に初期状態)。
    /// simctl ベースなのでホーム画面のアイコン位置に依存しない。
    func launchApp(udid: String, bundleID: String) async throws {
        _ = try? await ShellRunner.run("/usr/bin/xcrun", ["simctl", "terminate", udid, bundleID])
        _ = try await ShellRunner.run("/usr/bin/xcrun", ["simctl", "launch", udid, bundleID])
    }

    private func runAxe(_ arguments: [String]) async throws -> String {
        let data: Data
        if let axePath {
            data = try await ShellRunner.run(axePath, arguments)
        } else {
            // AXE_PATH 未指定時は PATH から解決(Homebrew 等でインストール済みの想定)
            data = try await ShellRunner.run("/usr/bin/env", ["axe"] + arguments)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
