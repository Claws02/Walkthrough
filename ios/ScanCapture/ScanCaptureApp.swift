// ScanCaptureApp.swift
// ScanCapture
//
// Application entry point. Injects AppSettings and APIClient into the
// SwiftUI environment so any descendant view can access them.

import SwiftUI

@main
struct ScanCaptureApp: App {

    /// Shared settings backed by UserDefaults.
    @State private var settings = AppSettings()

    /// Lazily created after settings are available so the base URL is correct.
    @State private var apiClient: APIClient

    init() {
        let s = AppSettings()
        _settings   = State(initialValue: s)
        _apiClient  = State(initialValue: APIClient(settings: s))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(settings)
                .environment(apiClient)
                // Keep apiClient.baseURL in sync when settings change.
                .onChange(of: settings.serverURL) { _, newURL in
                    apiClient.baseURL = newURL
                }
        }
    }
}
