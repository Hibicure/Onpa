import SwiftUI

// Web版と同じ色
extension Color {
    static let paper = Color(red: 0.933, green: 0.941, blue: 0.957)   // #EEF0F4
    static let ink = Color(red: 0.086, green: 0.102, blue: 0.200)     // #161A33
    static let mute = Color(red: 0.416, green: 0.435, blue: 0.533)    // #6A6F88
    static let cobalt = Color(red: 0.141, green: 0.275, blue: 0.961)  // #2446F5
    static let live = Color(red: 0.071, green: 0.659, blue: 0.404)    // #12A867
}

let holo = AngularGradient(
    colors: [Color(red: 0.79, green: 0.94, blue: 1), Color(red: 0.91, green: 0.83, blue: 1), Color(red: 1, green: 0.84, blue: 0.93),
             Color(red: 1, green: 0.95, blue: 0.78), Color(red: 0.82, green: 1, blue: 0.91), Color(red: 0.79, green: 0.94, blue: 1)],
    center: .center)

struct ContentView: View {
    @EnvironmentObject var lab: Lab
    @State private var query = ""
    @State private var joinCode = ""
    @FocusState private var focused: Bool
    @State private var showWidget = false

    var body: some View {
        ZStack(alignment: .top) {
            Color.paper.ignoresSafeArea()
            // 埋め込みプレーヤー本体。普段はほぼ見えない状態で置いておく
            WidgetHost(webView: lab.widget.webView)
                .frame(width: 320, height: 160)
                .opacity(showWidget ? 1 : 0.01)
                .allowsHitTesting(showWidget)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .zIndex(showWidget ? 1 : 0)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Otocloud")
                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.ink)
                    Text("通話しながら音楽を流して、声と音楽の音量を別々に調整できるかを試すアプリです。")
                        .font(.footnote).foregroundStyle(Color.mute)

                    callCard
                    engineCard
                    if lab.nowPlaying != nil { playerCard }
                    searchSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.interactively)

            if let n = lab.notice {
                Text(n)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Color.ink, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35), value: lab.notice)
    }

    // MARK: 通話

    private var callCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch lab.callState {
            case .idle:
                Text("通話").font(.headline).foregroundStyle(Color.ink)
                Button {
                    Task { await lab.startCall() }
                } label: {
                    Label("部屋を作る", systemImage: "phone.fill")
                        .frame(maxWidth: .infinity).frame(height: 48)
                }
                .buttonStyle(.borderedProminent).tint(.cobalt)
                HStack {
                    TextField("相手の6桁の番号", text: $joinCode)
                        .keyboardType(.numberPad)
                        .padding(.horizontal, 14).frame(height: 46)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                    Button("入る") { Task { await lab.joinCall(code: joinCode) } }
                        .buttonStyle(.bordered).tint(.ink).frame(height: 46)
                }
            case .connecting:
                HStack(spacing: 10) { ProgressView(); Text("つないでいます…").foregroundStyle(Color.mute) }
            case .waiting, .live:
                HStack {
                    Circle().fill(lab.callState == .live ? Color.live : Color.orange).frame(width: 9, height: 9)
                    Text(lab.callState == .live ? "通話中" : "相手を待っています").font(.headline).foregroundStyle(Color.ink)
                    Spacer()
                    if let code = lab.roomCode {
                        Text(code).font(.system(.title3, design: .rounded).weight(.bold)).monospacedDigit().foregroundStyle(Color.cobalt)
                    }
                }
                if lab.callState == .waiting {
                    Text("この番号を相手に伝えて、相手のアプリで「入る」を押してもらってください。")
                        .font(.footnote).foregroundStyle(Color.mute)
                }
                HStack(spacing: 12) {
                    Button { Task { await lab.toggleMute() } } label: {
                        Label(lab.isMuted ? "ミュート中" : "ミュート", systemImage: lab.isMuted ? "mic.slash.fill" : "mic.fill")
                            .frame(maxWidth: .infinity).frame(height: 44)
                    }
                    .buttonStyle(.bordered).tint(.ink)
                    Button(role: .destructive) { Task { await lab.endCall() } } label: {
                        Label("終える", systemImage: "phone.down.fill").frame(maxWidth: .infinity).frame(height: 44)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(16)
        .background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: 鳴らし方の切り替え

    private var engineCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("音楽の鳴らし方").font(.headline).foregroundStyle(Color.ink)
            Picker("音楽の鳴らし方", selection: $lab.engine) {
                ForEach(Lab.Engine.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(lab.engine == .stream
                 ? "Otocloudのサーバー経由で鳴らします（1日の再生回数に上限あり）"
                 : "SoundCloud公式のプレーヤーで鳴らします（回数の上限を使わない）")
                .font(.footnote).foregroundStyle(Color.mute)
            if lab.engine == .widget {
                Toggle("プレーヤーを表示する（うまく鳴らない時の確認用）", isOn: $showWidget)
                    .font(.footnote).tint(.cobalt)
            }
        }
        .padding(16)
        .background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: 再生

    private var playerCard: some View {
        VStack(spacing: 16) {
            if let t = lab.nowPlaying {
                Disc(artwork: t.bigArtwork, spinning: lab.isPlaying)
                    .frame(width: 220, height: 220)
                    .padding(.top, 6)
                VStack(spacing: 2) {
                    Text(t.title).font(.system(.title3, design: .rounded).weight(.heavy)).foregroundStyle(Color.ink).lineLimit(1)
                    Text(t.artist).font(.subheadline).foregroundStyle(Color.mute).lineLimit(1)
                    if lab.engine == .widget {
                        Text("埋め込み：\(lab.widget.status)　\(clock(lab.widget.position)) / \(clock(lab.widget.duration))")
                            .font(.caption).monospacedDigit().foregroundStyle(Color.cobalt)
                            .padding(.top, 4)
                    }
                }
                Button { lab.togglePlay() } label: {
                    Image(systemName: lab.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 68, height: 68)
                        .background(Circle().fill(Color.ink).shadow(color: .ink.opacity(0.35), radius: 12, y: 8))
                }
            }
            VStack(spacing: 10) {
                volumeRow(label: "音楽", value: $lab.musicVolume, enabled: true)
                volumeRow(label: "声", value: $lab.voiceVolume, enabled: lab.callState == .live)
                if lab.callState != .live {
                    Text("声の音量は、通話中に調整できます").font(.caption).foregroundStyle(Color.mute)
                }
            }
            .padding(14)
            .background(.white, in: RoundedRectangle(cornerRadius: 16))
        }
        .frame(maxWidth: .infinity)
    }

    private func clock(_ s: Double) -> String {
        let t = max(0, Int(s))
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    private func volumeRow(label: String, value: Binding<Double>, enabled: Bool) -> some View {
        HStack(spacing: 12) {
            Text(label).font(.subheadline).foregroundStyle(Color.mute).frame(width: 34, alignment: .leading)
            Slider(value: value, in: 0...1).tint(.ink).disabled(!enabled)
        }
        .opacity(enabled ? 1 : 0.45)
    }

    // MARK: 検索

    private var searchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.mute)
                TextField("曲名やアーティストを検索", text: $query)
                    .focused($focused)
                    .submitLabel(.search)
                    .onSubmit { Task { await lab.search(query) } }
            }
            .padding(.horizontal, 14).frame(height: 48)
            .background(.white, in: RoundedRectangle(cornerRadius: 14))

            if lab.searching { ProgressView().frame(maxWidth: .infinity).padding() }

            ForEach(lab.results) { t in
                Button { focused = false; Task { await lab.play(t) } } label: {
                    HStack(spacing: 12) {
                        AsyncImage(url: URL(string: t.artwork ?? "")) { img in img.resizable().scaledToFill() } placeholder: { holo }
                            .frame(width: 46, height: 46).clipShape(Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.title).font(.subheadline.weight(.bold)).foregroundStyle(lab.nowPlaying == t ? Color.cobalt : Color.ink).lineLimit(1)
                            Text(t.artist).font(.caption).foregroundStyle(Color.mute).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                }
                Divider()
            }
        }
    }
}

// MARK: - 回るCD

struct Disc: View {
    let artwork: URL?
    let spinning: Bool
    @State private var angle: Double = 0

    var body: some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height)
            ZStack {
                ZStack {
                    Circle().fill(holo)
                    if let artwork {
                        AsyncImage(url: artwork) { img in img.resizable().scaledToFill() } placeholder: { Color.clear }
                    }
                }
                .clipShape(Circle())
                .rotationEffect(.degrees(angle))

                // 光の反射（回らない）
                Circle().fill(AngularGradient(colors: [.white.opacity(0), .white.opacity(0.35), .white.opacity(0), .white.opacity(0), .white.opacity(0.28), .white.opacity(0)], center: .center))
                    .blendMode(.screen)
                // 真ん中の透明なリング
                Circle().fill(Color(white: 0.93).opacity(0.9))
                    .frame(width: d * 0.34, height: d * 0.34)
                    .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1))
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                // 穴
                Circle().fill(Color.paper)
                    .frame(width: d * 0.12, height: d * 0.12)
                    .overlay(Circle().stroke(Color.ink.opacity(0.15), lineWidth: 1))
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 2)
            }
            .frame(width: d, height: d)
            .shadow(color: Color.ink.opacity(0.35), radius: 20, y: 16)
        }
        .onAppear { if spinning { spin() } }
        .onChange(of: spinning) { _, on in if on { spin() } else { stop() } }
    }

    private func spin() {
        withAnimation(.linear(duration: 7).repeatForever(autoreverses: false)) { angle += 360 }
    }

    private func stop() {
        withAnimation(.easeOut(duration: 0.4)) { angle = angle.truncatingRemainder(dividingBy: 360) }
    }
}
