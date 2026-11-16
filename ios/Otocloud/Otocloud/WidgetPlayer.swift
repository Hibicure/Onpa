import SwiftUI
import WebKit

/// SoundCloud公式の埋め込みプレーヤーを、見えない形でアプリの中に置いて操作する係。
/// 1日の再生回数の枠を使わずに鳴らせるかを試すためのもの。
@MainActor
final class WidgetPlayer: NSObject, ObservableObject, WKScriptMessageHandler {
    @Published var isPlaying = false
    @Published var position: Double = 0   // 秒
    @Published var duration: Double = 0   // 秒
    @Published var status = "待機中"

    let webView: WKWebView
    private var ready = false
    private var pending: [String] = []

    override init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []   // ボタンを押さなくても再生してよい
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 160), configuration: config)
        super.init()
        config.userContentController.add(WeakHandler(self), name: "otocloud")
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
    }

    /// 曲を読み込んで、そのまま再生する
    func load(trackId: Int, volume: Double) {
        ready = false
        pending = []
        status = "読み込み中…"
        let track = "https://api.soundcloud.com/tracks/\(trackId)"
        let src = "https://w.soundcloud.com/player/?url=\(track.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? track)&auto_play=true&visual=false&show_artwork=false&buying=false&sharing=false&download=false&show_comments=false&show_teaser=false"
        let vol = Int((volume * 100).rounded())
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;background:transparent}iframe{border:0;width:100%;height:160px}</style>
        <script src="https://w.soundcloud.com/player/api.js"></script></head><body>
        <iframe id="sc" allow="autoplay; encrypted-media" src="\(src)"></iframe>
        <script>
          const post = (o) => window.webkit.messageHandlers.otocloud.postMessage(o);
          const w = SC.Widget(document.getElementById('sc'));
          window.w = w;
          w.bind(SC.Widget.Events.READY, () => {
            w.setVolume(\(vol));
            w.getDuration(d => post({ e: 'ready', dur: d / 1000 }));
            w.play();
          });
          w.bind(SC.Widget.Events.PLAY, () => post({ e: 'play' }));
          w.bind(SC.Widget.Events.PAUSE, () => post({ e: 'pause' }));
          w.bind(SC.Widget.Events.FINISH, () => post({ e: 'finish' }));
          w.bind(SC.Widget.Events.ERROR, () => post({ e: 'error' }));
          w.bind(SC.Widget.Events.PLAY_PROGRESS, (p) => post({ e: 'progress', pos: p.currentPosition / 1000 }));
        </script></body></html>
        """
        // 埋め込みプレーヤーが自分のサイトから呼ばれたと分かるよう、Otocloudのアドレスを基準にする
        webView.loadHTMLString(html, baseURL: URL(string: "https://on-pa.net/"))
    }

    func play() { run("w.play()") }
    func pause() { run("w.pause()") }
    func toggle() { isPlaying ? pause() : play() }
    func seek(to seconds: Double) { run("w.seekTo(\(Int(seconds * 1000)))") }
    /// 0〜1。iPhoneではWebの音量が効かない可能性がある（それを確かめるのもこのテストの目的）
    func setVolume(_ v: Double) { run("w.setVolume(\(Int((v * 100).rounded())))") }

    private func run(_ js: String) {
        guard ready else { pending.append(js); return }
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let e = body["e"] as? String else { return }
        handle(e, pos: (body["pos"] as? NSNumber)?.doubleValue, dur: (body["dur"] as? NSNumber)?.doubleValue)
    }

    private func handle(_ e: String, pos: Double?, dur: Double?) {
        switch e {
        case "ready":
            ready = true
            duration = dur ?? 0
            status = "準備OK"
            pending.forEach { webView.evaluateJavaScript($0, completionHandler: nil) }
            pending = []
        case "play": isPlaying = true; status = "再生中"
        case "pause": isPlaying = false; status = "一時停止"
        case "finish": isPlaying = false; status = "再生終了"
        case "error": isPlaying = false; status = "エラー（この曲は埋め込みで流せないかも）"
        case "progress": position = pos ?? position
        default: break
        }
    }
}

/// WKWebViewが係を強く握って離さないのを防ぐための中継
@MainActor
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        target?.userContentController(c, didReceive: m)
    }
}

/// 埋め込みプレーヤーを画面に置くための部品（ほぼ見えない大きさで置く）
struct WidgetHost: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
