// CaptureView.swift
// ScanCapture
//
// Main capture screen: AR preview + HUD overlay + record button.

import ARKit
import Observation
import SceneKit
import SwiftUI
import UIKit

// MARK: - CaptureView

struct CaptureView: View {

    @Environment(AppSettings.self) private var settings
    @State private var viewModel: CaptureViewModel

    init(settings: AppSettings, apiClient: APIClient) {
        _viewModel = State(initialValue: CaptureViewModel(settings: settings, apiClient: apiClient))
    }

    var body: some View {
        ZStack {
            // AR camera feed
            ARSceneView(captureManager: viewModel.captureManager)
                .ignoresSafeArea()

            // Depth overlay
            if settings.enableDepthVisualization,
               let depthImage = viewModel.captureManager.currentDepthImage {
                Image(uiImage: depthImage)
                    .resizable()
                    .scaledToFill()
                    .opacity(0.4)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            // HUD
            VStack {
                statsOverlay
                    .padding(.top, 8)

                Spacer()

                if viewModel.state == .uploading {
                    uploadProgressView
                        .padding(.bottom, 8)
                }

                bottomControls
                    .padding(.bottom, 24)
            }
            .padding(.horizontal)
        }
        .alert("Error", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .onAppear {
            if viewModel.state == .idle {
                viewModel.captureManager.startSession()
            }
        }
        .onDisappear {
            if viewModel.state == .idle {
                viewModel.captureManager.stopSession()
            }
        }
    }

    // MARK: - Subviews

    private var statsOverlay: some View {
        HStack(spacing: 16) {
            statItem(label: "Frames", value: "\(viewModel.captureManager.frameCount)")
            Divider().frame(height: 20).background(Color.white.opacity(0.5))
            statItem(label: "FPS", value: String(format: "%.1f", viewModel.captureManager.fps))
            Divider().frame(height: 20).background(Color.white.opacity(0.5))
            statItem(label: "Points", value: "\(viewModel.captureManager.pointCloudCount)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func statItem(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.headline, design: .monospaced))
                .foregroundStyle(.white)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private var uploadProgressView: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Uploading…")
                    .font(.caption)
                    .foregroundStyle(.white)
                Spacer()
                Text("\(Int(viewModel.uploadProgress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white)
            }
            ProgressView(value: viewModel.uploadProgress)
                .tint(.white)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var bottomControls: some View {
        VStack(spacing: 16) {
            // Status text
            Text(statusText)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())

            HStack(spacing: 32) {
                // Depth visualisation toggle
                Button {
                    settings.enableDepthVisualization.toggle()
                } label: {
                    Image(systemName: settings.enableDepthVisualization
                          ? "square.3.layers.3d.top.filled"
                          : "square.3.layers.3d")
                        .font(.title2)
                        .foregroundStyle(settings.enableDepthVisualization ? .cyan : .white)
                        .frame(width: 48, height: 48)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .disabled(viewModel.state == .uploading)

                // Record / stop button
                recordButton

                // Reset button (shown after complete)
                Button {
                    if viewModel.state == .complete {
                        viewModel.resetToIdle()
                    }
                } label: {
                    Image(systemName: viewModel.state == .complete ? "arrow.counterclockwise" : "square.and.arrow.up")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .opacity(viewModel.state == .capturing ? 0 : 1)
                .disabled(viewModel.state == .capturing || viewModel.state == .uploading)
            }
        }
    }

    private var recordButton: some View {
        Button {
            handleRecordTap()
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(.white, lineWidth: 3)
                    .frame(width: 72, height: 72)

                if viewModel.state == .capturing {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.red)
                        .frame(width: 30, height: 30)
                } else {
                    Circle()
                        .fill(viewModel.state == .uploading ? .gray : .red)
                        .frame(width: 60, height: 60)
                }
            }
        }
        .disabled(viewModel.state == .uploading || viewModel.state == .complete)
        .animation(.easeInOut(duration: 0.2), value: viewModel.state)
    }

    // MARK: - Helpers

    private var statusText: String {
        switch viewModel.state {
        case .idle:      return viewModel.captureManager.captureProgress
        case .capturing: return viewModel.captureManager.captureProgress
        case .uploading: return "Uploading to server…"
        case .complete:
            if let id = viewModel.currentJobId {
                return "Uploaded – Job \(id.prefix(8))"
            }
            return "Upload complete"
        }
    }

    private func handleRecordTap() {
        switch viewModel.state {
        case .idle:
            viewModel.startCapture()
        case .capturing:
            Task { await viewModel.stopAndUpload() }
        case .uploading, .complete:
            break
        }
    }
}

// MARK: - ARSceneView (UIViewRepresentable)

private struct ARSceneView: UIViewRepresentable {

    let captureManager: ARCaptureManager

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        // Share the ARSession managed by ARCaptureManager.
        view.session = captureManager.session
        view.automaticallyUpdatesLighting = true
        view.preferredFramesPerSecond = 60
        view.rendersCameraGrain = false
        view.rendersMotionBlur = false
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
