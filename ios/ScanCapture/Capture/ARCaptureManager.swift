// ARCaptureManager.swift
// ScanCapture
//
// Manages an ARKit session with LiDAR scene depth, captures frames at a
// configurable rate, and packages them into a Nerfstudio-compatible ZIP archive.

import ARKit
import CoreImage
import Foundation
import Observation
import simd
import UIKit
import ZIPFoundation

// MARK: - ARCaptureManager

@MainActor
@Observable
final class ARCaptureManager: NSObject {

    // MARK: - Observable state (all read/written on MainActor)

    var isRunning: Bool = false
    var isRecording: Bool = false
    var frameCount: Int = 0
    var pointCloudCount: Int = 0
    var fps: Double = 0.0
    var captureProgress: String = "Ready"
    var currentDepthImage: UIImage? = nil
    var currentFrame: ARFrame? = nil

    // MARK: - Internal – shared with ARSceneView

    /// Exposed as `internal` so ARSCNView in CaptureView can bind to the same session.
    nonisolated let session = ARSession()

    // MARK: - Private state

    private var settings: AppSettings

    /// Directory that receives frames during the current recording.
    private var outputDir: URL?

    /// In-memory list of captured frames.
    private var capturedFrames: [CaptureFrame] = []

    /// Timestamp of the last captured frame (used to throttle to configured FPS).
    private var lastCaptureTime: TimeInterval = 0

    /// Camera intrinsics captured from the first valid ARFrame.
    private var intrinsics: simd_float3x3?
    private var imageWidth: Int = 0
    private var imageHeight: Int = 0

    // MARK: - FPS tracking

    private var fpsFrameCount: Int = 0
    private var fpsLastTime: TimeInterval = 0

    // MARK: - Init

    init(settings: AppSettings) {
        self.settings = settings
        super.init()
        session.delegate = self
    }

    // MARK: - Session lifecycle

    func startSession() {
        guard ARWorldTrackingConfiguration.isSupported else {
            captureProgress = "ARKit not supported on this device"
            return
        }

        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity

        if settings.enableLiDAR,
           ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics = .sceneDepth
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics = .smoothedSceneDepth
        }

        if let format = videoFormat(for: settings.captureResolution) {
            config.videoFormat = format
        }

        config.isAutoFocusEnabled = true
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        isRunning = true
        captureProgress = "Session running"
    }

    func stopSession() {
        session.pause()
        isRunning = false
        captureProgress = "Session stopped"
    }

    // MARK: - Recording

    func startRecording(outputDir: URL) {
        guard !isRecording else { return }

        self.outputDir = outputDir
        capturedFrames = []
        lastCaptureTime = 0
        frameCount = 0

        let fm = FileManager.default
        let imagesDir = outputDir.appendingPathComponent("images")
        let depthDir  = outputDir.appendingPathComponent("depth")
        try? fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        if settings.enableLiDAR {
            try? fm.createDirectory(at: depthDir, withIntermediateDirectories: true)
        }

        isRecording = true
        captureProgress = "Recording…"
    }

    @discardableResult
    func stopRecording() -> URL? {
        guard isRecording, let dir = outputDir else { return nil }
        isRecording = false
        captureProgress = "Finalising…"
        writeTransformsJSON(to: dir)
        captureProgress = "Capture complete – \(capturedFrames.count) frames"
        return dir
    }

    // MARK: - Compression

    func compressCapture(captureDir: URL) async throws -> URL {
        let zipURL = captureDir
            .deletingLastPathComponent()
            .appendingPathComponent("capture.zip")
        try? FileManager.default.removeItem(at: zipURL)

        return try await Task.detached(priority: .userInitiated) {
            try FileManager.default.zipItem(at: captureDir, to: zipURL)
            return zipURL
        }.value
    }

    // MARK: - Frame capture (called from ARSessionDelegate on background queue)

    private nonisolated func captureFrame(_ frame: ARFrame, outputDir: URL, captureDepth: Bool, enableDepthViz: Bool) -> CaptureFrame? {
        let ciContext = CIContext()
        let pixelBuffer = frame.capturedImage
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

        // Determine next index by inspecting images dir.
        let imagesDir = outputDir.appendingPathComponent("images")
        let existingCount = (try? FileManager.default.contentsOfDirectory(atPath: imagesDir.path))?.count ?? 0
        let paddedIdx = String(format: "%04d", existingCount)
        let imageFilename = "frame_\(paddedIdx).jpg"
        let relImagePath = "images/\(imageFilename)"
        let imageURL = outputDir.appendingPathComponent(relImagePath)

        if let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) {
            let uiImage = UIImage(cgImage: cgImage)
            if let data = uiImage.jpegData(compressionQuality: 0.85) {
                try? data.write(to: imageURL)
            }
        }

        // Depth map
        var relDepthPath: String? = nil
        if captureDepth,
           let depthMap = frame.sceneDepth?.depthMap ?? frame.smoothedSceneDepth?.depthMap {
            let depthFilename = "frame_\(paddedIdx).png"
            relDepthPath = "depth/\(depthFilename)"
            let depthURL = outputDir.appendingPathComponent(relDepthPath!)
            saveDepthMap(depthMap, to: depthURL)
        }

        let matrix = frame.camera.transform.toNerfstudioTransform()

        return CaptureFrame(
            timestamp: frame.timestamp,
            imagePath: relImagePath,
            transformMatrix: matrix,
            depthMapPath: relDepthPath
        )
    }

    // MARK: - Transforms JSON

    private func writeTransformsJSON(to dir: URL) {
        guard let intr = intrinsics else { return }

        let frames = capturedFrames.map { cf in
            FrameData(
                filePath: cf.imagePath,
                transformMatrix: cf.transformMatrix,
                depthFilePath: cf.depthMapPath
            )
        }

        let transforms = TransformsJSON(
            cameraModel: "OPENCV",
            flX: Double(intr[0][0]),
            flY: Double(intr[1][1]),
            cx: Double(intr[2][0]),
            cy: Double(intr[2][1]),
            w: imageWidth,
            h: imageHeight,
            k1: 0.0,
            k2: 0.0,
            p1: 0.0,
            p2: 0.0,
            frames: frames
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(transforms) else { return }
        try? data.write(to: dir.appendingPathComponent("transforms.json"))
    }

    // MARK: - Depth helpers

    private nonisolated func saveDepthMap(_ depthMap: CVPixelBuffer, to url: URL) {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let width  = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard let baseAddr = CVPixelBufferGetBaseAddress(depthMap) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let floatBuffer = baseAddr.bindMemory(to: Float32.self, capacity: width * height)
        var uint16Buffer = [UInt16](repeating: 0, count: width * height)

        for row in 0..<height {
            for col in 0..<width {
                let stride = bytesPerRow / MemoryLayout<Float32>.size
                let depthMeters = floatBuffer[row * stride + col]
                let mm = min(max(depthMeters * 1000.0, 0), 65535)
                uint16Buffer[row * width + col] = UInt16(mm)
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceGray()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        guard let ctx = CGContext(
            data: &uint16Buffer,
            width: width, height: height,
            bitsPerComponent: 16,
            bytesPerRow: width * 2,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ), let cgImage = ctx.makeImage() else { return }

        if let data = UIImage(cgImage: cgImage).pngData() {
            try? data.write(to: url)
        }
    }

    private nonisolated func depthMapAsUIImage(_ depthMap: CVPixelBuffer) -> UIImage? {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let width  = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard let baseAddr = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let floatBuffer = baseAddr.bindMemory(to: Float32.self, capacity: width * height)
        var uint8Buffer = [UInt8](repeating: 0, count: width * height)
        let maxDepth: Float32 = 5.0

        for row in 0..<height {
            for col in 0..<width {
                let stride = bytesPerRow / MemoryLayout<Float32>.size
                let d = floatBuffer[row * stride + col]
                uint8Buffer[row * width + col] = UInt8(min(max(d / maxDepth * 255.0, 0), 255))
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: &uint8Buffer,
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ), let cgImage = ctx.makeImage() else { return nil }

        return UIImage(cgImage: cgImage)
    }

    // MARK: - Video format selection

    private nonisolated func videoFormat(for resolution: String) -> ARConfiguration.VideoFormat? {
        let formats = ARWorldTrackingConfiguration.supportedVideoFormats
        switch resolution {
        case "high":
            return formats
                .filter { $0.imageResolution.width >= 1920 }
                .max { $0.imageResolution.width < $1.imageResolution.width }
                ?? formats.last
        case "medium":
            return formats
                .filter { $0.imageResolution.width >= 1280 && $0.imageResolution.width < 1920 }
                .max { $0.imageResolution.width < $1.imageResolution.width }
                ?? formats.first
        case "low":
            return formats
                .filter { $0.imageResolution.width < 1280 }
                .min { $0.imageResolution.width < $1.imageResolution.width }
                ?? formats.first
        default:
            return nil
        }
    }
}

// MARK: - ARSessionDelegate

extension ARCaptureManager: ARSessionDelegate {

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Throttle check (no MainActor needed, lastCaptureTime is only set here).
        // Because of @MainActor on the class, we must hop to main to read isRecording.
        Task { @MainActor in
            currentFrame = frame

            // FPS tracking
            fpsFrameCount += 1
            let now = frame.timestamp
            if now - fpsLastTime >= 1.0 {
                fps = Double(fpsFrameCount) / max(now - fpsLastTime, 0.001)
                fpsFrameCount = 0
                fpsLastTime   = now
            }

            // Point cloud
            if let points = frame.rawFeaturePoints {
                pointCloudCount = points.points.count
            }

            guard isRecording, let dir = outputDir else { return }

            // Throttle to configured FPS
            let interval = 1.0 / settings.captureFrameRate
            guard frame.timestamp - lastCaptureTime >= interval else { return }
            lastCaptureTime = frame.timestamp

            // Capture intrinsics on first frame
            if intrinsics == nil {
                intrinsics  = frame.camera.intrinsics
                imageWidth  = CVPixelBufferGetWidth(frame.capturedImage)
                imageHeight = CVPixelBufferGetHeight(frame.capturedImage)
            }

            // Save frame data on a background thread to avoid blocking ARKit.
            let captureDepth   = settings.enableLiDAR
            let enableDepthViz = settings.enableDepthVisualization
            let depthMapOpt    = frame.sceneDepth?.depthMap ?? frame.smoothedSceneDepth?.depthMap

            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                if let captured = self.captureFrame(
                    frame,
                    outputDir: dir,
                    captureDepth: captureDepth,
                    enableDepthViz: enableDepthViz
                ) {
                    await MainActor.run {
                        self.capturedFrames.append(captured)
                        self.frameCount = self.capturedFrames.count
                        self.captureProgress = "Recording – \(self.capturedFrames.count) frames"
                    }
                }
                // Update depth preview if enabled
                if enableDepthViz, let dm = depthMapOpt {
                    let img = self.depthMapAsUIImage(dm)
                    await MainActor.run { self.currentDepthImage = img }
                }
            }
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        Task { @MainActor in
            captureProgress = "Session error: \(error.localizedDescription)"
        }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor in
            captureProgress = "Session interrupted"
        }
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        Task { @MainActor in
            captureProgress = "Session resumed"
        }
    }
}
