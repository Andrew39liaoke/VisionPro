#if DEBUG
import SwiftUI
import WebKit

struct WebDiagnosticView: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text("此页面使用服务器自带播放器。原生播放已暂停；如服务器要求认证，请在网页中登录。")
                    .font(.caption).padding(.horizontal)
                DiagnosticWebView(url: url)
            }
            .navigationTitle("网页诊断")
            .toolbar { Button("完成") { dismiss() } }
        }.frame(width: 900, height: 650)
    }
}

private struct DiagnosticWebView: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isInspectable = true
        view.load(URLRequest(url: url))
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {}
    static func dismantleUIView(_ view: WKWebView, coordinator: ()) {
        view.stopLoading()
        view.loadHTMLString("", baseURL: nil)
    }
}
#endif
