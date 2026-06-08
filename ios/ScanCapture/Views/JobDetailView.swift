// JobDetailView.swift
// ScanCapture
//
// Full detail view for a single processing job, with auto-polling,
// download, share, and delete actions.

import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - JobDetailViewModel

@MainActor
@Observable
private final class JobDetailViewModel {

    var job: Job
    var isDownloading: Bool = false
    var downloadProgress: Double = 0.0
    var downloadedURL: URL? = nil
    var errorMessage: String? = nil
    var showDeleteConfirm: Bool = false
    var navigateBack: Bool = false

    private let apiClient: APIClient
    private var pollingTask: Task<Void, Never>?

    init(job: Job, apiClient: APIClient) {
        self.job = job
        self.apiClient = apiClient
    }

    // MARK: - Polling

    func startPollingIfNeeded() {
        guard job.isActive else { return }
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshJob()
                if !self.job.isActive { return }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    // MARK: - Actions

    func refreshJob() async {
        do {
            job = try await apiClient.getJob(id: job.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func download() async {
        guard !isDownloading else { return }
        isDownloading = true
        downloadProgress = 0
        do {
            let url = try await apiClient.downloadResult(job: job) { [weak self] fraction in
                Task { @MainActor [weak self] in
                    self?.downloadProgress = fraction
                }
            }
            downloadedURL = url
        } catch {
            errorMessage = error.localizedDescription
        }
        isDownloading = false
    }

    func deleteJob() async {
        do {
            try await apiClient.deleteJob(id: job.id)
            navigateBack = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - JobDetailView

struct JobDetailView: View {

    @State private var vm: JobDetailViewModel
    @Environment(\.dismiss) private var dismiss

    // Sheet / share states
    @State private var showShareSheet = false
    @State private var showFileMover  = false

    init(job: Job, apiClient: APIClient) {
        _vm = State(initialValue: JobDetailViewModel(job: job, apiClient: apiClient))
    }

    var body: some View {
        List {
            Section("Status") {
                statusSection
            }

            if vm.job.status == .completed {
                Section("Result") {
                    resultSection
                }
            }

            Section("Details") {
                detailsSection
            }

            Section {
                destructiveSection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Job \(String(vm.job.id.prefix(8)))")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Error", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button("OK") { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "")
        }
        .confirmationDialog(
            "Delete this job?",
            isPresented: $vm.showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await vm.deleteJob() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone.")
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = vm.downloadedURL {
                ShareSheet(items: [url])
            }
        }
        .fileExporter(
            isPresented: $showFileMover,
            document: vm.downloadedURL.map { SplatDocument(url: $0) },
            contentType: .data,
            defaultFilename: "capture_\(vm.job.id.prefix(8)).ply"
        ) { _ in }
        .onChange(of: vm.navigateBack) { _, newValue in
            if newValue { dismiss() }
        }
        .onAppear { vm.startPollingIfNeeded() }
        .onDisappear { vm.stopPolling() }
        .refreshable { await vm.refreshJob() }
    }

    // MARK: - Sections

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(vm.job.status.displayName, systemImage: vm.job.statusIcon)
                    .font(.headline)
                    .foregroundStyle(vm.job.statusColor)
                Spacer()
            }

            if vm.job.status == .processing {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: vm.job.clampedProgress)
                        .tint(vm.job.statusColor)
                    Text("\(Int(vm.job.clampedProgress * 100))% — \(vm.job.message ?? "Processing…")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let msg = vm.job.message {
                Text(msg)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var resultSection: some View {
        Group {
            NavigationLink(destination: SplatViewerView(job: vm.job, apiClient: vm.sharedAPIClient)) {
                Label("View in 3D", systemImage: "cube.fill")
                    .foregroundStyle(.blue)
            }

            if vm.isDownloading {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Downloading…", systemImage: "arrow.down.circle")
                        .foregroundStyle(.secondary)
                    ProgressView(value: vm.downloadProgress)
                }
            } else {
                Button {
                    Task { await vm.download() }
                } label: {
                    Label(
                        vm.downloadedURL != nil ? "Downloaded" : "Download .ply",
                        systemImage: vm.downloadedURL != nil ? "checkmark.circle.fill" : "arrow.down.circle"
                    )
                }
                .disabled(vm.isDownloading)
            }

            if vm.downloadedURL != nil {
                Button {
                    showFileMover = true
                } label: {
                    Label("Save to Files", systemImage: "folder")
                }

                Button {
                    showShareSheet = true
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    private var detailsSection: some View {
        Group {
            LabeledContent("Job ID") {
                Text(vm.job.id)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            LabeledContent("Created") {
                Text(vm.job.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Updated") {
                Text(vm.job.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var destructiveSection: some View {
        Button(role: .destructive) {
            vm.showDeleteConfirm = true
        } label: {
            Label("Delete Job", systemImage: "trash")
        }
    }
}

// MARK: - JobDetailViewModel apiClient accessor

private extension JobDetailViewModel {
    /// Exposes the private apiClient to views that build child destinations.
    var sharedAPIClient: APIClient { apiClient }
}

// MARK: - SplatDocument (FileExporter wrapper)

private struct SplatDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    let url: URL?

    init(url: URL?) { self.url = url }

    init(configuration: ReadConfiguration) throws {
        url = nil
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard let url, let data = try? Data(contentsOf: url) else {
            return FileWrapper(regularFileWithContents: Data())
        }
        return FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - ShareSheet

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
