import AVFoundation
import MediaPlayer
import LiveKit
import SwiftUI
import WebKit
import ObjectiveC
import MusicKit
import SpotifyiOS
import StoreKit
import CoreHaptics

// Otocloud のアプリ本体。
// 画面とふるまいは https://otocloud.app/app/ と同じものを、アプリの中でそのまま表示する。
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
            WebShell(url: URL(string: "https://otocloud.app/app/")!)
                .ignoresSafeArea()
                .onOpenURL { url in _ = SpotifyBridge.shared.handle(url) } // Spotify の許可から戻ってきた時
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
        web.hideInputAccessoryBar() // キーボードの上の「前・次・完了」のバーを出さない
        context.coordinator.webView = web
        context.coordinator.nativeCall.webView = web
        // アプリに戻ってきた時、しばらく経っていたら新しいサイトを読み直す
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.didBecomeActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.willResign),
                                               name: UIApplication.willResignActiveNotification, object: nil)
        // 画面収録・ミラーリング中は、画面の角の丸みを消す（収録した動画に角のふちが映らないように）
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.captureChanged),
                                               name: UIScreen.capturedDidChangeNotification, object: nil)
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

        @objc func captureChanged() { tellCapture() }
        func tellCapture() {
            let on = UIScreen.main.isCaptured
            webView?.evaluateJavaScript("document.documentElement.classList.toggle('captured', \(on ? "true" : "false"))", completionHandler: nil)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { tellCapture() }

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
            decisionHandler(origin.host == "on-pa.net" || origin.host == "otocloud.app" ? .grant : .prompt)
        }

        // iPhoneの傾き（四角いジャケットが傾きに合わせて動く）：Otocloud のページなら、聞かずに許可する
        @available(iOS 15.0, *)
        func webView(_ webView: WKWebView,
                     requestDeviceOrientationAndMotionPermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(origin.host == "on-pa.net" || origin.host == "otocloud.app" ? .grant : .prompt)
        }

        // 新しいタブで開こうとするリンクは、同じ画面で開く
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            // Otocloud 以外（SoundCloud など）は、外のアプリ／Safari で開く。アプリの画面は Otocloud のまま
            if let u = navigationAction.request.url, let h = u.host, !h.hasSuffix("on-pa.net") && !h.hasSuffix("otocloud.app") {
                UIApplication.shared.open(u)
                return nil
            }
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }

        // Otocloud 以外のページ（SoundCloud のログインなど）は、時計や電池の下に潜らないよう、上をあける
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            let h = webView.url?.host ?? ""
            let ours = h.hasSuffix("on-pa.net") || h.hasSuffix("otocloud.app")
            webView.scrollView.contentInsetAdjustmentBehavior = ours ? .never : .always
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
    let radio = Radio()
    let am = AppleMusic()
    private var amHooked = false
    private var room: Room?
    private var timer: Timer?
    private var voiceVolume: Double = 1
    private var hadPeer = false
    private var wasConnected = false
    var inCall: Bool { room != nil }

    private var wantHeadphones = false
    private var usingHFP = false

    override init() {
        super.init()
        // LiveKit に音の設定を勝手に変えさせない（アプリ起動時に一度だけ）
        AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false
        AudioManager.shared.audioSession.isAutomaticDeactivationEnabled = false
        NotificationCenter.default.addObserver(self, selector: #selector(routeChanged(_:)),
                                               name: AVAudioSession.routeChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted(_:)),
                                               name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(becameActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        setupRemoteCommands()
    }

    // ほかのアプリ（音声入力・録音・電話など）に音を取られて止まったら、終わったあとに続きから鳴らす
    private var isPlayingNow = false
    private var pausedAt = Date.distantPast
    private var resumeAfterInterruption = false
    @objc private func interrupted(_ n: Notification) {
        guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .began {
            // 止まる直前まで鳴っていたか（ページの「止まった」が先に届くこともあるので、2秒以内なら鳴っていたとみなす）
            resumeAfterInterruption = isPlayingNow || Date().timeIntervalSince(pausedAt) < 2
        } else if type == .ended, resumeAfterInterruption {
            revive()
        }
    }
    // 画面に「再生中」と出ていても音が止まっていることがあるので、同じ曲を同じ位置から読み込み直して鳴らす
    private func revive() {
        resumeAfterInterruption = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            try? AVAudioSession.sharedInstance().setActive(true)
            self?.webView?.evaluateJavaScript("window.__otoRevive ? window.__otoRevive() : (window.__otoRemote && window.__otoRemote('play'))", completionHandler: nil)
        }
    }
    // 「終わった」の知らせが来ないまま戻ってきたとき（アプリを開き直したとき）も、鳴っていたなら戻す
    @objc private func becameActive() {
        if resumeAfterInterruption { revive() }
    }

    // ページの中の埋め込み（SoundCloud）が、あとから「10秒送り」に戻してしまうので、鳴っている間は2秒ごとに「次の曲・前の曲」に戻し続ける
    private var guardTimer: Timer?
    private func guardRemoteCommands(_ on: Bool) {
        if !on { guardTimer?.invalidate(); guardTimer = nil; return }
        guard guardTimer == nil else { return }
        guardTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                let c = MPRemoteCommandCenter.shared()
                if c.skipForwardCommand.isEnabled || c.skipBackwardCommand.isEnabled || !c.nextTrackCommand.isEnabled {
                    self?.setupRemoteCommands()
                }
                if let info = self?.lastInfo, (MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String) != (info[MPMediaItemPropertyTitle] as? String) {
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                }
            }
        }
    }
    private var lastInfo: [String: Any]?

    // ロック画面・コントロールセンター：「10秒送り・戻し」を消して「次の曲・前の曲」にする。押したらページに伝える
    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.skipForwardCommand.isEnabled = false
        c.skipBackwardCommand.isEnabled = false
        c.seekForwardCommand.isEnabled = false
        c.seekBackwardCommand.isEnabled = false
        let hook: (MPRemoteCommand, String) -> Void = { cmd, name in
            cmd.isEnabled = true
            cmd.removeTarget(nil)
            cmd.addTarget { [weak self] _ in
                Task { @MainActor in
                    self?.webView?.evaluateJavaScript("window.__otoRemote && window.__otoRemote('\(name)')", completionHandler: nil)
                }
                return .success
            }
        }
        hook(c.nextTrackCommand, "next")
        hook(c.previousTrackCommand, "prev")
        hook(c.playCommand, "play")
        hook(c.pauseCommand, "pause")
        hook(c.togglePlayPauseCommand, "toggle")
    }

    private var artURL = ""
    private var artImage: MPMediaItemArtwork?
    /// ロック画面に、曲名・アーティスト・ジャケット・長さを出す
    private func setNowPlaying(_ b: [String: Any]) {
        setupRemoteCommands() // ページ側が上書きしていたら、もう一度「次の曲・前の曲」に戻す
        let playingNow = b["playing"] as? Bool ?? false
        if isPlayingNow && !playingNow { pausedAt = Date() }
        isPlayingNow = playingNow
        guardRemoteCommands(playingNow)
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: b["title"] as? String ?? "",
            MPMediaItemPropertyArtist: b["artist"] as? String ?? "",
            MPMediaItemPropertyPlaybackDuration: b["duration"] as? Double ?? 0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: b["elapsed"] as? Double ?? 0,
            MPNowPlayingInfoPropertyPlaybackRate: (b["playing"] as? Bool ?? false) ? 1.0 : 0.0,
        ]
        let url = b["artwork"] as? String ?? ""
        if url == artURL, let a = artImage { info[MPMediaItemPropertyArtwork] = a }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        lastInfo = info
        if url != artURL, let u = URL(string: url), url.hasPrefix("https://") {
            artURL = url; artImage = nil
            Task {
                guard let (data, _) = try? await URLSession.shared.data(from: u), let img = UIImage(data: data) else { return }
                let art = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
                await MainActor.run {
                    guard self.artURL == url else { return }
                    self.artImage = art
                    var cur = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                    cur[MPMediaItemPropertyArtwork] = art
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = cur
                    self.lastInfo?[MPMediaItemPropertyArtwork] = art
                }
            }
        }
    }

    static func routeText() -> String {
        let s = AVAudioSession.sharedInstance()
        let o = s.currentRoute.outputs.map { "\($0.portType.rawValue)(\($0.portName))" }.joined(separator: ",")
        let i = s.currentRoute.inputs.map { "\($0.portType.rawValue)" }.joined(separator: ",")
        return "cat=\(s.category.rawValue) mode=\(s.mode.rawValue) opts=\(s.categoryOptions.rawValue) out=[\(o)] in=[\(i)]"
    }
    private func log(_ m: String) { NSLog("[oto] %@ | %@", m, Self.routeText()) }

    /// 通話中に、イヤホンがあるのに音が本体に移ってしまったら、AirPodsのマイクも使う形に切り替えて、AirPodsに戻す
    @objc private func routeChanged(_ n: Notification) {
        let reason = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap { AVAudioSession.RouteChangeReason(rawValue: $0) }
        Task { @MainActor in
            self.log("route changed reason=\(reason.map { String($0.rawValue) } ?? "?")")
            self.send(self.earphones()) // イヤホンをつけた・外したを画面に知らせる（通話前の「イヤホンをつけて」画面用）
            if self.room != nil { self.updateMicBoost() }
            guard self.room != nil, self.wantHeadphones, !self.usingHFP else { return }
            if !self.headphonesConnected() && self.bluetoothAvailable() {
                self.usingHFP = true
                let s = AVAudioSession.sharedInstance()
                try? s.setCategory(.playAndRecord, mode: .default,
                                   options: [.allowBluetoothHFP, .allowBluetoothA2DP, .mixWithOthers])
                if let bt = s.availableInputs?.first(where: { [.bluetoothHFP, .bluetoothLE].contains($0.portType) }) {
                    try? s.setPreferredInput(bt)
                }
                self.log("fallback to bluetooth HFP")
            }
        }
    }
    private func bluetoothAvailable() -> Bool {
        (AVAudioSession.sharedInstance().availableInputs ?? []).contains { [.bluetoothHFP, .bluetoothLE].contains($0.portType) }
    }

    // ページからのお願い
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let op = body["op"] as? String else { return }
        let id = body["id"] as? String
        Task { @MainActor in
            do {
                var result: [String: Any] = ["ok": true]
                switch op {
                case "connect":
                    voiceFirst = body["voiceFirst"] as? Bool ?? true
                    try await connect(url: body["url"] as? String ?? "", token: body["token"] as? String ?? "")
                case "mic":
                    let on = body["on"] as? Bool ?? true
                    _ = try await room?.localParticipant.setMicrophone(enabled: on,
                                                                       captureOptions: capture,
                                                                       publishOptions: Self.publish)
                case "vol":
                    voiceVolume = max(0, min(6, (body["v"] as? Double) ?? 1))
                    applyVoiceVolume()
                case "disconnect":
                    await hangUp()
                case "route":
                    result = earphones()
                // ---- Apple Music（2人とも会員の時は、それぞれのiPhoneで同じ曲を流す）
                case "amStatus":
                    result = await am.status()
                case "amAuth":
                    result = await am.authorize()
                case "amArtists":
                    // 地球儀用：Apple Music でよく聴いているアーティスト
                    result = ["ok": true, "items": await am.topArtists()]
                case "amSearch":
                    result = ["items": try await am.search(body["q"] as? String ?? "")]
                case "amPlay":
                    hookAM()
                    try await am.play(id: body["trackId"] as? String ?? "", at: body["at"] as? Double ?? 0, autoplay: body["autoplay"] as? Bool ?? true)
                    result = ["ok": true, "duration": am.duration]
                case "amPause": am.pause()
                case "amResume": await am.resume()
                case "amSeek": am.seek(body["t"] as? Double ?? 0)
                case "amStop": am.stop()
                // ---- Spotify（Premium の人。再生は iPhone の Spotify アプリで、Otocloud はリモコン）
                case "spStatus":
                    result = SpotifyBridge.shared.status()
                case "spLogin":
                    hookSP()
                    let ok = await SpotifyBridge.shared.login()
                    result = SpotifyBridge.shared.status().merging(["ok": ok]) { $1 }
                case "spPlay":
                    hookSP()
                    let ok = await SpotifyBridge.shared.play(uri: body["uri"] as? String ?? "", at: body["at"] as? Double ?? 0, force: body["force"] as? Bool ?? false)
                    result = ["ok": ok]
                case "spToken":
                    // 検索用の合鍵。期限が近ければ、Spotify を開かずに裏で更新してから返す
                    result = ["ok": true, "token": await SpotifyBridge.shared.freshToken()]
                case "spSetClient":
                    // 自分の Client ID を保存（空なら Otocloud の鍵に戻す）。次にアプリを開いた時から効く
                    let v = (body["id"] as? String ?? "").trimmingCharacters(in: .whitespaces).lowercased()
                    if v.isEmpty { UserDefaults.standard.removeObject(forKey: "spClientID") } else { UserDefaults.standard.set(v, forKey: "spClientID") }
                    UserDefaults.standard.removeObject(forKey: "spSession")
                    // その場で新しい鍵に切りかえる（開き直し不要）
                    SpotifyBridge.shared.shutdown()
                    SpotifyBridge.shared = SpotifyBridge()
                    spHooked = false
                    hookSP()
                    result = ["ok": true, "id": SpotifyBridge.customClientID ?? ""]
                case "spGetClient":
                    result = ["ok": true, "id": SpotifyBridge.customClientID ?? "", "redirect": SpotifyBridge.redirect.absoluteString]
                case "spEnqueue":
                    // Otocloud の次の曲たちを、Spotify アプリの「次に再生」に入れる（眠っていても順番どおりに流れる）
                    let uris = (body["uris"] as? [String] ?? []).filter { $0.hasPrefix("spotify:track:") }
                    result = ["ok": true, "n": await SpotifyBridge.shared.enqueue(uris)]
                case "spNow":
                    result = await SpotifyBridge.shared.now()
                case "spWarm":
                    // 先につないでおく（Spotify は開かない）
                    result = ["ok": true, "connected": await SpotifyBridge.shared.warm()]
                case "spPause": SpotifyBridge.shared.pause()
                case "spResume": SpotifyBridge.shared.resume()
                case "spSeek": SpotifyBridge.shared.seek(body["t"] as? Double ?? 0)
                // ---- 触った感じ（ハプティクス）：スライドや切りかえの「ククッ」
                case "nowPlaying":
                    setNowPlaying(body)
                // ---- Bandcamp：公式の埋め込みプレーヤーを見えないところで開いて、その中の音を操作する
                case "bcLoad":
                    BandcampEngine.shared.host = webView
                    result = ["ok": BandcampEngine.shared.load(body["url"] as? String ?? "", autoplay: body["play"] as? Bool ?? true)]
                case "bcPlay": BandcampEngine.shared.play()
                case "bcPause": BandcampEngine.shared.pause()
                case "bcSeek": BandcampEngine.shared.seek(body["t"] as? Double ?? 0)
                case "bcStop": BandcampEngine.shared.stop()
                case "haptic":
                    Haptics.play(body["k"] as? String ?? "tick")
                case "review":
                    // App Store の評価のお願い（出すかどうか・回数はiPhoneが決める。TestFlightでは出ない）
                    if let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
                        AppStore.requestReview(in: scene)
                    }
                case "open":
                    // SoundCloud の曲のページを、SoundCloud アプリ（なければ Safari）で開く
                    if let str = body["url"] as? String, let u = URL(string: str), let h = u.host,
                       h == "soundcloud.com" || h.hasSuffix(".soundcloud.com") || h.hasSuffix(".bandcamp.com") || h == "developer.spotify.com" || h == "open.spotify.com" || h == "genius.com" {
                        await UIApplication.shared.open(u)
                        result = ["ok": true, "opened": true]
                    }
                // ---- ラジオ（声だけ録音＋曲の記録）
                case "recStart":
                    result = try radio.start()
                case "recStop":
                    result = try await radio.stop(cues: body["cues"] ?? [Any](), title: body["title"] as? String ?? "Radio")
                case "recList":
                    result = ["items": radio.list()]
                case "recPlay":
                    result = try radio.play(id: body["rid"] as? String ?? "") { [weak self] t, playing in
                        self?.send(["type": "radioTime", "t": t, "playing": playing])
                    }
                case "recPause": radio.pause()
                case "recResume": radio.resume()
                case "recSeek": radio.seek(to: body["t"] as? Double ?? 0)
                case "recEnd": radio.endPlayback()
                case "recShare":
                    radio.share(id: body["rid"] as? String ?? "", from: webView)
                case "recDelete":
                    radio.delete(id: body["rid"] as? String ?? "")
                default: break
                }
                reply(id, result)
            } catch {
                let denied = AVAudioApplication.shared.recordPermission == .denied
                reply(id, ["error": error.localizedDescription, "name": denied ? "NotAllowedError" : "Error"])
            }
        }
    }

    // 声の送り方：ふつうの通話（24kbps）より高い音質で、無音の間も途切れさせない
    private var capture = AudioCaptureOptions(echoCancellation: true, autoGainControl: true, noiseSuppression: true)
    static let publish = AudioPublishOptions(encoding: AudioEncoding(maxBitrate: 64000), dtx: false, red: true)

    /// AirPods などの Bluetooth の時、声を優先するか（AirPods のマイクを使う。その間、音楽は電話の音質になる）
    private var voiceFirst = true
    private func bluetoothOut() -> Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE].contains($0.portType) }
    }

    private func connect(url: String, token: String) async throws {
        await hangUp()
        // 声を優先：Bluetooth のイヤホンのマイクで話す（口の近くで拾うので、はっきり・大きく届く）
        if voiceFirst && bluetoothOut() {
            log("connect voice-first (bluetooth mic)")
            do { try AudioManager.shared.setPlatformVoiceProcessingAllowed(true) } catch { log("vp allow failed: \(error)") }
            capture = AudioCaptureOptions(echoCancellation: true, autoGainControl: true, noiseSuppression: true)
            AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false
            let s = AVAudioSession.sharedInstance()
            try? s.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .mixWithOthers])
            try? s.setActive(true)
            if let bt = s.availableInputs?.first(where: { [.bluetoothHFP, .bluetoothLE].contains($0.portType) }) { try? s.setPreferredInput(bt) }
            wantHeadphones = true; usingHFP = true
            AudioManager.shared.duckingLevel = .min
            AudioManager.shared.isAdvancedDuckingEnabled = false
            let room = Room(); self.room = room; hadPeer = false; wasConnected = false
            do {
                try await room.connect(url: url, token: token)
                wasConnected = true
                try await room.localParticipant.setMicrophone(enabled: true, captureOptions: capture, publishOptions: Self.publish)
            } catch { log("connect error \(error)"); await hangUp(); throw error }
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
            return
        }
        // AirPodsなどがつながっている時は、iPhoneの「通話用の音の処理」を使わない。
        // それを使うと、iPhoneが音をAirPodsから本体のスピーカーに勝手に切り替えてしまうため。
        // （イヤホンなら音が相手に返らないので、その処理はいらない）
        let hp = headphonesConnected()
        wantHeadphones = hp; usingHFP = false
        log("connect start headphones=\(hp)")
        do { try AudioManager.shared.setPlatformVoiceProcessingAllowed(!hp) } catch { log("vp allow failed: \(error)") }
        capture = AudioCaptureOptions(echoCancellation: !hp, autoGainControl: true, noiseSuppression: true)
        configureSession()
        updateMicBoost()
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
            log("connected")
            try await room.localParticipant.setMicrophone(enabled: true, captureOptions: capture, publishOptions: Self.publish)
            log("mic on")
        } catch {
            log("connect error \(error)")
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
        log("session set")
    }

    private var spHooked = false
    private func hookSP() {
        guard !spHooked else { return }
        spHooked = true
        SpotifyBridge.shared.onEvent = { [weak self] e in self?.send(e) }
    }

    private func hookAM() {
        guard !amHooked else { return }
        amHooked = true
        am.onTick = { [weak self] t, playing in self?.send(["type": "amTime", "t": t, "playing": playing]) }
        am.onEnded = { [weak self] in self?.send(["type": "amEnded"]) }
    }

    /// 今イヤホン（有線・AirPodsなど）から音が出ているか、と、その名前
    private func earphones() -> [String: Any] {
        let wired: [AVAudioSession.Port] = [.headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .usbAudio]
        let out = AVAudioSession.sharedInstance().currentRoute.outputs.first { wired.contains($0.portType) }
        return ["type": "route", "ok": true, "hp": out != nil, "name": out?.portName ?? ""]
    }

    /// 有線イヤホンのマイクを確実に使い、声が小さいので持ち上げる（それ以外のマイクはそのまま）
    private let micBoost = MicBoost()
    private func updateMicBoost() {
        let s = AVAudioSession.sharedInstance()
        if let wired = s.availableInputs?.first(where: { $0.portType == .headsetMic }) { try? s.setPreferredInput(wired) }
        let wiredMic = s.currentRoute.inputs.contains { $0.portType == .headsetMic }
        micBoost.gain = wiredMic ? 2.8 : 1
        if AudioManager.shared.capturePostProcessingDelegate == nil { AudioManager.shared.capturePostProcessingDelegate = micBoost }
        log("mic boost \(micBoost.gain)")
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
        log("hang up")
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

// MARK: - ラジオ（通話の声だけを録音して、どの曲を流したかの記録と一緒に、このiPhoneに保存する）
// 曲そのものは録らない（再生する時にSoundCloudからもう一度流す）。サーバーには何も置かない。

/// LiveKit から届く音を、そのままファイルに書く係
final class PCMWriter: NSObject, AudioRenderer, @unchecked Sendable {
    let url: URL
    private var file: AVAudioFile?
    private let lock = NSLock()
    private(set) var firstAt: Date?
    init(url: URL) { self.url = url }
    func render(pcmBuffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        if file == nil {
            let f = pcmBuffer.format
            file = try? AVAudioFile(forWriting: url, settings: f.settings, commonFormat: f.commonFormat, interleaved: f.isInterleaved)
            firstAt = Date()
        }
        try? file?.write(from: pcmBuffer)
    }
    func close() { lock.lock(); file = nil; lock.unlock() }
}

@MainActor
final class Radio {
    private var dir: URL?
    private var mine: PCMWriter?
    private var theirs: PCMWriter?
    private var startAt = Date()
    private var player: AVAudioPlayer?
    private var timer: Timer?

    private var root: URL {
        let u = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Radio", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func start() throws -> [String: Any] {
        if dir != nil { return ["startedAt": startAt.timeIntervalSince1970 * 1000] }
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let d = root.appendingPathComponent(f.string(from: Date()), isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        dir = d
        startAt = Date()
        let m = PCMWriter(url: d.appendingPathComponent("me.caf"))
        let t = PCMWriter(url: d.appendingPathComponent("them.caf"))
        mine = m; theirs = t
        AudioManager.shared.add(localAudioRenderer: m)
        AudioManager.shared.add(remoteAudioRenderer: t)
        NSLog("[oto] radio start %@", d.lastPathComponent)
        return ["startedAt": startAt.timeIntervalSince1970 * 1000, "rid": d.lastPathComponent]
    }

    func stop(cues: Any, title: String) async throws -> [String: Any] {
        guard let d = dir, let m = mine, let t = theirs else { return ["ok": false] }
        AudioManager.shared.remove(localAudioRenderer: m)
        AudioManager.shared.remove(remoteAudioRenderer: t)
        m.close(); t.close()
        dir = nil; mine = nil; theirs = nil
        // 2人の声を1つの音声ファイルにまとめる（始まった時間のずれも合わせる）
        let comp = AVMutableComposition()
        for w in [m, t] {
            guard let first = w.firstAt, FileManager.default.fileExists(atPath: w.url.path) else { continue }
            let asset = AVURLAsset(url: w.url)
            guard let src = (try await asset.loadTracks(withMediaType: .audio)).first else { continue }
            let dur = try await asset.load(.duration)
            let tr = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            let at = CMTime(seconds: max(0, first.timeIntervalSince(startAt)), preferredTimescale: 600)
            try tr?.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: src, at: at)
        }
        let out = d.appendingPathComponent("voice.m4a")
        if let ex = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetAppleM4A) {
            try? FileManager.default.removeItem(at: out)
            ex.outputURL = out
            ex.outputFileType = .m4a
            await ex.export()
        }
        let duration = Date().timeIntervalSince(startAt)
        let info: [String: Any] = ["title": title, "date": startAt.timeIntervalSince1970 * 1000, "duration": duration, "cues": cues]
        let data = try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted])
        try data.write(to: d.appendingPathComponent("radio.json"))
        try? FileManager.default.removeItem(at: m.url); try? FileManager.default.removeItem(at: t.url)
        NSLog("[oto] radio saved %@ %.0fs", d.lastPathComponent, duration)
        return ["rid": d.lastPathComponent, "duration": duration]
    }

    func list() -> [[String: Any]] {
        let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return items.compactMap { u -> [String: Any]? in
            guard let d = try? Data(contentsOf: u.appendingPathComponent("radio.json")),
                  var j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
            j["cues"] = nil; j["rid"] = u.lastPathComponent
            return j
        }.sorted { (($0["date"] as? Double) ?? 0) > (($1["date"] as? Double) ?? 0) }
    }

    func play(id: String, onTime: @escaping (Double, Bool) -> Void) throws -> [String: Any] {
        endPlayback()
        let d = root.appendingPathComponent(id, isDirectory: true)
        let j = (try JSONSerialization.jsonObject(with: Data(contentsOf: d.appendingPathComponent("radio.json"))) as? [String: Any]) ?? [:]
        let p = try AVAudioPlayer(contentsOf: d.appendingPathComponent("voice.m4a"))
        p.prepareToPlay(); p.play()
        player = p
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let p = self?.player else { return }
                onTime(p.currentTime, p.isPlaying)
            }
        }
        return ["cues": j["cues"] ?? [], "title": j["title"] ?? "", "duration": p.duration]
    }
    func pause() { player?.pause() }
    func resume() { player?.play() }
    func seek(to t: Double) { player?.currentTime = max(0, t) }
    func endPlayback() { timer?.invalidate(); timer = nil; player?.stop(); player = nil }

    func share(id: String, from web: WKWebView?) {
        let d = root.appendingPathComponent(id, isDirectory: true)
        let files = [d.appendingPathComponent("voice.m4a"), d.appendingPathComponent("radio.json")].filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty, let vc = web?.window?.rootViewController else { return }
        let a = UIActivityViewController(activityItems: files, applicationActivities: nil)
        a.popoverPresentationController?.sourceView = web
        var top = vc; while let p = top.presentedViewController { top = p }
        top.present(a, animated: true)
    }
    func delete(id: String) {
        guard !id.isEmpty, !id.contains("/") else { return }
        try? FileManager.default.removeItem(at: root.appendingPathComponent(id, isDirectory: true))
    }
}

// MARK: - キーボードの上のバー（前の欄・次の欄・完了）を消す
// 入力欄を行き来するためのiPhone標準のバー。このアプリでは使わないので出さない。
extension WKWebView {
    func hideInputAccessoryBar() {
        guard let content = scrollView.subviews.first(where: { String(describing: type(of: $0)).hasPrefix("WKContent") }),
              let base: AnyClass = object_getClass(content) else { return }
        let name = "\(NSStringFromClass(base))_OtoNoAccessory"
        var cls: AnyClass? = NSClassFromString(name)
        if cls == nil, let c = objc_allocateClassPair(base, name, 0) {
            let block: @convention(block) (AnyObject) -> UIView? = { _ in nil }
            class_addMethod(c, #selector(getter: UIResponder.inputAccessoryView), imp_implementationWithBlock(block), "@@:")
            // 新しいiOSでは、バーが別の入り口（inputAccessoryViewController）から出てくるので、そっちも空にする
            let vcBlock: @convention(block) (AnyObject) -> UIInputViewController? = { _ in nil }
            class_addMethod(c, #selector(getter: UIResponder.inputAccessoryViewController), imp_implementationWithBlock(vcBlock), "@@:")
            objc_registerClassPair(c)
            cls = c
        }
        if let cls { object_setClass(content, cls) }
    }
}


// MARK: - Apple Music（MusicKit）
// Apple Music の会員の人は、Apple Music の曲をこのアプリの中で流せる。
// 一緒に聴く時は、2人のiPhoneがそれぞれ自分の Apple Music で同じ曲を同じ位置から流す（音楽を相手に送らない）。
@MainActor
final class AppleMusic {
    private let player = ApplicationMusicPlayer.shared
    private var timer: Timer?
    private var current: Song?
    private var lastT: Double = 0
    private var wasPlaying = false
    var onTick: ((Double, Bool) -> Void)?
    var onEnded: (() -> Void)?

    var duration: Double { current?.duration ?? 0 }
    private var playing: Bool { player.state.playbackStatus == .playing }

    func status() async -> [String: Any] {
        let auth = MusicAuthorization.currentStatus
        var canPlay = false
        if auth == .authorized, let sub = try? await MusicSubscription.current { canPlay = sub.canPlayCatalogContent }
        return ["ok": true, "auth": String(describing: auth), "canPlay": canPlay]
    }

    func authorize() async -> [String: Any] {
        _ = await MusicAuthorization.request()
        return await status()
    }

    /// よく聴いているアーティスト（よく聴く曲・最近聴いた曲・ライブラリ）。名前と画像だけ
    func topArtists() async -> [[String: Any]] {
        guard MusicAuthorization.currentStatus == .authorized else { return [] }
        var score: [String: (name: String, art: String, n: Int)] = [:]
        func add(_ name: String, _ art: String, _ w: Int) {
            let n = name.trimmingCharacters(in: .whitespaces); guard !n.isEmpty else { return }
            let k = n.lowercased()
            if var e = score[k] { e.n += w; if e.art.isEmpty { e.art = art }; score[k] = e } else { score[k] = (n, art, w) }
        }
        // よく聴いている（ヘビーローテーション）
        if let url = URL(string: "https://api.music.apple.com/v1/me/history/heavy-rotation?limit=10"),
           let r = try? await MusicDataRequest(urlRequest: URLRequest(url: url)).response(),
           let j = try? JSONSerialization.jsonObject(with: r.data) as? [String: Any],
           let data = j["data"] as? [[String: Any]] {
            for d in data {
                guard let a = d["attributes"] as? [String: Any], let n = a["artistName"] as? String else { continue }
                var art = ""
                if let aw = a["artwork"] as? [String: Any], let u = aw["url"] as? String { art = u.replacingOccurrences(of: "{w}", with: "200").replacingOccurrences(of: "{h}", with: "200") }
                add(n, art, 5)
            }
        }
        // 最近聴いた曲
        if let r = try? await MusicRecentlyPlayedRequest<Song>().response() {
            for song in r.items.prefix(60) { add(song.artistName, song.artwork?.url(width: 200, height: 200)?.absoluteString ?? "", 2) }
        }
        // ライブラリのアーティスト
        var lib = MusicLibraryRequest<Artist>()
        lib.limit = 80
        if let r = try? await lib.response() {
            for a in r.items { add(a.name, a.artwork?.url(width: 200, height: 200)?.absoluteString ?? "", 1) }
        }
        return score.values.sorted { $0.n > $1.n }.prefix(60).map { ["name": $0.name, "art": $0.art, "n": $0.n] }
    }

    func search(_ q: String) async throws -> [[String: Any]] {
        guard !q.isEmpty else { return [] }
        var req = MusicCatalogSearchRequest(term: q, types: [Song.self])
        req.limit = 25
        let res = try await req.response()
        return res.songs.map { s in
            ["id": s.id.rawValue, "title": s.title, "artist": s.artistName,
             "artwork": s.artwork?.url(width: 500, height: 500)?.absoluteString ?? "",
             "duration": Int((s.duration ?? 0) * 1000), "isrc": s.isrc ?? "",
             "url": s.url?.absoluteString ?? ""]
        }
    }

    func play(id: String, at: Double, autoplay: Bool) async throws {
        let req = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(id))
        let res = try await req.response()
        guard let song = res.items.first else { throw NSError(domain: "AppleMusic", code: 404, userInfo: [NSLocalizedDescriptionKey: "Song not found"]) }
        current = song
        player.queue = [song]
        try await player.prepareToPlay()
        if at > 0 { player.playbackTime = at }
        if autoplay { try await player.play() }
        lastT = at; wasPlaying = autoplay
        startTimer()
    }

    func pause() { player.pause() }
    func resume() async { try? await player.play() }
    func seek(_ t: Double) { player.playbackTime = t; lastT = t }
    func stop() { player.stop(); timer?.invalidate(); timer = nil; current = nil }

    // 再生位置を少しずつ画面に知らせる。曲の終わりも知らせる
    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let song = self.current else { return }
                let t = self.player.playbackTime, p = self.playing
                self.onTick?(t, p)
                let d = song.duration ?? 0
                if d > 0, self.wasPlaying, !p, self.lastT > d - 2 { self.wasPlaying = false; self.onEnded?() }
                if p { self.wasPlaying = true }
                self.lastT = t
            }
        }
    }
}


// MARK: - Spotify（iOS SDK）
// 曲を流すのは iPhone の Spotify アプリ。Otocloud はそれを操作するリモコン。
// 許可は最初の1回だけ（合鍵を保存して、期限が来たらサーバー経由で自動更新）。
// Spotify アプリが止まっている時だけ、一瞬 Spotify を開いて起こしてから戻ってくる。
final class SpotifyBridge: NSObject, SPTSessionManagerDelegate, SPTAppRemoteDelegate, SPTAppRemotePlayerStateDelegate {
    static var shared = SpotifyBridge()
    static let defaultClientID = "1ff4e8ebb2f94fb5a20149d697df21fc"
    /// 試験用（Labs）：自分の Spotify 開発者の Client ID を入れた人は、それで使う（鍵の交換はPKCE。Otocloud のサーバーは通さない）
    static var customClientID: String? {
        let v = (UserDefaults.standard.string(forKey: "spClientID") ?? "").trimmingCharacters(in: .whitespaces)
        return v.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil ? v : nil
    }
    static var clientID: String { customClientID ?? defaultClientID }
    static let redirect = URL(string: "app.otocloud://spotify-callback")!
    private let config: SPTConfiguration
    private lazy var sessionManager = SPTSessionManager(configuration: config, delegate: self)
    private lazy var remote: SPTAppRemote = {
        let r = SPTAppRemote(configuration: config, logLevel: .error)
        r.delegate = self
        return r
    }()
    var onEvent: (([String: Any]) -> Void)?
    private var loginWaiter: CheckedContinuation<Bool, Never>?
    private var connectWaiters: [CheckedContinuation<Bool, Never>] = []

    override init() {
        config = SPTConfiguration(clientID: SpotifyBridge.clientID, redirectURL: SpotifyBridge.redirect)
        if SpotifyBridge.customClientID == nil {
            config.tokenSwapURL = URL(string: "https://geocloud.icchasong.workers.dev/spotify/swap")
            config.tokenRefreshURL = URL(string: "https://geocloud.icchasong.workers.dev/spotify/refresh")
        }
        config.playURI = ""
        super.init()
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.sessionManager.session != nil else { return }
            Task { await self.afterReturn() }
        }
        if let d = UserDefaults.standard.data(forKey: "spSession"),
           let s = try? NSKeyedUnarchiver.unarchivedObject(ofClass: SPTSession.self, from: d) {
            sessionManager.session = s
        }
    }

    func freshToken() async -> String {
        guard let s = sessionManager.session else { return "" }
        if s.isExpired || s.expirationDate.timeIntervalSinceNow < 120 {
            sessionManager.renewSession()
            for _ in 0..<12 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if let n = sessionManager.session, !n.isExpired, n.expirationDate.timeIntervalSinceNow > 120 { break }
            }
        }
        return sessionManager.session?.accessToken ?? ""
    }

    func shutdown() {
        onEvent = nil
        if remote.isConnected { remote.disconnect() }
    }

    func status() -> [String: Any] {
        let s = sessionManager.session
        return ["ok": true, "linked": s != nil, "connected": remote.isConnected,
                "installed": sessionManager.isSpotifyAppInstalled, "token": s?.accessToken ?? "",
                "expires": (s?.expirationDate.timeIntervalSince1970 ?? 0) * 1000]
    }

    func login() async -> Bool {
        await withCheckedContinuation { c in
            loginWaiter = c
            DispatchQueue.main.async { self.sessionManager.initiateSession(with: [.appRemoteControl, .userReadPlaybackState, .userModifyPlaybackState, .streaming, .userFollowRead, .userTopRead, .userLibraryRead, .userLibraryModify, .playlistReadPrivate, .playlistReadCollaborative], options: .default, campaign: nil) }
        }
    }

    // Spotify から app.otocloud://spotify-callback で戻ってきた時
    func handle(_ url: URL) -> Bool {
        guard url.scheme == "app.otocloud" else { return false }
        _ = sessionManager.application(UIApplication.shared, open: url, options: [:])
        if let p = remote.authorizationParameters(from: url), let t = p["access_token"], !t.isEmpty {
            remote.connectionParameters.accessToken = t
            DispatchQueue.main.async { self.remote.connect() } // Spotify の部品は画面の係（メイン）で動かす
        }
        return true
    }

    private func saved(_ s: SPTSession) {
        if let d = try? NSKeyedArchiver.archivedData(withRootObject: s, requiringSecureCoding: true) {
            UserDefaults.standard.set(d, forKey: "spSession")
        }
        remote.connectionParameters.accessToken = s.accessToken
    }

    // つながっていなければつなぐ。Spotify が止まっていたら、その曲で起こす
    /// 起こすために Spotify を開いた時は、その時点でもう曲が流れ始めている（もう一度 play すると頭から鳴り直すので、しない）
    private var wokeWith: String?
    /// さっき「つながらなかった」＝ Spotify が眠っている。その時は、つながるのを待たずにすぐ起こす（久しぶりに開いた時に速く）
    private var asleepAt: Date?
    /// 最後に Spotify を開いて起こした時。起こした直後は、つながるのに少し時間がかかるだけなので、もう一度開かない（何回も Spotify が開くのを防ぐ）
    private var wokeAt: Date?
    private var wokeRecently: Bool { wokeAt.map { Date().timeIntervalSince($0) < 25 } ?? false }
    /// つながるのを待つ（Spotify は開かない）
    private func waitConnect(_ sec: Double) async -> Bool {
        if remote.isConnected { return true }
        remote.connectionParameters.accessToken = sessionManager.session?.accessToken
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            connectWaiters.append(c)
            DispatchQueue.main.async { self.remote.connect() }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, !self.connectWaiters.isEmpty, !self.remote.isConnected else { return }
                self.finishConnect(false)
            }
        }
    }
    /// 起こした曲と位置。Otocloud に戻ってきた時に、本当に鳴っているかを確かめるため
    private var wakeURI: String?
    private var wakePos: Double = 0
    private var wakeTries = 0
    /// Otocloud に戻ってきた時：Spotify とつなぎ、起こした曲が鳴っていなければ鳴らす。
    /// つながらない（Spotify が鳴り始める前に眠ってしまった）時だけ、もう1回だけ起こす（全部で2回まで）
    func afterReturn() async {
        let ok = remote.isConnected ? true : await warm()
        guard let u = wakeURI, let w = wokeAt, Date().timeIntervalSince(w) < 45 else { return }
        if ok {
            wakeURI = nil
            await ensurePlaying(u, at: wakePos)
        } else if wakeTries < 2 {
            wakeTries += 1; wokeAt = Date(); wokeWith = u
            DispatchQueue.main.async { self.remote.authorizeAndPlayURI(u) { _ in } }
        } else { wakeURI = nil }
    }
    /// つながっている時に、その曲が鳴っているか確かめて、止まっていたり別の曲なら流し直す
    private func ensurePlaying(_ uri: String, at: Double) async {
        guard let api = remote.playerAPI else { return }
        let st: SPTAppRemotePlayerState? = await withCheckedContinuation { c in
            var done = false
            api.getPlayerState { r, _ in DispatchQueue.main.async { if !done { done = true; c.resume(returning: r as? SPTAppRemotePlayerState) } } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if !done { done = true; c.resume(returning: nil) } }
        }
        if let st, st.track.uri == uri, !st.isPaused { return }
        api.play(uri, callback: { _, err in
            if err == nil, at > 0.5 { self.remote.playerAPI?.seek(toPosition: Int(at * 1000), callback: nil) }
        })
    }
    private func ensureConnected(playURI: String, at: Double = 0, force: Bool = false) async -> Bool {
        wokeWith = nil
        if remote.isConnected { asleepAt = nil; return true }
        // ついさっき起こしたばかり：開き直さずに、つながるのを待つだけ（▶ を押し直した時は、もう一度起こしてよい）
        if wokeRecently && !force { return await waitConnect(6) }
        guard let s = sessionManager.session else { return false }
        if s.isExpired {
            sessionManager.renewSession()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        remote.connectionParameters.accessToken = sessionManager.session?.accessToken
        let sleeping = asleepAt.map { Date().timeIntervalSince($0) < 120 } ?? false
        let ok = sleeping ? false : await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            connectWaiters.append(c)
            DispatchQueue.main.async { self.remote.connect() } // Spotify の部品は画面の係（メイン）で動かす
            // Spotify が起きていれば1秒もかからずにつながる。2秒待ってだめなら、すぐ起こしに行く（前は5秒待っていて遅かった）
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, !self.connectWaiters.isEmpty, !self.remote.isConnected else { return }
                self.finishConnect(false)
            }
        }
        if ok { return true }
        // Spotify アプリが動いていない：一瞬開いて、その曲から流し始めてもらう
        let opened = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            var done = false
            DispatchQueue.main.async { self.remote.authorizeAndPlayURI(playURI) { ok in DispatchQueue.main.async { if !done { done = true; c.resume(returning: ok) } } } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { if !done { done = true; c.resume(returning: false) } }
        }
        guard opened else { return false }
        wakeTries = wokeRecently ? wakeTries + 1 : 1
        wokeWith = playURI; asleepAt = nil; wokeAt = Date(); wakeURI = playURI; wakePos = at
        // 曲はもう流れ始めているので、つながるのを待たずに「流せた」と返す（つなぐのは裏で）
        DispatchQueue.main.async { self.remote.connect() }
        return true
    }

    func play(uri: String, at: Double, force: Bool = false) async -> Bool {
        guard !uri.isEmpty, await ensureConnected(playURI: uri, at: at, force: force) else { return false }
        if wokeWith == uri { // 起こした時にもう流れ始めている：途中からの時だけ、つながったら位置を合わせる（待たずに返す）
            wokeWith = nil
            if at > 0.5 { Task { for _ in 0..<40 { if let api = self.remote.playerAPI, self.remote.isConnected { api.seek(toPosition: Int(at * 1000), callback: nil); return }; try? await Task.sleep(nanoseconds: 250_000_000) } } }
            return true
        }
        guard let api = remote.playerAPI else { return false }
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            api.play(uri, callback: { _, err in
                if at > 0.5 { self.remote.playerAPI?.seek(toPosition: Int(at * 1000), callback: nil) }
                c.resume(returning: err == nil)
            })
        }
    }
    /// Spotify を開かずに、つながるだけ試す（Spotify アプリが起きていれば一瞬でつながる）
    func warm() async -> Bool {
        if remote.isConnected { return true }
        guard let s = sessionManager.session else { return false }
        if s.isExpired { sessionManager.renewSession(); try? await Task.sleep(nanoseconds: 1_200_000_000) }
        remote.connectionParameters.accessToken = sessionManager.session?.accessToken
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            connectWaiters.append(c)
            DispatchQueue.main.async { self.remote.connect() } // Spotify の部品は画面の係（メイン）で動かす
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self, !self.connectWaiters.isEmpty, !self.remote.isConnected else { return }
                if !self.wokeRecently { self.asleepAt = Date() } // Spotify は眠っている：次に流す時はすぐ起こす（起こした直後は、つながるのが遅いだけなので数えない）
                self.finishConnect(false)
            }
        }
    }
    func enqueue(_ uris: [String]) async -> Int {
        guard !uris.isEmpty else { return 0 }
        var connected = remote.isConnected
        if !connected { connected = await warm() }
        guard connected, let api = remote.playerAPI else { return 0 }
        var n = 0
        for u in uris.prefix(6) {
            let ok = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                var done = false
                api.enqueueTrackUri(u) { _, err in DispatchQueue.main.async { if !done { done = true; c.resume(returning: err == nil) } } }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if !done { done = true; c.resume(returning: false) } }
            }
            if ok { n += 1 }
        }
        return n
    }
    /// 今の再生状態（曲・位置・止まっているか）
    func now() async -> [String: Any] {
        guard remote.isConnected, let api = remote.playerAPI else { return ["ok": true, "connected": false] }
        return await withCheckedContinuation { (c: CheckedContinuation<[String: Any], Never>) in
            var done = false
            api.getPlayerState { r, _ in
                DispatchQueue.main.async {
                    guard !done else { return }; done = true
                    if let st = r as? SPTAppRemotePlayerState {
                        c.resume(returning: ["ok": true, "connected": true, "uri": st.track.uri, "name": st.track.name, "artist": st.track.artist.name,
                                             "pos": Double(st.playbackPosition) / 1000, "dur": Double(st.track.duration) / 1000, "paused": st.isPaused])
                    } else { c.resume(returning: ["ok": true, "connected": true]) }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if !done { done = true; c.resume(returning: ["ok": true, "connected": true]) } }
        }
    }
    func pause() { remote.playerAPI?.pause(nil) }
    func resume() { remote.playerAPI?.resume(nil) }
    func seek(_ t: Double) { remote.playerAPI?.seek(toPosition: Int(t * 1000), callback: nil) }

    private func finishConnect(_ ok: Bool) {
        if ok { asleepAt = nil }
        let w = connectWaiters; connectWaiters = []
        w.forEach { $0.resume(returning: ok) }
    }

    // MARK: SPTSessionManagerDelegate
    func sessionManager(manager: SPTSessionManager, didInitiate session: SPTSession) {
        DispatchQueue.main.async {
            self.saved(session)
            self.loginWaiter?.resume(returning: true); self.loginWaiter = nil
        }
    }
    func sessionManager(manager: SPTSessionManager, didFailWith error: Error) {
        DispatchQueue.main.async {
            self.loginWaiter?.resume(returning: false); self.loginWaiter = nil
        }
    }
    func sessionManager(manager: SPTSessionManager, didRenew session: SPTSession) {
        DispatchQueue.main.async { self.saved(session) }
    }

    // MARK: SPTAppRemoteDelegate
    func appRemoteDidEstablishConnection(_ appRemote: SPTAppRemote) {
        appRemote.playerAPI?.delegate = self
        appRemote.playerAPI?.subscribe(toPlayerState: nil)
        finishConnect(true)
        onEvent?(["type": "spState", "connected": true])
        // つながった時点で、もう流れている曲の状態もすぐ知らせる（変化がないと知らせが来ないため）
        appRemote.playerAPI?.getPlayerState { [weak self] r, _ in if let st = r as? SPTAppRemotePlayerState { self?.playerStateDidChange(st) } }
    }
    func appRemote(_ appRemote: SPTAppRemote, didFailConnectionAttemptWithError error: Error?) { finishConnect(false) }
    func appRemote(_ appRemote: SPTAppRemote, didDisconnectWithError error: Error?) { onEvent?(["type": "spState", "connected": false]) }

    // MARK: SPTAppRemotePlayerStateDelegate
    func playerStateDidChange(_ s: SPTAppRemotePlayerState) {
        onEvent?(["type": "spState", "connected": true, "uri": s.track.uri, "name": s.track.name,
                  "artist": s.track.artist.name, "pos": Double(s.playbackPosition) / 1000,
                  "dur": Double(s.track.duration) / 1000, "paused": s.isPaused, "at": Date().timeIntervalSince1970 * 1000])
    }
}


// MARK: - ハプティクス（指に返ってくる、音のない手ごたえ）
@MainActor enum Haptics {
    static let sel = UISelectionFeedbackGenerator()
    static let soft = UIImpactFeedbackGenerator(style: .soft)
    static let light = UIImpactFeedbackGenerator(style: .light)
    static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    static let medium = UIImpactFeedbackGenerator(style: .medium)
    static let heavy = UIImpactFeedbackGenerator(style: .heavy)
    static let note = UINotificationFeedbackGenerator()
    static func play(_ k: String) {
        switch k {
        case "tick": sel.selectionChanged(); sel.prepare()            // ダイヤルの1目もり
        case "soft": soft.impactOccurred(intensity: 0.7); soft.prepare()
        case "light": light.impactOccurred(); light.prepare()
        case "rigid": rigid.impactOccurred(intensity: 0.8); rigid.prepare() // ボタンのカチッ
        case "thud": medium.impactOccurred(); medium.prepare()          // CDが入れかわる
        case "success": note.notificationOccurred(.success)
        case "medium": medium.impactOccurred(); medium.prepare()
        default:
            // 自分で作った手ごたえ（Core Haptics）。使えない端末では、近いふつうの手ごたえで代わりにする
            if let p = Custom.patterns[k], Custom.play(p) { return }
            if k.hasPrefix("star") || k.hasPrefix("heart") && k != "heartOff" { heavy.impactOccurred(intensity: 1.0); heavy.prepare() }
            else if k == "unheart" { soft.impactOccurred(intensity: 0.5); soft.prepare() }
            else { sel.selectionChanged() }
        }
    }

    /// Core Haptics：強さ（intensity）と鋭さ（sharpness）を時間に合わせて組み立てた、Otocloud だけの手ごたえ
    enum Custom {
        typealias Tap = (t: Double, i: Float, s: Float, d: Double) // 時間・強さ・鋭さ・長さ（0なら一瞬）
        static var engine: CHHapticEngine?
        static let patterns: [String: [Tap]] = [
            // ♡：ぷくっ（やわらかく膨らむ）→ ポンッ（はじける）→ ぷるっ（小さく戻る）
            "heart": [(0, 0.45, 0.15, 0.07), (0.09, 1.0, 0.55, 0), (0.2, 0.35, 0.35, 0)],
            // ♡（いま使う方）：ドクン、ドクン。1回目は深く重く「グッ」と沈む（強さいっぱい・鋭さ低め＋短い震え）、2回目はそれより少し軽く締める
            "heartDeep": [(0, 1.0, 0.08, 0.075), (0.03, 1.0, 0.3, 0), (0.17, 0.9, 0.42, 0), (0.17, 0.55, 0.06, 0.05)],
            // ♡を外す：しぼむ感じの、やわらかい1回
            "unheart": [(0, 0.4, 0.1, 0.09)],
            // ★：1つ増えるごとに、少しずつ強く・高く（コッ、コッ、コン）
            "star1": [(0, 0.5, 0.45, 0)], "star2": [(0, 0.6, 0.55, 0)], "star3": [(0, 0.7, 0.65, 0)],
            "star4": [(0, 0.82, 0.75, 0)], "star5": [(0, 1.0, 0.9, 0), (0.08, 0.5, 0.9, 0)],
            "star0": [(0, 0.3, 0.1, 0.05)],
        ]
        static func play(_ taps: [Tap]) -> Bool {
            guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return false }
            do {
                if engine == nil {
                    let e = try CHHapticEngine()
                    e.playsHapticsOnly = true
                    e.isAutoShutdownEnabled = true
                    e.resetHandler = { try? Custom.engine?.start() }
                    e.stoppedHandler = { _ in }
                    engine = e
                }
                try engine?.start()
                let events = taps.map { t -> CHHapticEvent in
                    let ps = [CHHapticEventParameter(parameterID: .hapticIntensity, value: t.i), CHHapticEventParameter(parameterID: .hapticSharpness, value: t.s)]
                    return t.d > 0 ? CHHapticEvent(eventType: .hapticContinuous, parameters: ps, relativeTime: t.t, duration: t.d)
                                   : CHHapticEvent(eventType: .hapticTransient, parameters: ps, relativeTime: t.t)
                }
                let player = try engine?.makePlayer(with: CHHapticPattern(events: events, parameters: []))
                try player?.start(atTime: CHHapticTimeImmediate)
                return true
            } catch { return false }
        }
    }
}


// MARK: - Bandcamp（公式の埋め込みプレーヤー）
// Bandcamp の埋め込みには、SoundCloud のような外から操作する仕組みがない。
// そこで、埋め込みプレーヤーを見えない WKWebView で直接開き、その中の <audio> を小さなスクリプトで操作して、
// 0.5秒ごとに状態（止まっているか・何秒か・長さ・終わったか）を読む。
// 考え方は Parachord（MIT License, Copyright (c) 2026 Jason Herskowitz）の bandcamp-embed-control.js を参考にした。
// 音は Bandcamp の公式プレーヤーがそのまま鳴らす（音を取り出したり保存したりはしない）。
@MainActor final class BandcampEngine: NSObject, WKNavigationDelegate {
    static let shared = BandcampEngine()
    weak var host: WKWebView?           // 状態を知らせる先（Otocloud のページ）
    private var web: WKWebView?
    private var timer: Timer?
    private var url = ""
    private var loaded = false, installed = false, clicked = false, autoplay = true
    private var startedAt = Date()

    private static let control = """
    (function(){ if (window.__oto) return true;
      function a(){ return document.querySelector('audio'); }
      var w = { el: null, ended: false, src: '' };
      function watch(el){ if (!el || w.el === el) return; w.el = el; w.ended = false; w.src = ''; el.addEventListener('ended', function(){ w.ended = true; }); }
      window.__oto = {
        start: function(){ var b = document.querySelector('#big_play_button'); if (!b) return false; watch(a()); b.click(); return true; },
        state: function(){ var el = a(); if (!el) return JSON.stringify({ audio:false, paused:true, ended:false, t:0, dur:0, err:null });
          watch(el);
          if (el.src) { if (!w.src) w.src = el.src; else if (w.src !== el.src && !w.ended) { w.ended = true; el.pause(); } }
          return JSON.stringify({ audio:true, hasSrc: !!el.src, paused: !!el.paused, ended: !!(w.ended || el.ended), t: Number(el.currentTime)||0, dur: Number(el.duration)||0, err: el.error ? el.error.code : null }); },
        play: function(){ var el = a(); if (el) el.play(); return !!el; },
        pause: function(){ var el = a(); if (el) el.pause(); return !!el; },
        seek: function(s){ var el = a(); if (el) el.currentTime = s; return !!el; }
      };
      return true; })()
    """

    private func ensure() -> WKWebView? {
        if let web { return web }
        let c = WKWebViewConfiguration()
        c.allowsInlineMediaPlayback = true
        c.mediaTypesRequiringUserActionForPlayback = []
        let v = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 470), configuration: c)
        v.navigationDelegate = self
        v.alpha = 0.01; v.isUserInteractionEnabled = false
        // 画面のどこかにいないと止められることがあるので、Otocloud の画面の裏にそっと置く
        host?.superview?.insertSubview(v, at: 0)
        web = v
        return v
    }

    /// Bandcamp の埋め込みの URL だけを受け付ける
    private static func valid(_ s: String) -> URL? {
        guard let u = URL(string: s), u.scheme == "https", u.host == "bandcamp.com",
              u.path.hasPrefix("/EmbeddedPlayer/track=") else { return nil }
        return u
    }

    func load(_ s: String, autoplay: Bool) -> Bool {
        guard let u = Self.valid(s), let v = ensure() else { return false }
        try? AVAudioSession.sharedInstance().setActive(true)
        url = u.absoluteString; loaded = false; installed = false; clicked = false; self.autoplay = autoplay; startedAt = Date()
        v.load(URLRequest(url: u))
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in Task { @MainActor in await self?.poll() } }
        return true
    }
    func play() { if !clicked { autoplay = true; return }; web?.evaluateJavaScript("window.__oto && __oto.play()") }
    func pause() { autoplay = false; web?.evaluateJavaScript("window.__oto && __oto.pause()") }
    func seek(_ t: Double) { guard t.isFinite else { return }; web?.evaluateJavaScript("window.__oto && __oto.seek(\(max(0, t)))") }
    func stop() {
        timer?.invalidate(); timer = nil; url = ""
        web?.evaluateJavaScript("window.__oto && __oto.pause()")
        web?.loadHTMLString("", baseURL: nil)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.loaded = true }
    }
    // 埋め込みのページの中で、bandcamp 以外の場所へ移動させない
    nonisolated func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let h = action.request.url?.host ?? ""
        let ok = action.request.url?.absoluteString == "about:blank" || h == "bandcamp.com" || h.hasSuffix(".bandcamp.com") || h.hasSuffix(".bcbits.com")
        let sub = action.targetFrame != nil && action.targetFrame?.isMainFrame == false
        Task { @MainActor in decisionHandler(ok || sub ? .allow : .cancel) }
    }

    private func poll() async {
        guard let v = web, loaded, v.url?.absoluteString == url else {
            if Date().timeIntervalSince(startedAt) > 20 { report(["error": "timeout"]); stop() }
            return
        }
        if !installed { installed = ((try? await v.evaluateJavaScript(Self.control)) as? Bool) == true }
        if installed && !clicked && autoplay {
            clicked = ((try? await v.evaluateJavaScript("__oto.start()")) as? Bool) == true
        }
        guard installed, let raw = (try? await v.evaluateJavaScript("__oto.state()")) as? String,
              let d = raw.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        var st: [String: Any] = [:]
        st["paused"] = (o["paused"] as? Bool) ?? true
        st["ended"] = (o["ended"] as? Bool) ?? false
        st["t"] = min(2_592_000, max(0, (o["t"] as? Double) ?? 0))
        st["dur"] = min(2_592_000, max(0, (o["dur"] as? Double) ?? 0))
        if let e = o["err"] as? Int { st["error"] = "media \(e)" }
        report(st)
        if (st["ended"] as? Bool) == true { timer?.invalidate(); timer = nil }
    }

    private func report(_ st: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: st), let j = String(data: d, encoding: .utf8) else { return }
        host?.evaluateJavaScript("window.__otoBC && window.__otoBC(\(j))")
    }
}


/// 送る前の声を持ち上げる。大きすぎる所は割れないよう、やわらかく抑える（tanh）
final class MicBoost: NSObject, AudioCustomProcessingDelegate, @unchecked Sendable {
    var gain: Float = 1
    func audioProcessingInitialize(sampleRate sampleRateHz: Int, channels: Int) {}
    func audioProcessingProcess(audioBuffer: LKAudioBuffer) {
        let g = gain
        if g == 1 { return }
        for ch in 0..<audioBuffer.channels {
            let p = audioBuffer.rawBuffer(forChannel: ch)
            for i in 0..<audioBuffer.frames { p[i] = tanhf(p[i] * g / 32768) * 32767 }
        }
    }
    func audioProcessingRelease() {}
}
