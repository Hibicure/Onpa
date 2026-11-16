import AVFoundation
import LiveKit
import SwiftUI
import WebKit
import ObjectiveC

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
        web.hideInputAccessoryBar() // キーボードの上の「前・次・完了」のバーを出さない
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
            // Otocloud 以外（SoundCloud など）は、外のアプリ／Safari で開く。アプリの画面は Otocloud のまま
            if let u = navigationAction.request.url, let h = u.host, !h.hasSuffix("on-pa.net") {
                UIApplication.shared.open(u)
                return nil
            }
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
    let radio = Radio()
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
                case "open":
                    // SoundCloud の曲のページを、SoundCloud アプリ（なければ Safari）で開く
                    if let str = body["url"] as? String, let u = URL(string: str), let h = u.host,
                       h == "soundcloud.com" || h.hasSuffix(".soundcloud.com") {
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

    private func connect(url: String, token: String) async throws {
        await hangUp()
        // AirPodsなどがつながっている時は、iPhoneの「通話用の音の処理」を使わない。
        // それを使うと、iPhoneが音をAirPodsから本体のスピーカーに勝手に切り替えてしまうため。
        // （イヤホンなら音が相手に返らないので、その処理はいらない）
        let hp = headphonesConnected()
        wantHeadphones = hp; usingHFP = false
        log("connect start headphones=\(hp)")
        do { try AudioManager.shared.setPlatformVoiceProcessingAllowed(!hp) } catch { log("vp allow failed: \(error)") }
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

    /// 今イヤホン（有線・AirPodsなど）から音が出ているか、と、その名前
    private func earphones() -> [String: Any] {
        let wired: [AVAudioSession.Port] = [.headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .usbAudio]
        let out = AVAudioSession.sharedInstance().currentRoute.outputs.first { wired.contains($0.portType) }
        return ["type": "route", "ok": true, "hp": out != nil, "name": out?.portName ?? ""]
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
