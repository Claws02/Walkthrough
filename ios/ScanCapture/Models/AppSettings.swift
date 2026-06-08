// AppSettings.swift
// ScanCapture
//
// Persistent application settings backed by UserDefaults via @AppStorage.

import SwiftUI
import Observation

@Observable
final class AppSettings {

    // MARK: - Stored Properties (backed by UserDefaults)

    @ObservationIgnored
    @AppStorage("serverURL")
    var serverURL: String = "http://localhost:8000"

    @ObservationIgnored
    @AppStorage("captureFrameRate")
    var captureFrameRate: Double = 5.0

    @ObservationIgnored
    @AppStorage("enableLiDAR")
    var enableLiDAR: Bool = true

    @ObservationIgnored
    @AppStorage("captureResolution")
    var captureResolution: String = "high"

    @ObservationIgnored
    @AppStorage("enableDepthVisualization")
    var enableDepthVisualization: Bool = false

    // MARK: - Computed helpers

    /// Available resolution options for the picker.
    static let resolutionOptions: [String] = ["high", "medium", "low"]

    /// Available frame-rate options for the picker.
    static let frameRateOptions: [Double] = [1, 3, 5, 10]

    // MARK: - Validation

    /// Returns `true` when `serverURL` looks like a reachable base URL.
    var isServerURLValid: Bool {
        guard let url = URL(string: serverURL),
              let scheme = url.scheme,
              (scheme == "http" || scheme == "https"),
              url.host != nil else {
            return false
        }
        return true
    }

    // MARK: - Reset

    func resetToDefaults() {
        serverURL = "http://localhost:8000"
        captureFrameRate = 5.0
        enableLiDAR = true
        captureResolution = "high"
        enableDepthVisualization = false
    }
}
