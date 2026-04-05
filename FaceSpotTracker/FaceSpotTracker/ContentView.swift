import SwiftUI
import PhotosUI

struct ContentView: View {
    @StateObject private var trackingManager = FaceTrackingManager()
    @State private var showingSpotList = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showingAnalysis = false

    var body: some View {
        ZStack {
            // AR Camera View (full screen)
            ARFaceView(trackingManager: trackingManager)
                .ignoresSafeArea()

            // Scanning overlay (front camera)
            if trackingManager.isScanning && !trackingManager.isUsingBackCamera {
                ScanningOverlayView(
                    detectedPositions: trackingManager.detectedMarkerScreenPositions,
                    progress: trackingManager.scanProgress,
                    hint: trackingManager.scanAngleHint
                )
            }

            // Back camera overlay (marker-based scan via reference image)
            if trackingManager.isUsingBackCamera && !trackingManager.isQRScanning {
                BackCameraOverlayView(trackingManager: trackingManager)
            }

            // QR marker scan overlay (back camera, Vision barcode detection)
            if trackingManager.isQRScanning {
                QRScanOverlayView(trackingManager: trackingManager)
            }

            // Overlay UI
            VStack {
                // Status bar at top
                HStack {
                    Circle()
                        .fill(trackingManager.isFaceTracked ? Color.green : Color.red)
                        .frame(width: 12, height: 12)
                    Text(statusText)
                        .font(.caption)
                        .foregroundColor(.white)
                    Spacer()
                    Text("\(trackingManager.markedSpots.count) spot(s)")
                        .font(.caption)
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.black.opacity(0.5))

                Spacer()

                // Image processing indicator
                if trackingManager.isProcessingImage {
                    HStack(spacing: 8) {
                        ProgressView()
                            .tint(.white)
                        Text("Detecting markers...")
                            .font(.callout)
                            .foregroundColor(.white)
                    }
                    .padding(12)
                    .background(.black.opacity(0.7))
                    .cornerRadius(8)
                }

                // Processing result toast
                if !trackingManager.imageProcessingResult.isEmpty && !trackingManager.isProcessingImage {
                    Text(trackingManager.imageProcessingResult)
                        .font(.callout)
                        .foregroundColor(.white)
                        .padding(12)
                        .background(.black.opacity(0.6))
                        .cornerRadius(8)
                        .transition(.opacity)
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                                withAnimation { trackingManager.imageProcessingResult = "" }
                            }
                        }
                }

                // Info text
                if trackingManager.markedSpots.isEmpty && trackingManager.isFaceTracked
                    && !trackingManager.isScanning && !trackingManager.isUsingBackCamera {
                    Text("Tap on your face or neck to mark a spot")
                        .font(.callout)
                        .foregroundColor(.white)
                        .padding(12)
                        .background(.black.opacity(0.6))
                        .cornerRadius(8)
                        .padding(.bottom, 8)
                }

                // Bottom controls
                if !trackingManager.isUsingBackCamera {
                    HStack(spacing: 14) {
                        // Clear all spots
                        Button(action: {
                            trackingManager.clearAllSpots()
                        }) {
                            Label("Clear", systemImage: "trash")
                                .font(.callout)
                                .foregroundColor(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(.red.opacity(0.7))
                                .cornerRadius(8)
                        }
                        .disabled(trackingManager.markedSpots.isEmpty)

                        // Scan controls
                        if trackingManager.isScanning {
                            // Camera swap button
                            Button(action: {
                                trackingManager.swapToBackCamera()
                            }) {
                                Label("Back Cam", systemImage: "arrow.triangle.2.circlepath.camera")
                                    .font(.callout)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .background(.indigo.opacity(0.8))
                                    .cornerRadius(8)
                            }

                            Button(action: {
                                trackingManager.stopScanning()
                            }) {
                                Label("Done", systemImage: "checkmark.circle")
                                    .font(.callout)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .background(.green.opacity(0.8))
                                    .cornerRadius(8)
                            }
                        } else {
                            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                                Label("Scan", systemImage: "viewfinder")
                                    .font(.callout)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .background(.purple.opacity(0.7))
                                    .cornerRadius(8)
                            }
                            .disabled(!trackingManager.isFaceTracked)

                            // QR marker scan: back camera, place a QR sticker on the spot
                            Button(action: {
                                trackingManager.startQRScan()
                            }) {
                                Label("QR Scan", systemImage: "qrcode.viewfinder")
                                    .font(.callout)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .background(.teal.opacity(0.8))
                                    .cornerRadius(8)
                            }
                        }

                        // Spot list
                        Button(action: {
                            showingSpotList.toggle()
                        }) {
                            Label("Spots", systemImage: "list.bullet")
                                .font(.callout)
                                .foregroundColor(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(.blue.opacity(0.7))
                                .cornerRadius(8)
                        }

                        // Undo last spot
                        Button(action: {
                            trackingManager.removeLastSpot()
                        }) {
                            Label("Undo", systemImage: "arrow.uturn.backward")
                                .font(.callout)
                                .foregroundColor(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(.orange.opacity(0.7))
                                .cornerRadius(8)
                        }
                        .disabled(trackingManager.markedSpots.isEmpty)

                        // On-device AI analysis
                        Button(action: { showingAnalysis = true }) {
                            Label("Analyze", systemImage: "sparkles")
                                .font(.callout)
                                .foregroundColor(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(.indigo.opacity(0.85))
                                .cornerRadius(8)
                        }
                    }
                    .padding(.bottom, 30)
                }
            }

            // Spot list overlay
            if showingSpotList {
                SpotListView(
                    spots: trackingManager.markedSpots,
                    onDismiss: { showingSpotList = false },
                    onDelete: { spot in
                        trackingManager.removeSpot(id: spot.id)
                    }
                )
            }
        }
        .onChange(of: selectedPhoto) { newItem in
            guard let item = newItem else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    trackingManager.startScanning(withReferenceImage: image)
                }
                selectedPhoto = nil
            }
        }
        .sheet(isPresented: $showingAnalysis) {
            SkinAnalysisView()
        }
    }

    private var statusText: String {
        if trackingManager.isQRScanning {
            let f = trackingManager.qrScanFrameCount
            let m = trackingManager.qrScanMarkerCount
            return "QR Scan — \(f) frames, \(m) marker(s)"
        } else if trackingManager.isUsingBackCamera {
            return "Back Camera — Marker Scan"
        } else if trackingManager.isFaceTracked {
            return "Face Tracked"
        } else {
            return "No Face Detected"
        }
    }
}

// MARK: - Back Camera Overlay

struct BackCameraOverlayView: View {
    @ObservedObject var trackingManager: FaceTrackingManager

    var body: some View {
        ZStack {
            // Green circle on detected marker
            if let pos = trackingManager.backCameraMarkerScreenPos,
               trackingManager.backCameraMarkerDetected {
                Circle()
                    .stroke(Color.green, lineWidth: 3)
                    .frame(width: 50, height: 50)
                    .position(pos)

                Circle()
                    .fill(Color.green.opacity(0.3))
                    .frame(width: 50, height: 50)
                    .position(pos)
            }

            VStack {
                // Detection status
                HStack(spacing: 20) {
                    HStack(spacing: 6) {
                        Image(systemName: trackingManager.backCameraMarkerDetected ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundColor(trackingManager.backCameraMarkerDetected ? .green : .red)
                        Text("Marker")
                            .font(.caption.bold())
                            .foregroundColor(.white)
                    }

                    HStack(spacing: 6) {
                        Image(systemName: trackingManager.backCameraFaceDetected ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundColor(trackingManager.backCameraFaceDetected ? .green : .red)
                        Text("Face")
                            .font(.caption.bold())
                            .foregroundColor(.white)
                    }
                }
                .padding(10)
                .background(.black.opacity(0.8))
                .cornerRadius(8)

                Spacer()

                // Instructions
                VStack(spacing: 8) {
                    Text(trackingManager.debugInfo)
                        .font(.callout)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)

                    Text("Point the back camera at the marker on your face or neck")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
                .padding(16)
                .background(.black.opacity(0.7))
                .cornerRadius(12)

                // Action buttons
                HStack(spacing: 16) {
                    Button(action: {
                        trackingManager.cancelBackCamera()
                    }) {
                        Label("Back", systemImage: "arrow.uturn.backward")
                            .font(.callout)
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(.gray.opacity(0.7))
                            .cornerRadius(8)
                    }

                    Button(action: {
                        trackingManager.captureBackCameraResult()
                    }) {
                        Label("Capture", systemImage: "camera.fill")
                            .font(.callout.bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .background(
                                (trackingManager.backCameraMarkerDetected && trackingManager.backCameraFaceDetected)
                                    ? Color.green.opacity(0.8)
                                    : Color.green.opacity(0.3)
                            )
                            .cornerRadius(8)
                    }
                    .disabled(!trackingManager.backCameraMarkerDetected || !trackingManager.backCameraFaceDetected)
                }
                .padding(.bottom, 40)
            }
        }
        .allowsHitTesting(true)
    }
}

// MARK: - QR Scan Overlay

/// Overlay shown during back-camera QR marker scan mode.
/// The user places a small QR-code sticker on the spot to track, then points
/// the back camera at their face. Vision detects the QR code + face landmarks
/// simultaneously, accumulating position data across multiple frames.
struct QRScanOverlayView: View {
    @ObservedObject var trackingManager: FaceTrackingManager

    var body: some View {
        ZStack {
            VStack {
                // Status bar
                HStack(spacing: 16) {
                    HStack(spacing: 6) {
                        Image(systemName: trackingManager.backCameraFaceDetected
                              ? "face.smiling.inverse" : "face.dashed")
                            .foregroundColor(trackingManager.backCameraFaceDetected ? .green : .orange)
                        Text(trackingManager.backCameraFaceDetected ? "Face" : "No face")
                            .font(.caption.bold())
                            .foregroundColor(.white)
                    }

                    HStack(spacing: 6) {
                        Image(systemName: trackingManager.backCameraMarkerDetected
                              ? "qrcode" : "qrcode")
                            .foregroundColor(trackingManager.backCameraMarkerDetected ? .green : .orange)
                            .font(.caption)
                        Text(trackingManager.backCameraMarkerDetected ? "QR found" : "No QR")
                            .font(.caption.bold())
                            .foregroundColor(.white)
                    }

                    Spacer()

                    HStack(spacing: 4) {
                        Text("\(trackingManager.qrScanFrameCount) frames")
                            .font(.caption.bold())
                            .foregroundColor(.white)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.black.opacity(0.75))
                .cornerRadius(10)

                Spacer()

                // Hint
                VStack(spacing: 8) {
                    Text(trackingManager.qrScanHint)
                        .font(.callout)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .animation(.easeInOut, value: trackingManager.qrScanHint)

                    Text("Place a QR sticker on the spot, then point back camera at face")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                }
                .padding(16)
                .background(.black.opacity(0.7))
                .cornerRadius(12)

                // Action buttons
                HStack(spacing: 16) {
                    Button(action: {
                        trackingManager.cancelQRScan()
                    }) {
                        Label("Cancel", systemImage: "xmark")
                            .font(.callout)
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(.gray.opacity(0.7))
                            .cornerRadius(8)
                    }

                    Button(action: {
                        trackingManager.stopQRScan()
                    }) {
                        Label(
                            trackingManager.qrScanMarkerCount > 0
                                ? "Place \(trackingManager.qrScanMarkerCount) Spot(s)"
                                : "Done",
                            systemImage: "checkmark.circle.fill"
                        )
                        .font(.callout.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(
                            trackingManager.qrScanMarkerCount > 0
                                ? Color.teal.opacity(0.85)
                                : Color.teal.opacity(0.4)
                        )
                        .cornerRadius(8)
                    }
                }
                .padding(.bottom, 40)
            }
        }
        .allowsHitTesting(true)
    }
}

// MARK: - Spot List

struct SpotListView: View {
    let spots: [MarkedSpot]
    let onDismiss: () -> Void
    let onDelete: (MarkedSpot) -> Void

    var body: some View {
        VStack {
            HStack {
                Text("Marked Spots")
                    .font(.headline)
                Spacer()
                Button("Done") { onDismiss() }
            }
            .padding()

            if spots.isEmpty {
                Text("No spots marked yet")
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                List {
                    ForEach(spots) { spot in
                        HStack {
                            ZStack {
                                Circle()
                                    .stroke(spot.confidenceColor, lineWidth: 2)
                                    .frame(width: 22, height: 22)
                                Circle()
                                    .fill(spot.color)
                                    .frame(width: 14, height: 14)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(spot.label ?? "Spot \(spot.index)")
                                        .font(.body)
                                    if spot.isExtrapolated {
                                        Text("EXT")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(.orange)
                                            .cornerRadius(3)
                                    }
                                }
                                Text("Vertex \(spot.nearestVertexIndex) \u{2022} \(spot.region.rawValue)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(spot.confidenceColor)
                                        .frame(width: 6, height: 6)
                                    Text("\(spot.confidenceLabel) confidence (\(Int(spot.confidence * 100))%)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    Text("\u{2022}")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    Text(spot.createdAt, style: .relative)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                if spot.vertexDistance > 0.001 {
                                    Text(String(format: "\u{00B1}%.1fmm margin", spot.vertexDistance * 1000))
                                        .font(.caption2)
                                        .foregroundColor(spot.confidenceColor)
                                }
                            }
                            Spacer()
                            Button(action: { onDelete(spot) }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.red.opacity(0.7))
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: 450)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .padding()
    }
}

// MARK: - Scanning Overlay

struct ScanningOverlayView: View {
    let detectedPositions: [CGPoint]
    let progress: [UUID: AngleCoverage]
    let hint: String

    var body: some View {
        ZStack {
            ForEach(Array(detectedPositions.enumerated()), id: \.offset) { _, position in
                Circle()
                    .stroke(Color.green, lineWidth: 2)
                    .frame(width: 30, height: 30)
                    .position(position)
            }

            VStack {
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(.green)
                    Text("SCANNING")
                        .font(.caption.bold())
                        .foregroundColor(.green)
                }
                .padding(8)
                .background(.black.opacity(0.7))
                .cornerRadius(8)

                Spacer()

                VStack(spacing: 6) {
                    Text(hint)
                        .font(.callout)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)

                    if !progress.isEmpty {
                        let overallProgress = progress.values.map(\.fraction).min() ?? 0
                        ProgressView(value: Double(overallProgress))
                            .tint(.green)
                            .frame(width: 200)
                        Text("\(Int(overallProgress * 100))% coverage")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.8))
                    }

                    Text("\(progress.count) marker(s) detected")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                }
                .padding(16)
                .background(.black.opacity(0.7))
                .cornerRadius(12)
                .padding(.bottom, 80)
            }
        }
        .allowsHitTesting(false)
    }
}
