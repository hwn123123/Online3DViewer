import SwiftUI
import WebKit
import OSLog

struct WebViewer: UIViewRepresentable {
    @ObservedObject var model: ViewerModel
    let url: URL
    let sessionID: UUID

    func makeCoordinator() -> Coordinator { Coordinator(model: model, sessionID: sessionID) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "o3dv")
        #if DEBUG
        configuration.userContentController.addUserScript(WKUserScript(source: "window.O3DVNativeDebug = true;", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        #endif
        configuration.allowsInlineMediaPlayback = true
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.scrollView.isScrollEnabled = false
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.isOpaque = false
        view.backgroundColor = .systemBackground
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.sessionID == model.webViewID else { return }
        if model.ready,context.coordinator.foreground != model.foreground {
            context.coordinator.foreground = model.foreground
            view.callAsyncJavaScript("window.O3DVSetForeground?.(value);",arguments: ["value":model.foreground],in: nil,in: .page) { _ in }
        }
        if model.ready, context.coordinator.memoryPolicy != model.memoryPolicy {
            context.coordinator.memoryPolicy = model.memoryPolicy
            view.callAsyncJavaScript("window.O3DVSetMemoryPolicy?.(policy);", arguments: ["policy": model.memoryPolicy],in: nil,in: .page) { _ in }
        }
        let preferences = ["background": model.preferences.background, "navigation": model.preferences.navigation,
                           "projection": model.preferences.projection]
        if model.ready, context.coordinator.preferences != preferences {
            context.coordinator.preferences = preferences
            view.callAsyncJavaScript("window.O3DVSetViewerPreferences?.(values);", arguments: ["values": preferences], in: nil, in: .page) { _ in }
        }
        if model.ready, context.coordinator.layerVisibility != model.layerVisibility {
            context.coordinator.layerVisibility = model.layerVisibility
            let values = Dictionary(uniqueKeysWithValues: model.layerVisibility.map { (String($0.key), $0.value) })
            view.callAsyncJavaScript("window.O3DVSetStreamLayers?.(values);", arguments: ["values": values], in: nil, in: .page) { _ in }
        }
        guard model.ready, let request = model.request, context.coordinator.lastRequest != request.id else { return }
        context.coordinator.lastRequest = request.id
        let script = request.isStream ? "window.O3DVOpenStream(urls[0]);" : "window.O3DVOpenFiles(urls);"
        view.callAsyncJavaScript(script, arguments: ["urls": request.urls.map(\.absoluteString)], in: nil, in: .page) { result in
            if case .failure(let error) = result {
                DispatchQueue.main.async {
                    guard model.webViewID == sessionID, model.request?.id == request.id else { return }
                    model.loadingFailed("模型打开失败：\(error.localizedDescription)")
                }
            }
        }
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "o3dv")
        view.evaluateJavaScript("window.O3DVStop?.();", completionHandler: nil)
        view.stopLoading()
        view.loadHTMLString("", baseURL: nil)
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let model: ViewerModel
        let sessionID: UUID
        var lastRequest: UUID?
        var layerVisibility: [Int: Bool] = [:]
        var memoryPolicy: [String:Int] = [:]
        var preferences: [String:String] = [:]
        var foreground = true
        #if DEBUG
        var benchmarkStarted = false
        #endif
        let logger = Logger(subsystem: "com.hwn.Online3DViewer", category: "Viewer")

        init(model: ViewerModel, sessionID: UUID) { self.model = model; self.sessionID = sessionID }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard model.webViewID == sessionID else { return }
            guard let value = message.body as? [String: Any], let type = value["type"] as? String else { return }
            logger.notice("Viewer event: \(type, privacy: .public), model: \((value["name"] as? String) ?? "", privacy: .public)")
            var diagnostic = type == "stream_metadata" ? ["receivedObjects": (value["objects"] as? [Any])?.count ?? 0,
                                                          "layers": (value["layers"] as? [Any])?.count ?? 0] : value
            if type == "ready" { diagnostic["resources"] = NativeMemoryControl.snapshot() }
            model.recordEvent(type, name: (value["name"] as? String) ?? "", details: diagnostic)
            if type == "ready" { model.didBecomeReady() }
            if type == "request_file_picker", !model.isLoading && !model.storageBusy { model.showingImporter = true }
            if type == "javascript_error" {
                model.loadingFailed("模型显示失败：\((value["name"] as? String) ?? "未知错误")")
            }
            if type == "load_progress" { model.receiveLoadProgress(value) }
            if ["no_importable_file", "failed_to_load_file", "import_failed"].contains(type) {
                model.loadingFailed("无法解析这个模型，请检查文件格式及配套文件是否完整。")
            }
            if type.hasPrefix("stream_") || type == "model_loaded" || value["stream"] as? Bool == true { model.receiveStreamMessage(value) }
            if type == "model_loaded", let name = value["name"] as? String, !name.isEmpty {
                model.title = name.removingPercentEncoding ?? name
                model.modelDidLoad(manifestURL: value["manifestUrl"] as? String)
                #if DEBUG
                if !benchmarkStarted, ProcessInfo.processInfo.arguments.contains("--benchmark-navigation") {
                    benchmarkStarted = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak webView = message.webView] in
                        guard let self,let webView,self.model.webViewID == self.sessionID else { return }
                        webView.callAsyncJavaScript("return window.O3DVBenchmarkNavigation();",arguments: [:],in: nil,in: .page) { result in
                            if case .failure(let error) = result { self.model.recordEvent("navigation_benchmark_failed",name: self.model.title,details: ["error":error.localizedDescription]) }
                        }
                    }
                }
                #endif
                if let itemID = model.activeItemID {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self, weak webView = message.webView] in
                        guard let self, let webView, self.model.webViewID == self.sessionID, self.model.activeItemID == itemID else { return }
                        webView.callAsyncJavaScript("return window.O3DVGetThumbnail?.();", arguments: [:], in: nil, in: .page) { result in
                            guard self.model.webViewID == self.sessionID else { return }
                            if case .success(let value) = result, let dataURL = value as? String { self.model.saveThumbnail(dataURL, itemID: itemID) }
                        }
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let url = navigationAction.request.url
            let local = url?.scheme == "about" || (url?.host == "127.0.0.1" && url?.port == model.baseURL?.port)
            decisionHandler(local ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard model.webViewID == sessionID, (error as NSError).code != NSURLErrorCancelled else { return }
            model.error = "查看器加载失败：\(error.localizedDescription)"
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard model.webViewID == sessionID else { return }
            model.recordEvent("webcontent_terminated", name: model.title)
            model.returnToLibrary()
            model.error = "查看器进程已退出。模型可能超出了设备可用内存，请尝试更小的模型。"
        }
    }
}
