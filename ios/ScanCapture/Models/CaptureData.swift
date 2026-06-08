// CaptureData.swift
// ScanCapture
//
// Data structures that describe a single captured frame and the overall
// transforms.json written in Nerfstudio / NeRF-compatible format.

import Foundation
import simd

// MARK: - CaptureFrame

/// In-memory record of one captured ARKit frame before it is written to disk.
struct CaptureFrame: Identifiable {
    let id: UUID
    /// ARKit timestamp (seconds since device boot).
    let timestamp: Double
    /// Relative path inside the capture directory, e.g. "images/frame_0001.jpg".
    let imagePath: String
    /// 4×4 camera-to-world transform in OpenCV / Nerfstudio convention (column-major).
    let transformMatrix: [[Double]]
    /// Optional relative path to the 16-bit depth PNG, e.g. "depth/frame_0001.png".
    let depthMapPath: String?

    init(
        id: UUID = UUID(),
        timestamp: Double,
        imagePath: String,
        transformMatrix: [[Double]],
        depthMapPath: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.imagePath = imagePath
        self.transformMatrix = transformMatrix
        self.depthMapPath = depthMapPath
    }
}

// MARK: - FrameData (Nerfstudio)

/// One entry in the `frames` array of `transforms.json`.
struct FrameData: Codable {
    /// Relative path to the image, e.g. "images/frame_0001.jpg".
    let filePath: String
    /// 4×4 column-major transform as a flat row-major 2D array [[r0c0…r0c3], …].
    let transformMatrix: [[Double]]
    /// Optional depth map path.
    let depthFilePath: String?

    enum CodingKeys: String, CodingKey {
        case filePath        = "file_path"
        case transformMatrix = "transform_matrix"
        case depthFilePath   = "depth_file_path"
    }
}

// MARK: - TransformsJSON (Nerfstudio)

/// Top-level `transforms.json` written to the capture directory.
/// Conforms to the Nerfstudio dataset format so the file can be used directly
/// with `ns-train` or the Gaussian Splatting backend.
struct TransformsJSON: Codable {
    // Camera model identifier expected by Nerfstudio.
    let cameraModel: String
    /// Focal length x in pixels.
    let flX: Double
    /// Focal length y in pixels.
    let flY: Double
    /// Principal point x in pixels.
    let cx: Double
    /// Principal point y in pixels.
    let cy: Double
    /// Image width in pixels.
    let w: Int
    /// Image height in pixels.
    let h: Int
    /// Radial distortion k1 (ARKit uses a pinhole model, so 0).
    let k1: Double
    /// Radial distortion k2.
    let k2: Double
    /// Tangential distortion p1.
    let p1: Double
    /// Tangential distortion p2.
    let p2: Double
    /// Per-frame data.
    let frames: [FrameData]

    enum CodingKeys: String, CodingKey {
        case cameraModel = "camera_model"
        case flX  = "fl_x"
        case flY  = "fl_y"
        case cx
        case cy
        case w
        case h
        case k1
        case k2
        case p1
        case p2
        case frames
    }
}

// MARK: - simd_float4x4 → [[Double]] helpers

extension simd_float4x4 {

    /// Converts an ARKit camera transform (right-handed, Y-up, Z towards viewer)
    /// to the OpenCV / Nerfstudio convention (right-handed, Y-down, Z into scene)
    /// and returns it as a row-major 4×4 array of Doubles.
    ///
    /// The conversion flips the Y and Z axes on the right-hand side of the matrix,
    /// which is equivalent to left-multiplying by diag(1, -1, -1, 1).
    func toNerfstudioTransform() -> [[Double]] {
        // ARKit: columns are the basis vectors in world space.
        // Nerfstudio expects OpenCV: X right, Y down, Z forward.
        // Flip Y and Z rows (rows 1 and 2).
        let c0 = columns.0
        let c1 = columns.1
        let c2 = columns.2
        let c3 = columns.3

        // Build row-major 4×4 with flipped Y/Z
        return [
            [ Double(c0.x),  Double(c1.x),  Double(c2.x),  Double(c3.x)],
            [-Double(c0.y), -Double(c1.y), -Double(c2.y), -Double(c3.y)],
            [-Double(c0.z), -Double(c1.z), -Double(c2.z), -Double(c3.z)],
            [ Double(c0.w),  Double(c1.w),  Double(c2.w),  Double(c3.w)]
        ]
    }
}
