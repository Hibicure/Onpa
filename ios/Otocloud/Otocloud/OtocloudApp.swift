import AVFoundation
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
        // アプリに戻ってきた時、しばらく経っていたら新しいサイトを読み直す
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.didBecomeActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate, UIScrollViewDelegate {
        weak var webView: WKWebView?
        private var leftAt = Date()

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { nil }

        @objc func didBecomeActive() {
            defer { leftAt = Date() }
            // 10分以上たっていて、通話中でなければ読み直す（通話中に切れないように）
            guard Date().timeIntervalSince(leftAt) > 600, let web = webView else { return }
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
