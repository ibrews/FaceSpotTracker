import Foundation
import Vision
import CoreImage

/// One frame's QR-code-on-face observation from the back camera.
struct QRMarkerObservation {
    /// Decoded QR string (e.g. "SPOT1"). Empty if decode failed but barcode was detected.
    let payload: String
    /// QR center in Vision normalized coords (bottom-left origin, 0..1).
    let qrCenterVision: CGPoint
    /// Face bounding box in Vision normalized coords.
    let faceBBox: CGRect
    /// Nose tip in Vision normalized coords (most stable face landmark).
    let noseTip: CGPoint
    /// QR center relative to nose, measured in face-width units.
    /// (0,0) = on nose tip. Positive X = right from camera's view, positive Y = up.
    let offsetFromNose: CGPoint
    /// Face bounding box width in image coords (proxy for distance).
    let faceWidth: CGFloat
}

/// Detects QR codes and face landmarks simultaneously in a back-camera frame.
///
/// Workflow:
///   1. Run VNDetectBarcodesRequest to find QR codes.
///   2. Run VNDetectFaceLandmarksRequest to find the face + nose tip.
///   3. Compute each QR code's position relative to the nose tip, measured in face-width units.
///
/// Using face-width units makes the measurement scale-invariant (works at any distance).
/// Using the nose tip as origin makes it head-pose-semi-invariant (nose moves least during rotation).
///
/// Both requests run on the same VNImageRequestHandler for a single pixel-buffer lock.
class QRMarkerDetector {

    /// Process one back-camera frame. Returns observations for every QR code that has
    /// a co-visible face. If no face is detected, returns empty (we need the face reference).
    func processFrame(_ pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation = .right) -> [QRMarkerObservation] {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation)

        let barcodeRequest = VNDetectBarcodesRequest()
        barcodeRequest.symbologies = [.qr, .dataMatrix, .aztec]

        let faceRequest = VNDetectFaceLandmarksRequest()

        do {
            try handler.perform([barcodeRequest, faceRequest])
        } catch {
            return []
        }

        guard let face = faceRequest.results?.first else { return [] }
        guard let barcodes = barcodeRequest.results, !barcodes.isEmpty else { return [] }

        // Find nose tip (most stable landmark for face-relative positioning)
        let noseTip: CGPoint
        if let landmarks = face.landmarks,
           let noseCrest = landmarks.noseCrest,
           let tip = noseCrest.normalizedPoints.last {
            // Landmark points are in face-bbox-normalized coords (bottom-left origin).
            // Convert to full-image Vision coords.
            let bbox = face.boundingBox
            noseTip = CGPoint(
                x: bbox.origin.x + CGFloat(tip.x) * bbox.width,
                y: bbox.origin.y + CGFloat(tip.y) * bbox.height
            )
        } else {
            // Fallback: center of face bbox
            let bbox = face.boundingBox
            noseTip = CGPoint(
                x: bbox.midX,
                y: bbox.midY
            )
        }

        let faceBBox = face.boundingBox
        let faceW = faceBBox.width

        return barcodes.compactMap { barcode -> QRMarkerObservation? in
            guard faceW > 0.01 else { return nil }

            // QR center in Vision coords
            let qrBBox = barcode.boundingBox
            let qrCenter = CGPoint(x: qrBBox.midX, y: qrBBox.midY)

            // Offset from nose in face-width units (scale-invariant)
            let offsetX = (qrCenter.x - noseTip.x) / faceW
            let offsetY = (qrCenter.y - noseTip.y) / faceW

            let payload = barcode.payloadStringValue ?? ""

            return QRMarkerObservation(
                payload: payload,
                qrCenterVision: qrCenter,
                faceBBox: faceBBox,
                noseTip: noseTip,
                offsetFromNose: CGPoint(x: offsetX, y: offsetY),
                faceWidth: faceW
            )
        }
    }
}

// MARK: - Multi-frame accumulator

/// Accumulates QR marker observations across back-camera frames and produces
/// an averaged, stable face-relative position for each detected QR code.
///
/// Observations are grouped by QR payload (each QR sticker gets its own group).
/// The face-relative offset is averaged across frames, giving a smooth estimate
/// even if individual frames have slight detection jitter.
class QRMarkerAccumulator {

    struct AccumulatedMarker {
        let payload: String
        /// Averaged offset from nose in face-width units.
        let offsetFromNose: CGPoint
        /// Number of frames this QR was detected in.
        let frameCount: Int
        /// Spread of offset values — lower = more confident.
        let offsetSpread: CGFloat
    }

    private var observations: [String: [QRMarkerObservation]] = [:]

    var totalFrameCount: Int {
        observations.values.map(\.count).max() ?? 0
    }

    var detectedMarkerCount: Int {
        observations.count
    }

    var isEmpty: Bool { observations.isEmpty }

    func add(_ obs: [QRMarkerObservation]) {
        for o in obs {
            let key = o.payload.isEmpty ? "__unknown__" : o.payload
            observations[key, default: []].append(o)
        }
    }

    func reset() {
        observations.removeAll()
    }

    /// Compute averaged results for all detected QR markers.
    /// Minimum 3 frames required per marker for a result.
    func results(minFrames: Int = 3) -> [AccumulatedMarker] {
        observations.compactMap { (payload, obs) -> AccumulatedMarker? in
            guard obs.count >= minFrames else { return nil }

            let offsets = obs.map(\.offsetFromNose)

            // Median-based averaging (robust to outliers)
            let sortedX = offsets.map(\.x).sorted()
            let sortedY = offsets.map(\.y).sorted()
            let mid = offsets.count / 2
            let medianOffset = CGPoint(x: sortedX[mid], y: sortedY[mid])

            // Reject outliers (> 2× median absolute deviation)
            let deviations = offsets.map { sqrt(pow($0.x - medianOffset.x, 2) + pow($0.y - medianOffset.y, 2)) }
            let sortedDevs = deviations.sorted()
            let medianDev = sortedDevs[sortedDevs.count / 2]
            let threshold = max(medianDev * 2.5, 0.02) // at least 2% face-width tolerance

            let inliers = zip(offsets, deviations)
                .filter { $0.1 <= threshold }
                .map { $0.0 }

            guard !inliers.isEmpty else { return nil }

            let avgX = inliers.map(\.x).reduce(0, +) / CGFloat(inliers.count)
            let avgY = inliers.map(\.y).reduce(0, +) / CGFloat(inliers.count)

            // Spread = average distance from mean (lower = more stable)
            let spread = inliers.map { sqrt(pow($0.x - avgX, 2) + pow($0.y - avgY, 2)) }
                .reduce(0, +) / CGFloat(inliers.count)

            return AccumulatedMarker(
                payload: payload,
                offsetFromNose: CGPoint(x: avgX, y: avgY),
                frameCount: obs.count,
                offsetSpread: spread
            )
        }
        .sorted { $0.frameCount > $1.frameCount }
    }
}
