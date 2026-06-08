// Job.swift
// ScanCapture
//
// Domain model representing a 3D Gaussian Splatting processing job on the backend.

import SwiftUI

// MARK: - JobStatus

enum JobStatus: String, Codable, CaseIterable, Sendable {
    case pending    = "pending"
    case processing = "processing"
    case completed  = "completed"
    case failed     = "failed"

    /// Human-readable display label.
    var displayName: String {
        switch self {
        case .pending:    return "Pending"
        case .processing: return "Processing"
        case .completed:  return "Completed"
        case .failed:     return "Failed"
        }
    }
}

// MARK: - Job

struct Job: Identifiable, Codable, Sendable, Equatable {

    // MARK: Stored properties

    let id: String
    var status: JobStatus
    var progress: Double
    var message: String?
    var createdAt: Date
    var updatedAt: Date
    var resultUrl: String?

    // MARK: CodingKeys

    enum CodingKeys: String, CodingKey {
        case id
        case status
        case progress
        case message
        case createdAt   = "created_at"
        case updatedAt   = "updated_at"
        case resultUrl   = "result_url"
    }

    // MARK: Computed UI helpers

    /// SwiftUI `Color` reflecting the current status.
    var statusColor: Color {
        switch status {
        case .pending:    return .orange
        case .processing: return .blue
        case .completed:  return .green
        case .failed:     return .red
        }
    }

    /// SF Symbol name reflecting the current status.
    var statusIcon: String {
        switch status {
        case .pending:    return "clock"
        case .processing: return "gearshape.2"
        case .completed:  return "checkmark.seal.fill"
        case .failed:     return "xmark.octagon.fill"
        }
    }

    /// Clamped progress in [0, 1] suitable for `ProgressView`.
    var clampedProgress: Double {
        min(max(progress, 0.0), 1.0)
    }

    /// `true` when the job is still in a non-terminal state.
    var isActive: Bool {
        status == .pending || status == .processing
    }

    /// Returns the full URL for the result file given a base URL string,
    /// or `nil` when `resultUrl` is absent.
    func resultAbsoluteURL(baseURL: String) -> URL? {
        guard let path = resultUrl else { return nil }
        // resultUrl may already be absolute or a relative path like /api/jobs/{id}/result
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            return URL(string: path)
        }
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        return URL(string: base + path)
    }
}
