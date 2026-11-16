import AVFoundation
import LiveKit
import SwiftUI
import WebKit

// Otocloud のアプリ本体。
// 画面とふるまいは https://on-pa.net/app/ と同じものを、アプリの中でそのまま表示する。
// サイトを更新すれば、アプリを作り直さなくても中身が新しくなる。

@main
struct OtocloudApp: App {
    init() {
        // 画面を消しても、ほかのアプリの音と一緒でも鳴らせるように
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
    }

    var body: some Scene {
        WindowGroup {
            WebShell(url: URL(string: "https://on-pa.net/app/")!)
                .ignoresSafeArea()
                .background(Color(red: 0.851, green: 0.855, blue: 0.867)) // #D9DADD
        }
    }
}

struct WebShell: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = [] // 曲を選んだらすぐ鳴らせる
        config.websiteDataStore = .default()                 // ログイン状態や設定を覚えておく
        // 通話はアプリ本体（ネイティブ）でつなぐ。ページからは window.webkit.messageHandlers.otoCall で頼む
        config.userContentController.add(context.coordinator.nativeCall, name: "otoCall")

        let web = WKWebView(frame: .zero, configuration: config)
        web.uiDelegate = context.coordinator
        web.navigationDelegate = context.coordinator
        web.isOpaque = false
        web.backgroundColor = UIColor(red: 0.851, green: 0.855, blue: 0.867, alpha: 1)
        web.scrollView.backgroundColor = web.backgroundColor
        web.scrollView.contentInsetAdjustmentBehavior = .never // 画面の端までサイトの見た目にする
        web.scrollView.bounces = false
        web.allowsBackForwardNavigationGestures = false
        // 拡大・縮小させない（アプリとして画面を固定する）
        web.scrollView.minimumZoomScale = 1
        web.scrollView.maximumZoomScale = 1
        web.scrollView.pinchGestureRecognizer?.isEnabled = false
        web.scrollView.delegate = context.coordinator
        if #available(iOS 16.4, *) { web.isInspectable = true }
        // 毎回いちばん新しいサイトを読む（古い画面が残らないように）
        web.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        context.coordinator.webView = web
        context.coordinator.nativeCall.webView = web
        // アプリに戻ってきた時、しばらく経っていたら新しいサイトを読み直す
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.didBecomeActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.willResign),
                                               name: UIApplication.willResignActiveNotification, object: nil)
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate, UIScrollViewDelegate {
        weak var webView: WKWebView?
        let nativeCall = NativeCall()
        private var leftAt = Date()

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { nil }

        @objc func willResign() { leftAt = Date() }

        @objc func didBecomeActive() {
            // 10分以上たっていて、通話中でなければ読み直す（通話中に切れないように）
            guard Date().timeIntervalSince(leftAt) > 600, let web = webView else { return }
            guard !nativeCall.inCall else { return }
            web.evaluateJavaScript("typeof call !== 'undefined' && call.state !== 'idle'") { result, _ in
                if (result as? Bool) != true { web.reload() }
            }
        }

        // 通話のマイクは、Otocloud のページからのお願いなら許可する
        @available(iOS 15.0, *)
        func webView(_ webView: WKWebView,
                     requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo,
                     type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(origin.host == "on-pa.net" ? .grant : .prompt)
        }

        // 新しいタブで開こうとするリンクは、同じ画面で開く
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }

        // 読み込みに失敗したら、少し待ってやり直す（電波が弱い時など）
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { webView.reload() }
        }
    }
}

// MARK: - 通話（ネイティブ）

/// ページの代わりに、アプリ本体で LiveKit の通話をつなぐ。
/// ねらい：喋っても音楽が小さくならない／音楽が電話っぽい音にならない／声をきれいに送る。
@MainActor
final class NativeCall: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?
    private var room: Room?
    private var timer: Timer?
    private var voiceVolume: Double = 1
    private var hadPeer = false
    private var wasConnected = false
    var inCall: Bool { room != nil }

    override init() {
        super.init()
    }

    // ページからのお願い
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let op = body["op"] as? String else { return }
        let id = body["id"] as? String
        Task { @MainActor in
            do {
                switch op {
                case "connect":
                    try await connect(url: body["url"] as? String ?? "", token: body["token"] as? String ?? "")
                case "mic":
                    let on = body["on"] as? Bool ?? true
                    _ = try await room?.localParticipant.setMicrophone(enabled: on,
                                                                       captureOptions: capture,
                                                                       publishOptions: Self.publish)
                case "vol":
                    voiceVolume = max(0, min(2, (body["v"] as? Double) ?? 1))
                    applyVoiceVolume()
                case "disconnect":
                    await hangUp()
                default: break
                }
                reply(id, ["ok": true])
            } catch {
                let denied = AVAudioApplication.shared.recordPermission == .denied
                reply(id, ["error": error.localizedDescription, "name": denied ? "NotAllowedError" : "Error"])
            }
        }
    }

    // 声の送り方：ふつうの通話（24kbps）より高い音質で、無音の間も途切れさせない
    private var capture = AudioCaptureOptions(echoCancellation: true, autoGainControl: true, noiseSuppression: true)
    static let publish = AudioPublishOptions(encoding: AudioEncoding(maxBitrate: 64000), dtx: false, red: true)

    private func connect(url: String, token: String) async throws {
        await hangUp()
        // AirPodsなどがつながっている時は、iPhoneの「通話用の音の処理」を使わない。
        // それを使うと、iPhoneが音をAirPodsから本体のスピーカーに勝手に切り替えてしまうため。
        // （イヤホンなら音が相手に返らないので、その処理はいらない）
        let hp = headphonesConnected()
        try? AudioManager.shared.setPlatformVoiceProcessingAllowed(!hp)
        capture = AudioCaptureOptions(echoCancellation: !hp, autoGainControl: true, noiseSuppression: true)
        configureSession()
        // 喋っても音楽をできるだけ下げない
        AudioManager.shared.duckingLevel = .min
        AudioManager.shared.isAdvancedDuckingEnabled = false
        let room = Room()
        self.room = room
        hadPeer = false
        wasConnected = false
        do {
            try await room.connect(url: url, token: token)
            wasConnected = true
            try await room.localParticipant.setMicrophone(enabled: true, captureOptions: capture, publishOptions: Self.publish)
        } catch {
            await hangUp()
            throw error
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// 音の出し方を自分で決める。
    /// - 電話モード（voiceChat）にしない＝音楽が電話っぽい音・小さい音にならない
    /// - AirPods などは高音質のまま（マイクは iPhone 本体のものを使う）
    /// - アプリの音楽（サンクラ）と混ぜて鳴らす
    private func configureSession() {
        AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playAndRecord, mode: .default,
                           options: [.defaultToSpeaker, .allowBluetoothA2DP, .allowAirPlay, .mixWithOthers])
        try? s.setActive(true)
    }

    private func headphonesConnected() -> Bool {
        let wired: [AVAudioSession.Port] = [.headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .usbAudio]
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { wired.contains($0.portType) }
    }

    private func applyVoiceVolume() {
        guard let room else { return }
        for p in room.remoteParticipants.values {
            for pub in p.audioTracks { (pub.track as? RemoteAudioTrack)?.volume = voiceVolume }
        }
    }

    private func tick() {
        guard let room else { return }
        applyVoiceVolume()
        let peers = room.remoteParticipants.count
        if peers > 0 { hadPeer = true }
        if hadPeer && peers == 0 { hadPeer = false; send(["type": "participantDisconnected"]) }
        if wasConnected && room.connectionState == .disconnected {
            Task { await hangUp() }
            send(["type": "disconnected"])
        }
    }

    private func hangUp() async {
        timer?.invalidate(); timer = nil
        guard let r = room else { return }
        room = nil
        wasConnected = false
        await r.disconnect()
        // 通話が終わっても音楽は止めない
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? s.setActive(true)
    }

    private func reply(_ id: String?, _ data: [String: Any]) {
        guard let id else { return }
        var d = data; d["id"] = id
        send(d)
    }

    private func send(_ data: [String: Any]) {
        guard let json = try? JSONSerialization.data(withJSONObject: data),
              let str = String(data: json, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.__otoNative && window.__otoNative(\(str))", completionHandler: nil)
    }
}
