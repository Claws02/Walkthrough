// SettingsView.swift
// ScanCapture
//
// Form-based settings UI wired to AppSettings (@Observable + @AppStorage).

import SwiftUI

struct SettingsView: View {

    @Environment(AppSettings.self) private var settings
    @Environment(APIClient.self)   private var apiClient

    // Local ephemeral state
    @State private var isTestingConnection: Bool = false
    @State private var connectionResult: ConnectionResult? = nil
    @State private var showClearJobsConfirm: Bool = false
    @State private var clearJobsError: String? = nil

    private enum ConnectionResult {
        case success, failure(String)
    }

    // MARK: - Body

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            Form {
                serverSection(settings: settings)
                captureSection(settings: settings)
                advancedSection(settings: settings)
                dataSection
                aboutSection
            }
            .navigationTitle("Settings")
            .confirmationDialog(
                "Clear all jobs?",
                isPresented: $showClearJobsConfirm,
                titleVisibility: .visible
            ) {
                Button("Clear All Jobs", role: .destructive) {
                    Task { await clearAllJobs() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will delete every job record from the server. This action cannot be undone.")
            }
            .alert("Error", isPresented: Binding(
                get: { clearJobsError != nil },
                set: { if !$0 { clearJobsError = nil } }
            )) {
                Button("OK") { clearJobsError = nil }
            } message: {
                Text(clearJobsError ?? "")
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func serverSection(settings: AppSettings) -> some View {
        @Bindable var settings = settings

        Section {
            HStack {
                TextField("Server URL", text: $settings.serverURL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                if !settings.isServerURLValid && !settings.serverURL.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Button {
                testConnection()
            } label: {
                HStack {
                    Label("Test Connection", systemImage: "antenna.radiowaves.left.and.right")
                    Spacer()
                    if isTestingConnection {
                        ProgressView().controlSize(.small)
                    } else if let result = connectionResult {
                        switch result {
                        case .success:
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        case .failure:
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                        }
                    }
                }
            }
            .disabled(isTestingConnection || !settings.isServerURLValid)

            if case .failure(let msg) = connectionResult {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Server")
        } footer: {
            Text("Enter the base URL of your Gaussian Splatting backend (e.g. http://192.168.1.10:8000)")
        }
    }

    @ViewBuilder
    private func captureSection(settings: AppSettings) -> some View {
        @Bindable var settings = settings

        Section("Capture") {
            Picker("Frame Rate", selection: $settings.captureFrameRate) {
                ForEach(AppSettings.frameRateOptions, id: \.self) { fps in
                    Text("\(Int(fps)) FPS").tag(fps)
                }
            }

            Picker("Resolution", selection: $settings.captureResolution) {
                ForEach(AppSettings.resolutionOptions, id: \.self) { res in
                    Text(res.capitalized).tag(res)
                }
            }

            Toggle("Enable LiDAR Depth", isOn: $settings.enableLiDAR)
        }
    }

    @ViewBuilder
    private func advancedSection(settings: AppSettings) -> some View {
        @Bindable var settings = settings

        Section("Display") {
            Toggle("Depth Visualisation", isOn: $settings.enableDepthVisualization)
                .disabled(!settings.enableLiDAR)
        }
    }

    private var dataSection: some View {
        Section("Data") {
            Button(role: .destructive) {
                showClearJobsConfirm = true
            } label: {
                Label("Clear All Jobs", systemImage: "trash")
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version") {
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Build") {
                Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Actions

    private func testConnection() {
        isTestingConnection = true
        connectionResult = nil
        // Sync apiClient baseURL with latest setting before testing.
        apiClient.baseURL = settings.serverURL
        Task {
            do {
                let ok = try await apiClient.testConnection()
                await MainActor.run {
                    connectionResult = ok ? .success : .failure("Server responded with an unexpected status.")
                    isTestingConnection = false
                }
            } catch {
                await MainActor.run {
                    connectionResult = .failure(error.localizedDescription)
                    isTestingConnection = false
                }
            }
        }
    }

    private func clearAllJobs() async {
        do {
            let jobs = try await apiClient.listJobs()
            for job in jobs {
                try await apiClient.deleteJob(id: job.id)
            }
        } catch {
            await MainActor.run { clearJobsError = error.localizedDescription }
        }
    }
}
