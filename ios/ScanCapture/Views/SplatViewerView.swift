// SplatViewerView.swift
// ScanCapture
//
// Embeds a WKWebView that loads viewer.html and passes the .ply result URL
// via a JavaScript call: window.loadSplat(url).

import SwiftUI
import WebKit

// MARK: - WebViewCoordinator

final class WebViewCoordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WKUIDelegate {

    var parent: WebViewRepresentable
    var isLoaded: Bool = false

    init(parent: WebViewRepresentable) {
        self.parent = parent
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Once the page has loaded, inject the splat URL.
        if let urlString = parent.splatURLString {
            let escaped = urlString.replacingOccurrences(of: "'", with: "\\'")
            let js = "window.loadSplat('\(escaped)');"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
        DispatchQueue.main.async {
            self.parent.isPageLoaded = true
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        DispatchQueue.main.async {
            self.parent.loadError = error.localizedDescription
        }
    }

    // MARK: WKScriptMessageHandler

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        // Messages posted by the viewer JS (e.g. "ready", progress)
        if message.name == "splatReady" {
            DispatchQueue.main.async {
                self.parent.isWebGLReady = true
            }
        }
    }
}

// MARK: - WebViewRepresentable

struct WebViewRepresentable: UIViewRepresentable {

    let splatURLString: String?
    @Binding var isPageLoaded: Bool
    @Binding var isWebGLReady: Bool
    @Binding var loadError: String?

    weak var webViewRef: WKWebView?

    func makeCoordinator() -> WebViewCoordinator {
        WebViewCoordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let userContent = WKUserContentController()
        userContent.add(context.coordinator, name: "splatReady")
        config.userContentController = userContent

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false

        // Load viewer.html from the app bundle.
        // allowingReadAccessTo is set to the app's home directory so the WKWebView
        // can fetch downloaded .ply files stored anywhere in the app sandbox
        // (temp directory, caches, documents, etc.).
        if let htmlURL = Bundle.main.url(forResource: "viewer", withExtension: "html") {
            let appHome = URL(fileURLWithPath: NSHomeDirectory())
            webView.loadFileURL(htmlURL, allowingReadAccessTo: appHome)
        }

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.parent = self
    }

    func takeScreenshot(completion: @escaping (UIImage?) -> Void) {
        // Called externally via a bound callback – stored so SplatViewerView can invoke it.
    }
}

// MARK: - SplatViewerView

struct SplatViewerView: View {

    let job: Job
    let apiClient: APIClient

    @State private var isPageLoaded: Bool = false
    @State private var isWebGLReady: Bool = false
    @State private var loadError: String? = nil
    @State private var showHelp: Bool = false
    @State private var screenshotImage: UIImage? = nil
    @State private var showScreenshotPreview: Bool = false

    @State private var splatURLString: String? = nil
    @State private var isLoadingResult: Bool = false

    @Environment(AppSettings.self) private var settings

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let errorMsg = loadError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.yellow)
                    Text("Failed to load viewer")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(errorMsg)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
                .padding()
            } else {
                WebViewRepresentable(
                    splatURLString: splatURLString,
                    isPageLoaded: $isPageLoaded,
                    isWebGLReady: $isWebGLReady,
                    loadError: $loadError
                )
                .ignoresSafeArea()

                // Loading spinner while WebGL initialises
                if !isWebGLReady || isLoadingResult {
                    VStack(spacing: 12) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                            .scaleEffect(1.5)
                        Text(isLoadingResult ? "Downloading result…" : "Initialising viewer…")
                            .font(.subheadline)
                            .foregroundStyle(.white)
                    }
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                }

                // Gesture help overlay
                if showHelp {
                    helpOverlay
                        .transition(.opacity)
                }

                // Controls
                VStack {
                    HStack {
                        Spacer()
                        VStack(spacing: 12) {
                            Button {
                                withAnimation { showHelp.toggle() }
                            } label: {
                                Image(systemName: "questionmark.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(.white)
                                    .shadow(radius: 4)
                            }

                            Button {
                                takeScreenshot()
                            } label: {
                                Image(systemName: "camera.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(.white)
                                    .shadow(radius: 4)
                            }
                        }
                        .padding(.trailing, 16)
                        .padding(.top, 8)
                    }
                    Spacer()
                }
            }

            // Screenshot preview sheet
            if showScreenshotPreview, let img = screenshotImage {
                screenshotPreview(img)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .navigationTitle("3D Viewer")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadResult() }
    }

    // MARK: - Subviews

    private var helpOverlay: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Gesture Guide", systemImage: "hand.draw")
                .font(.headline)
                .foregroundStyle(.white)
            Divider().background(.white.opacity(0.3))
            helpRow(icon: "hand.point.up.left", text: "Single finger drag — orbit camera")
            helpRow(icon: "arrow.up.and.down.and.arrow.left.and.right", text: "Two finger drag — pan")
            helpRow(icon: "plus.magnifyingglass", text: "Pinch — zoom in / out")
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding()
        .frame(maxWidth: 320)
        .onTapGesture { withAnimation { showHelp = false } }
    }

    private func helpRow(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundStyle(.cyan)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.9))
        }
    }

    private func screenshotPreview(_ image: UIImage) -> some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture { withAnimation { showScreenshotPreview = false } }

            VStack(spacing: 16) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .cornerRadius(12)
                    .shadow(radius: 10)
                    .padding()

                HStack(spacing: 20) {
                    Button {
                        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                        withAnimation { showScreenshotPreview = false }
                    } label: {
                        Label("Save", systemImage: "photo")
                            .font(.headline)
                            .padding()
                            .background(.blue, in: Capsule())
                            .foregroundStyle(.white)
                    }

                    Button {
                        withAnimation { showScreenshotPreview = false }
                    } label: {
                        Label("Dismiss", systemImage: "xmark")
                            .font(.headline)
                            .padding()
                            .background(.ultraThinMaterial, in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
            }
            .padding()
        }
    }

    // MARK: - Actions

    private func loadResult() async {
        guard let resultPath = job.resultUrl else { return }
        isLoadingResult = true
        do {
            let localURL = try await apiClient.downloadResult(job: job) { _ in }
            splatURLString = localURL.absoluteString
        } catch {
            loadError = error.localizedDescription
        }
        isLoadingResult = false
    }

    private func takeScreenshot() {
        // UIWindow snapshot — works even when the webview is opaque.
        let scenes = UIApplication.shared.connectedScenes
        guard let windowScene = scenes.first as? UIWindowScene,
              let window = windowScene.windows.first else { return }

        let renderer = UIGraphicsImageRenderer(size: window.bounds.size)
        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        screenshotImage = image
        withAnimation { showScreenshotPreview = true }
    }
}
