import SwiftUI
import WebKit

struct WebPointCloudView: UIViewRepresentable {
    let url: URL
    let reloadID: UUID

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.websiteDataStore = .default()
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Self.compactPanelsScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        #if DEBUG
        webView.isInspectable = true
        #endif

        load(url, reloadID: reloadID, in: webView, coordinator: context.coordinator)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.loadedURL != url {
            load(url, reloadID: reloadID, in: webView, coordinator: coordinator)
        } else if coordinator.reloadID != reloadID {
            coordinator.reloadID = reloadID
            webView.reload()
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
    }

    private func load(_ url: URL, reloadID: UUID, in webView: WKWebView, coordinator: Coordinator) {
        coordinator.loadedURL = url
        coordinator.reloadID = reloadID
        webView.load(URLRequest(url: url))
    }

    // Only adjust the two known VPPC overlays; never scale the point-cloud canvas.
    private static let compactPanelsScript = #"""
        (() => {
          const labels = [
            ['VPPC Live Point Cloud', 'top left'],
            ['Controls', 'top right']
          ];

          function heading(label) {
            const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
            while (walker.nextNode()) {
              if (walker.currentNode.textContent.replace(/\s+/g, ' ').trim() === label) {
                return walker.currentNode.parentElement;
              }
            }
            return null;
          }

          function overlay(element) {
            let candidate = null;
            for (let depth = 0; element && depth < 8 && element !== document.body; depth++, element = element.parentElement) {
              const rect = element.getBoundingClientRect();
              if (rect.width < 180 || rect.width > window.innerWidth * 0.6 ||
                  rect.height < 150 || rect.height > window.innerHeight * 1.1) continue;
              candidate = element;
              const position = getComputedStyle(element).position;
              if (position === 'absolute' || position === 'fixed') return element;
            }
            return candidate;
          }

          function compact() {
            let found = 0;
            for (const [label, origin] of labels) {
              const element = heading(label);
              const panel = element && overlay(element);
              if (!panel) continue;
              panel.style.scale = '0.72';
              panel.style.transformOrigin = origin;
              found++;
            }
            return found === labels.length;
          }

          if (!compact()) {
            let attempts = 0;
            const retry = setInterval(() => {
              if (compact() || ++attempts >= 10) clearInterval(retry);
            }, 500);
          }
        })();
        """#

    final class Coordinator {
        var loadedURL: URL?
        var reloadID: UUID?
    }
}
