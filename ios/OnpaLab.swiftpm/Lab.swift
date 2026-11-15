import AVFoundation
import Combine
import Foundation
import LiveKit

// MARK: - 設定（Web版と同じサーバーを使う）

enum Config {
    static let worker = URL(string: "https://geocloud.icchasong.workers.dev")!
    static let livekitURL = "wss://otocloud-wygn7mrs.livekit.cloud"
    static let firebaseKey = "AIzaSyB_bITavjyZJ86Ky9BHjYJb9IcXbieHA0g"
    static let database = "https://onpa-e7cc6-default-rtdb.asia-southeast1.firebasedatabase.app"
}

struct Track: Decodable, Identifiable, Hashable {
    let id: Int
    let title: String
    let artist: String
    let artwork: String?
    let duration: Int?

    /// 再生画面用の大きいジャケット（SoundCloudは -large が100px、-t500x500 が500px）
    var bigArtwork: URL? {
        guard let a = artwork, !a.isEmpty else { return nil }
        return URL(string: a.replacingOccurrences(of: "-large.", with: "-t500x500."))
    }
}

private struct PlayInfo: Decodable {
    let kind: String
    let url: String
}

// MARK: - アプリの中身

@MainActor
final class Lab: ObservableObject {
    // 音楽
    @Published var results: [Track] = []
    @Published var searching = false
    @Published var nowPlaying: Track?
    @Published var isPlaying = false
    @Published var musicVolume: Double = 0.8 {
        didSet {
            player.volume = Float(musicVolume)
            widget.setVolume(musicVolume)
        }
    }

    /// 音楽の鳴らし方。比べるために切り替えられる
    enum Engine: String, CaseIterable, Identifiable {
        case stream = "今の方式"
        case widget = "埋め込み"
        var id: String { rawValue }
    }
    @Published var engine: Engine = .stream {
        didSet {
            guard engine != oldValue else { return }
            // 切り替えたら、もう片方は止める
            player.pause()
            widget.pause()
            isPlaying = false
        }
    }
    let widget = WidgetPlayer()
    private var bag = Set<AnyCancellable>()

    // 通話
    @Published var voiceVolume: Double = 1.0 { didSet { applyVoiceVolume() } }
    @Published var roomCode: String?
    @Published var callState: CallState = .idle
    @Published var peerCount = 0

    // お知らせ
    @Published var notice: String?

    enum CallState { case idle, connecting, waiting, live }

    let player = AVPlayer()
    let room = Room()

    private var uid = ""
    private var idToken = ""
    private var voiceTimer: Timer?

    init() {
        // 通話していないときは、普通の音楽アプリと同じ設定
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.volume = Float(musicVolume)
        // 埋め込みプレーヤーの変化を画面に伝える
        widget.objectWillChange
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.objectWillChange.send() } }
            .store(in: &bag)
        widget.$isPlaying
            .sink { [weak self] playing in
                MainActor.assumeIsolated {
                    guard let self, self.engine == .widget else { return }
                    self.isPlaying = playing
                }
            }
            .store(in: &bag)
    }

    // MARK: 検索と再生

    func search(_ q: String) async {
        let q = q.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return }
        searching = true
        defer { searching = false }
        do {
            var url = Config.worker.appending(path: "search")
            url.append(queryItems: [URLQueryItem(name: "q", value: q)])
            let (data, _) = try await URLSession.shared.data(from: url)
            results = try JSONDecoder().decode([Track].self, from: data)
        } catch {
            show("検索できませんでした")
        }
    }

    func play(_ track: Track) async {
        if engine == .widget {
            // 埋め込み：こちらのサーバーを通さず、SoundCloudのプレーヤーが直接鳴らす
            player.pause()
            widget.load(trackId: track.id, volume: musicVolume)
            nowPlaying = track
            return
        }
        do {
            var url = Config.worker.appending(path: "play")
            url.append(queryItems: [URLQueryItem(name: "id", value: String(track.id))])
            let (data, _) = try await URLSession.shared.data(from: url)
            let info = try JSONDecoder().decode(PlayInfo.self, from: data)
            guard let stream = URL(string: info.url) else { throw URLError(.badURL) }
            player.replaceCurrentItem(with: AVPlayerItem(url: stream))
            player.volume = Float(musicVolume)
            player.play()
            nowPlaying = track
            isPlaying = true
        } catch {
            show("この曲は再生できませんでした")
        }
    }

    func togglePlay() {
        guard nowPlaying != nil else { return }
        if engine == .widget { widget.toggle(); return }
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
    }

    // MARK: 通話

    /// 新しい部屋を作って、番号を相手に伝える
    func startCall() async {
        let code = String(format: "%06d", Int.random(in: 0..<1_000_000))
        await connect(code: code, creating: true)
    }

    /// 相手から聞いた番号の部屋に入る
    func joinCall(code: String) async {
        let code = code.filter(\.isNumber)
        guard code.count == 6 else { show("6桁の番号を入れてください"); return }
        await connect(code: code, creating: false)
    }

    private func connect(code: String, creating: Bool) async {
        callState = .connecting
        let roomName = "lab" + code
        do {
            try await signIn()
            // 誰の部屋か、を記録（中継役はこれを見て入場券を出す）
            if creating {
                try await dbPut("rooms/\(roomName)/call", ["from": uid, "to": "", "status": "open"])
            } else {
                try await dbPut("rooms/\(roomName)/call/to", uid)
            }
            let token = try await fetchCallToken(room: roomName)

            configureAudioForCall()
            try await room.connect(
                url: Config.livekitURL,
                token: token,
                connectOptions: ConnectOptions(enableMicrophone: true)
            )
            roomCode = code
            callState = .waiting
            startVoiceTimer()
        } catch {
            callState = .idle
            show("通話につなげませんでした（\(error.localizedDescription)）")
        }
    }

    func endCall() async {
        voiceTimer?.invalidate()
        voiceTimer = nil
        await room.disconnect()
        callState = .idle
        roomCode = nil
        peerCount = 0
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    func toggleMute() async {
        let on = room.localParticipant.isMicrophoneEnabled()
        _ = try? await room.localParticipant.setMicrophone(enabled: !on)
        objectWillChange.send()
    }

    var isMuted: Bool { !room.localParticipant.isMicrophoneEnabled() }

    /// 通話中も音楽を止めずに鳴らすための設定
    private func configureAudioForCall() {
        AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP, .mixWithOthers]
        )
        try? session.setActive(true)
    }

    /// 相手の声の音量（音楽とは別に調整できる）
    private func applyVoiceVolume() {
        for participant in room.remoteParticipants.values {
            for publication in participant.audioTracks {
                (publication.track as? RemoteAudioTrack)?.volume = voiceVolume
            }
        }
    }

    private func startVoiceTimer() {
        voiceTimer?.invalidate()
        voiceTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.peerCount = self.room.remoteParticipants.count
                if self.callState != .idle { self.callState = self.peerCount > 0 ? .live : .waiting }
                self.applyVoiceVolume()
            }
        }
    }

    // MARK: ログイン（匿名）とデータベース

    private func signIn() async throws {
        guard idToken.isEmpty else { return }
        var req = URLRequest(url: URL(string: "https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=\(Config.firebaseKey)")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("https://on-pa.net/", forHTTPHeaderField: "Referer")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["returnSecureToken": true])
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw LabError("ログインに失敗しました") }
        struct R: Decodable { let idToken: String; let localId: String }
        let r = try JSONDecoder().decode(R.self, from: data)
        idToken = r.idToken
        uid = r.localId
    }

    private func dbPut(_ path: String, _ value: Any) async throws {
        var req = URLRequest(url: URL(string: "\(Config.database)/\(path).json?auth=\(idToken)")!)
        req.httpMethod = "PUT"
        req.httpBody = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        let (_, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw LabError("部屋を作れませんでした") }
    }

    private func fetchCallToken(room: String) async throws -> String {
        var url = Config.worker.appending(path: "livekit-token")
        url.append(queryItems: [URLQueryItem(name: "room", value: room), URLQueryItem(name: "name", value: "iPhone")])
        var req = URLRequest(url: url)
        req.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        struct R: Decodable { let token: String?; let error: String? }
        let r = try JSONDecoder().decode(R.self, from: data)
        guard let token = r.token else { throw LabError(r.error ?? "入場券をもらえませんでした") }
        return token
    }

    // MARK: お知らせ

    func show(_ text: String) {
        notice = text
        Task {
            try? await Task.sleep(for: .seconds(3))
            if notice == text { notice = nil }
        }
    }
}

struct LabError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
