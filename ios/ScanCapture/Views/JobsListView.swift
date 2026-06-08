// JobsListView.swift
// ScanCapture
//
// Displays all Gaussian Splatting jobs with live polling.

import Foundation
import Observation
import SwiftUI

// MARK: - JobsViewModel

@MainActor
@Observable
final class JobsViewModel {

    var jobs: [Job] = []
    var isLoading: Bool = false
    var errorMessage: String? = nil

    let apiClient: APIClient
    private var pollingTask: Task<Void, Never>?

    init(apiClient: APIClient) {
        self.apiClient = apiClient
    }

    // MARK: - Lifecycle

    func startPolling() {
        stopPolling()
        pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.loadJobs()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    // MARK: - Data

    func loadJobs() async {
        guard !isLoading else { return }
        isLoading = true
        do {
            jobs = try await apiClient.listJobs()
                .sorted { $0.createdAt > $1.createdAt }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func deleteJob(_ job: Job) async {
        do {
            try await apiClient.deleteJob(id: job.id)
            jobs.removeAll { $0.id == job.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - JobsListView

struct JobsListView: View {

    @State private var viewModel: JobsViewModel
    @State private var selectedJob: Job? = nil

    init(apiClient: APIClient) {
        _viewModel = State(initialValue: JobsViewModel(apiClient: apiClient))
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.jobs.isEmpty && !viewModel.isLoading {
                    emptyStateView
                } else {
                    jobList
                }
            }
            .navigationTitle("Jobs")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if viewModel.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .refreshable {
                await viewModel.loadJobs()
            }
            .alert("Error", isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )) {
                Button("OK") { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
            .onAppear { viewModel.startPolling() }
            .onDisappear { viewModel.stopPolling() }
        }
    }

    // MARK: - Subviews

    private var jobList: some View {
        List {
            ForEach(viewModel.jobs) { job in
                NavigationLink(destination: JobDetailView(
                    job: job,
                    apiClient: viewModel.apiClient
                )) {
                    JobRowView(job: job)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        Task { await viewModel.deleteJob(job) }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var emptyStateView: some View {
        ContentUnavailableView(
            "No Jobs Yet",
            systemImage: "cube.transparent",
            description: Text("Capture a scene to create your first 3D Gaussian Splat.")
        )
    }
}

// MARK: - JobRowView

private struct JobRowView: View {

    let job: Job

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                // Truncated job ID
                Text(job.id.prefix(16) + "…")
                    .font(.system(.subheadline, design: .monospaced))
                    .lineLimit(1)

                Spacer()

                // Status badge
                statusBadge
            }

            Text(Self.dateFormatter.string(from: job.createdAt))
                .font(.caption)
                .foregroundStyle(.secondary)

            // Progress bar for in-flight jobs
            if job.status == .processing {
                ProgressView(value: job.clampedProgress)
                    .tint(job.statusColor)
                    .padding(.top, 2)

                Text("\(Int(job.clampedProgress * 100))% complete")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let msg = job.message, !msg.isEmpty {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusBadge: some View {
        Label(job.status.displayName, systemImage: job.statusIcon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(job.statusColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(job.statusColor.opacity(0.15), in: Capsule())
    }
}
