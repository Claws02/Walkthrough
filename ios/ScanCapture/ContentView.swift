// ContentView.swift
// ScanCapture
//
// Root tab container with three NavigationStacks: Capture, Jobs, Settings.

import SwiftUI

struct ContentView: View {

    @Environment(AppSettings.self) private var settings
    @Environment(APIClient.self)   private var apiClient

    var body: some View {
        TabView {
            // MARK: Capture tab
            NavigationStack {
                CaptureView(settings: settings, apiClient: apiClient)
                    .navigationTitle("Capture")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem {
                Label("Capture", systemImage: "camera.viewfinder")
            }

            // MARK: Jobs tab
            NavigationStack {
                JobsListView(apiClient: apiClient)
            }
            .tabItem {
                Label("Jobs", systemImage: "list.bullet.rectangle")
            }

            // MARK: Settings tab
            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
        }
    }
}

#Preview {
    let settings  = AppSettings()
    let apiClient = APIClient(settings: settings)
    return ContentView()
        .environment(settings)
        .environment(apiClient)
}
