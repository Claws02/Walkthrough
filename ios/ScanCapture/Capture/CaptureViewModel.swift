// CaptureViewModel.swift
// ScanCapture
//
// Orchestrates the capture pipeline: ARKit session → ZIP → two-step server upload.
// Step 1: POST /api/jobs  (creates job record)
// Step 2: POST /api/jobs/{id}/upload  (streams ZIP)

import Foundation
import Observation

// MARK: - CaptureState

enum CaptureState: CaseIterable {
    case idle
    case capturing
    case uploading
    case complete

    var displayName: String {
        switch self {
        case .idle:       return "Ready"
        case .capturing:  return "Recording"
        case .uploading:  return "Uploading"
        case .complete:   return "Complete"
        }
    }
}

// MARK: - CaptureViewModel

@MainActor
@Observable
final class CaptureViewModel {

    // MARK: - Dependencies

    let captureManager: ARCaptureManager
    let apiClient: APIClient
    private let settings: AppSettings

    // MARK: - State

    var state: CaptureState = .idle
    var uploadProgress: Double = 0.0
    var errorMessage: String? = nil
    var currentJobId: String? = nil

    // MARK: - Init

    init(settings: AppSettings, apiClient: APIClient) {
        self.settings       = settings
        self.apiClient      = apiClient
        self.captureManager = ARCaptureManager(settings: settings)
    }

    // MARK: - Public interface

    func startCapture() {
        guard state == .idle else { return }

        captureManager.startSession()

        let fm = FileManager.default
        let caches     = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let timestamp  = Int(Date().timeIntervalSince1970)
        let captureDir = caches.appendingPathComponent("capture_\(timestamp)")
        try? fm.createDirectory(at: captureDir, withIntermediateDirectories: true)

        captureManager.startRecording(outputDir: captureDir)
        state        = .capturing
        errorMessage = nil
    }

    func stopAndUpload() async {
        guard state == .capturing else { return }

        guard let captureDir = captureManager.stopRecording() else {
            errorMessage = "Recording produced no output directory."
            state = .idle
            return
        }

        state          = .uploading
        uploadProgress = 0.0

        do {
            // 1. Zip the capture directory.
            let zipURL = try await captureManager.compressCapture(captureDir: captureDir)

            // 2. Create a job record on the server (POST /api/jobs).
            let newJob = try await apiClient.createJob()
            currentJobId = newJob.id

            // 3. Upload the ZIP to the server (POST /api/jobs/{id}/upload).
            try await apiClient.uploadCapture(
                jobId: newJob.id,
                zipURL: zipURL
            ) { [weak self] fraction in
                Task { @MainActor [weak self] in
                    self?.uploadProgress = fraction
                }
            }

            // 4. Remove local files now that the server has them.
            try? FileManager.default.removeItem(at: captureDir)
            try? FileManager.default.removeItem(at: zipURL)

            state          = .complete
            uploadProgress = 1.0

        } catch {
            errorMessage = error.localizedDescription
            state        = .idle
        }
    }

    func resetToIdle() {
        state          = .idle
        uploadProgress = 0.0
        errorMessage   = nil
        currentJobId   = nil
        captureManager.stopSession()
    }
}
