// APIClient.swift
// ScanCapture
//
// Networking layer for communicating with the 3D Gaussian Splatting backend.

import Foundation
import Observation

// MARK: - APIError

enum APIError: LocalizedError {
    case invalidURL(String)
    case unexpectedStatusCode(Int)
    case decodingFailed(Error)
    case noResultURL
    case uploadFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):           return "Invalid URL: \(url)"
        case .unexpectedStatusCode(let c):   return "Server returned HTTP \(c)"
        case .decodingFailed(let e):         return "Decoding failed: \(e.localizedDescription)"
        case .noResultURL:                   return "Job has no result URL"
        case .uploadFailed(let msg):         return "Upload failed: \(msg)"
        }
    }
}

// MARK: - UploadDelegate

/// URLSessionDelegate subclass that bridges upload progress back to a Swift async closure.
private final class UploadDelegate: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate, @unchecked Sendable {

    var progressHandler: ((Double) -> Void)?
    var completionData = Data()
    var completionError: Error?
    private var continuation: CheckedContinuation<Data, Error>?

    func waitForCompletion() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    // MARK: URLSessionTaskDelegate

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        let fraction = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        progressHandler?(fraction)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume(returning: completionData)
        }
        continuation = nil
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        completionData.append(data)
    }
}

// MARK: - DownloadDelegate

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    var progressHandler: ((Double) -> Void)?
    private var continuation: CheckedContinuation<URL, Error>?

    func waitForCompletion() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Move the temp file to a persistent temp location before the delegate returns.
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(location.pathExtension.isEmpty ? "splat" : location.pathExtension)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            continuation?.resume(returning: dest)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        progressHandler?(fraction)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}

// MARK: - APIClient

@Observable
final class APIClient {

    // MARK: - Properties

    var baseURL: String

    private let defaultSession: URLSession
    private let decoder: JSONDecoder

    // MARK: - Init

    init(settings: AppSettings) {
        self.baseURL = settings.serverURL
        self.defaultSession = URLSession.shared
        let dec = JSONDecoder()
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        dec.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let str = try container.decode(String.self)
            if let date = fmt.date(from: str) { return date }
            // Fallback without fractional seconds
            let fmt2 = ISO8601DateFormatter()
            fmt2.formatOptions = [.withInternetDateTime]
            if let date = fmt2.date(from: str) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot parse date: \(str)")
        }
        self.decoder = dec
    }

    // MARK: - Helpers

    private func url(_ path: String) throws -> URL {
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: base + path) else {
            throw APIError.invalidURL(base + path)
        }
        return url
    }

    private func checkStatus(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.unexpectedStatusCode(http.statusCode)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw APIError.decodingFailed(error)
        }
    }

    // MARK: - API Methods

    /// Creates a bare job record via POST /api/jobs (no file).
    /// The capture ZIP is uploaded afterwards with `uploadCapture(jobId:zipURL:)`.
    func createJob() async throws -> Job {
        var request = URLRequest(url: try url("/api/jobs"))
        request.httpMethod = "POST"
        // An empty form body — the backend treats a missing `file` field as
        // a bare job creation.
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data()
        let (data, response) = try await defaultSession.data(for: request)
        try checkStatus(response)
        return try decode(Job.self, from: data)
    }

    /// Uploads a ZIP archive to POST /api/jobs/{id}/upload and starts processing.
    /// Reports upload progress via `progressHandler` (0.0 – 1.0). Returns the updated `Job`.
    @discardableResult
    func uploadCapture(
        jobId: String,
        zipURL: URL,
        progressHandler: @escaping (Double) -> Void
    ) async throws -> Job {
        let endpoint = try url("/api/jobs/\(jobId)/upload")

        let boundary = "ScanCapture-\(UUID().uuidString)"
        var body = Data()

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"capture.zip\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/zip\r\n\r\n".data(using: .utf8)!)
        body.append(try Data(contentsOf: zipURL))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300

        let delegate = UploadDelegate()
        delegate.progressHandler = progressHandler
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let task = session.uploadTask(with: request, from: body)
        task.resume()

        let responseData = try await delegate.waitForCompletion()

        if let http = task.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let msg = String(data: responseData, encoding: .utf8) ?? "Unknown error"
            throw APIError.uploadFailed("HTTP \(http.statusCode): \(msg)")
        }

        return try decode(Job.self, from: responseData)
    }

    /// Fetches the current state of a single job.
    func getJob(id: String) async throws -> Job {
        let (data, response) = try await defaultSession.data(from: try url("/api/jobs/\(id)"))
        try checkStatus(response)
        return try decode(Job.self, from: data)
    }

    /// Fetches all jobs from the server.
    func listJobs() async throws -> [Job] {
        let (data, response) = try await defaultSession.data(from: try url("/api/jobs"))
        try checkStatus(response)
        return try decode([Job].self, from: data)
    }

    /// Deletes a job from the server.
    func deleteJob(id: String) async throws {
        var request = URLRequest(url: try url("/api/jobs/\(id)"))
        request.httpMethod = "DELETE"
        let (_, response) = try await defaultSession.data(for: request)
        try checkStatus(response)
    }

    /// Downloads the result file (.ply / .splat) for a completed job.
    /// Reports download progress via `progressHandler` (0.0 – 1.0).
    /// Returns the local URL of the downloaded file in the tmp directory.
    func downloadResult(
        job: Job,
        progressHandler: @escaping (Double) -> Void
    ) async throws -> URL {
        guard let resultPath = job.resultUrl else {
            throw APIError.noResultURL
        }
        let resultURL: URL
        if resultPath.hasPrefix("http://") || resultPath.hasPrefix("https://") {
            guard let u = URL(string: resultPath) else { throw APIError.invalidURL(resultPath) }
            resultURL = u
        } else {
            resultURL = try url(resultPath)
        }

        let delegate = DownloadDelegate()
        delegate.progressHandler = progressHandler
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let task = session.downloadTask(with: resultURL)
        task.resume()

        return try await delegate.waitForCompletion()
    }

    /// Calls `GET /health` to verify the server is reachable.
    /// Returns `true` on any 2xx response.
    func testConnection() async throws -> Bool {
        let (_, response) = try await defaultSession.data(from: try url("/health"))
        guard let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }
}
