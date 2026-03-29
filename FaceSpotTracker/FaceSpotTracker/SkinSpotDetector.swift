import UIKit
import Vision
import Accelerate

/// A candidate spot detected in the skin via image analysis.
struct SkinSpotCandidate {
    /// Position within the face bounding box, 0..1 (top-left origin).
    let normalizedPosition: CGPoint
    /// 0..1 — how much redder/more inflamed this cluster is relative to the surrounding skin.
    let severity: Float
    /// Number of pixels in the cluster. Larger = more confident.
    let pixelCount: Int
    /// Average color of the cluster pixels.
    let avgColor: (r: UInt8, g: UInt8, b: UInt8)
}

/// Detects potential pimples/spots by analyzing redness and saturation anomalies in a face image.
///
/// The back camera provides much higher resolution than the front TrueDepth camera, making
/// it suitable for skin texture analysis. This detector:
///   1. Establishes a baseline skin tone from the outer regions of the face bounding box.
///   2. Flags pixels that deviate significantly toward red/inflamed (elevated redness and saturation).
///   3. Clusters flagged pixels spatially.
///   4. Returns candidates above a minimum cluster size.
///
/// NOTE: ARKit's ARFaceTrackingConfiguration (face mesh + blendshapes) requires the front
/// TrueDepth camera and does NOT work with the back camera. The back camera only supports
/// ARWorldTrackingConfiguration, which gives world pose but no face mesh. That's why this
/// detector works purely from the back camera's 2D image, using Vision for face detection.
enum SkinSpotDetector {

    // MARK: - Configuration

    /// Maximum image dimension for analysis — balances detail vs speed.
    private static let maxAnalysisDim = 480

    /// Pixels that deviate this much in redness from baseline are flagged.
    private static let rednessThreshold: Float = 0.10

    /// Pixel saturation must exceed this to qualify (filters pale/white and very dark areas).
    private static let saturationFloor: Float = 0.12

    /// Value (brightness) must be in this range to exclude shadows and specular highlights.
    private static let valueMin: Float = 0.15
    private static let valueMax: Float = 0.97

    /// Spatial clustering radius in pixels (at analysis resolution).
    private static let clusterRadius = 18

    /// Minimum pixels in a cluster to report as a candidate.
    private static let minClusterSize = 6

    /// Maximum cluster size — anything larger is probably a blush zone or lighting artifact.
    private static let maxClusterFraction: Float = 0.04   // 4% of face-bbox area

    // MARK: - Public API

    /// Analyze a face image for skin spots.
    ///
    /// - Parameters:
    ///   - faceImage: The full camera frame (or any image containing the face).
    ///   - faceObservation: A Vision face observation for the face region (provides bounding box + landmarks).
    /// - Returns: Array of candidates sorted by severity descending.
    static func detectSpots(
        in faceImage: UIImage,
        faceObservation: VNFaceObservation
    ) -> [SkinSpotCandidate] {
        guard let cgImage = faceImage.cgImage else { return [] }
        return detectSpots(in: cgImage, faceObservation: faceObservation, imageOrientation: faceImage.imageOrientation)
    }

    /// Analyze a CVPixelBuffer (ARFrame.capturedImage) for skin spots.
    ///
    /// - Parameters:
    ///   - pixelBuffer: The camera frame buffer.
    ///   - faceObservation: Vision face observation for the face region.
    ///   - viewportSize: The ARSCNView viewport size (needed for coordinate mapping).
    ///   - captureOrientation: The CGImagePropertyOrientation matching how Vision saw this frame.
    static func detectSpots(
        in pixelBuffer: CVPixelBuffer,
        faceObservation: VNFaceObservation,
        captureOrientation: CGImagePropertyOrientation = .right
    ) -> [SkinSpotCandidate] {
        // Convert pixel buffer to CGImage
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

        // Apply orientation so coordinates match Vision's expectations
        let orientedCI: CIImage
        switch captureOrientation {
        case .right:
            // Back camera in portrait: image buffer is rotated 90° CCW from display
            orientedCI = ciImage.oriented(.right)
        default:
            orientedCI = ciImage
        }

        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(orientedCI, from: orientedCI.extent) else { return [] }

        return detectSpots(in: cgImage, faceObservation: faceObservation, imageOrientation: .up)
    }

    // MARK: - Core Detection

    private static func detectSpots(
        in cgImage: CGImage,
        faceObservation: VNFaceObservation,
        imageOrientation: UIImage.Orientation
    ) -> [SkinSpotCandidate] {
        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)

        // Vision bounding box: bottom-left origin, 0..1 → convert to pixel rect (top-left origin)
        let bbox = faceObservation.boundingBox
        let faceRect = CGRect(
            x: bbox.origin.x * imgW,
            y: (1.0 - bbox.origin.y - bbox.height) * imgH,
            width: bbox.width * imgW,
            height: bbox.height * imgH
        )

        // Slightly expand the face rect to include the immediate hairline and chin
        let expanded = faceRect.insetBy(dx: -faceRect.width * 0.05, dy: -faceRect.height * 0.08)
        let clipped = expanded.intersection(CGRect(x: 0, y: 0, width: imgW, height: imgH))
        guard clipped.width > 20, clipped.height > 20 else { return [] }

        guard let faceRegionCG = cgImage.cropping(to: clipped) else { return [] }

        // Downsample for analysis
        let scale = min(
            CGFloat(maxAnalysisDim) / clipped.width,
            CGFloat(maxAnalysisDim) / clipped.height,
            1.0
        )
        let aW = max(1, Int(clipped.width * scale))
        let aH = max(1, Int(clipped.height * scale))

        // Render into an RGBA buffer
        let bytesPerRow = aW * 4
        var pixels = [UInt8](repeating: 0, count: aH * bytesPerRow)
        let cs = CGColorSpaceCreateDeviceRGB()
        let bi = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(
            data: &pixels, width: aW, height: aH,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: cs, bitmapInfo: bi
        ) else { return [] }
        ctx.draw(faceRegionCG, in: CGRect(x: 0, y: 0, width: aW, height: aH))

        // Sample baseline skin tone from the border region of the face rect
        // (edges tend to be more "average" skin, away from the central features that may be redder)
        let baseline = sampleBaselineSkin(pixels: pixels, width: aW, height: aH, bytesPerRow: bytesPerRow)

        // Detect anomalous pixels
        let flagged = findAnomalousPixels(
            pixels: pixels, width: aW, height: aH, bytesPerRow: bytesPerRow,
            baseline: baseline
        )

        guard !flagged.isEmpty else { return [] }

        // Cluster flagged pixels
        let maxAllowed = Int(Float(aW * aH) * maxClusterFraction)
        let clusters = clusterPoints(flagged, radius: clusterRadius)
            .filter { $0.count >= minClusterSize && $0.count < maxAllowed }

        // Convert clusters to candidates
        return clusters.map { cluster -> SkinSpotCandidate in
            let avgX = cluster.map { CGFloat($0.x) }.reduce(0, +) / CGFloat(cluster.count)
            let avgY = cluster.map { CGFloat($0.y) }.reduce(0, +) / CGFloat(cluster.count)

            // Map analysis-resolution coords back to face-bbox normalized coords
            let faceNormX = (avgX / CGFloat(aW)) * (clipped.width / faceRect.width)
                + (clipped.origin.x - faceRect.origin.x) / faceRect.width
            let faceNormY = (avgY / CGFloat(aH)) * (clipped.height / faceRect.height)
                + (clipped.origin.y - faceRect.origin.y) / faceRect.height

            // Average color and severity
            var totalR = 0, totalG = 0, totalB = 0
            var totalRedness: Float = 0
            for pt in cluster {
                let off = pt.y * bytesPerRow + pt.x * 4
                let r = pixels[off], g = pixels[off + 1], b = pixels[off + 2]
                totalR += Int(r); totalG += Int(g); totalB += Int(b)
                let redness = Float(r) / 255.0 - (Float(g) + Float(b)) / 510.0
                totalRedness += redness
            }
            let n = cluster.count
            let avgR = UInt8(totalR / n)
            let avgG = UInt8(totalG / n)
            let avgB = UInt8(totalB / n)
            let avgRedness = totalRedness / Float(n)
            let severity = min(1.0, max(0.0, (avgRedness - baseline.redness) / 0.30))

            return SkinSpotCandidate(
                normalizedPosition: CGPoint(x: faceNormX, y: faceNormY),
                severity: severity,
                pixelCount: n,
                avgColor: (avgR, avgG, avgB)
            )
        }
        .sorted { $0.severity > $1.severity }
    }

    // MARK: - Baseline Skin Sampling

    private struct SkinBaseline {
        let redness: Float        // average redness index of baseline pixels
        let avgHue: Float         // average hue (skin hue range 0.02..0.10)
        let avgSaturation: Float  // baseline saturation
    }

    /// Sample skin color from the border ring of the face region (avoids nose, spots, eyes).
    private static func sampleBaselineSkin(
        pixels: [UInt8], width: Int, height: Int, bytesPerRow: Int
    ) -> SkinBaseline {
        let borderFrac = 0.15   // outer 15% of each side
        let bx = Int(CGFloat(width) * borderFrac)
        let by = Int(CGFloat(height) * borderFrac)

        var totalRedness: Float = 0
        var totalHue: Float = 0
        var totalSat: Float = 0
        var count = 0

        let step = 3
        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                // Only sample pixels in the border ring
                let inBorder = x < bx || x >= (width - bx) || y < by || y >= (height - by)
                guard inBorder else { continue }

                let off = y * bytesPerRow + x * 4
                let r = pixels[off], g = pixels[off + 1], b = pixels[off + 2]
                let rf = Float(r) / 255.0
                let gf = Float(g) / 255.0
                let bf = Float(b) / 255.0

                let (h, s, v) = rgbToHSV(r: rf, g: gf, b: bf)

                // Only include pixels that look like skin (hue in skin range, reasonable brightness)
                let isSkinHue = (h < 0.15 || h > 0.93)   // red-orange range or near 360°
                let isReasonable = v > 0.2 && v < 0.95 && s > 0.05
                guard isSkinHue && isReasonable else { continue }

                let redness = rf - (gf + bf) / 2.0
                totalRedness += redness
                totalHue += h
                totalSat += s
                count += 1
            }
        }

        guard count > 0 else {
            // Fallback: use average Fitzpatrick scale skin redness
            return SkinBaseline(redness: 0.12, avgHue: 0.04, avgSaturation: 0.35)
        }

        return SkinBaseline(
            redness: totalRedness / Float(count),
            avgHue: totalHue / Float(count),
            avgSaturation: totalSat / Float(count)
        )
    }

    // MARK: - Anomaly Detection

    private struct FlaggedPixel {
        let x: Int
        let y: Int
    }

    private static func findAnomalousPixels(
        pixels: [UInt8], width: Int, height: Int, bytesPerRow: Int,
        baseline: SkinBaseline
    ) -> [FlaggedPixel] {
        var flagged: [FlaggedPixel] = []

        // Avoid processing every pixel for speed — step by 2 (still catches clusters of 6+)
        let step = 2

        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                let off = y * bytesPerRow + x * 4
                let r = pixels[off], g = pixels[off + 1], b = pixels[off + 2]
                let rf = Float(r) / 255.0
                let gf = Float(g) / 255.0
                let bf = Float(b) / 255.0

                let (_, s, v) = rgbToHSV(r: rf, g: gf, b: bf)
                let redness = rf - (gf + bf) / 2.0

                // Must be bright enough (not shadow) and not too bright (not specular)
                guard v >= valueMin && v <= valueMax else { continue }
                // Must have some saturation (not grey/white)
                guard s >= saturationFloor else { continue }
                // Must be significantly redder than the skin baseline
                guard redness > baseline.redness + rednessThreshold else { continue }

                flagged.append(FlaggedPixel(x: x, y: y))
            }
        }

        return flagged
    }

    // MARK: - Spatial Clustering

    private static func clusterPoints(_ points: [FlaggedPixel], radius: Int) -> [[FlaggedPixel]] {
        guard !points.isEmpty else { return [] }

        var used = [Bool](repeating: false, count: points.count)
        var clusters: [[FlaggedPixel]] = []

        for i in 0..<points.count {
            if used[i] { continue }
            var cluster = [points[i]]
            used[i] = true

            for j in (i + 1)..<points.count {
                if used[j] { continue }
                let dx = abs(points[i].x - points[j].x)
                let dy = abs(points[i].y - points[j].y)
                if dx <= radius && dy <= radius {
                    cluster.append(points[j])
                    used[j] = true
                }
            }

            if cluster.count >= minClusterSize {
                clusters.append(cluster)
            }
        }

        return clusters
    }

    // MARK: - Math Helpers

    @inline(__always)
    private static func rgbToHSV(r: Float, g: Float, b: Float) -> (h: Float, s: Float, v: Float) {
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let delta = maxC - minC
        let v = maxC
        let s = maxC > 0 ? delta / maxC : 0

        var h: Float = 0
        if delta > 0 {
            if maxC == r      { h = (g - b) / delta }
            else if maxC == g { h = 2 + (b - r) / delta }
            else              { h = 4 + (r - g) / delta }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, s, v)
    }
}

// MARK: - Frame-level skin observation (used by accumulator)

/// One frame's worth of skin spot observations, paired with the camera's face position.
struct SkinScanFrame {
    /// Detected spot candidates in this frame.
    let candidates: [SkinSpotCandidate]
    /// Face bounding box in Vision normalized coords (bottom-left origin) — used for cross-frame dedup.
    let faceBBox: CGRect
    /// Approximate frame index (for temporal weighting).
    let frameIndex: Int
}

// MARK: - Multi-frame accumulator

/// Accumulates skin spot candidates across multiple back-camera frames and produces a
/// deduplicated, confidence-weighted set of candidate spots.
///
/// Candidates from different frames are merged if their face-normalized positions
/// are within `mergeRadius`. The merged candidate's severity is the weighted average;
/// pixelCount accumulates as a proxy for how many frames detected it (more = more confident).
class SkinScanAccumulator {

    private(set) var frames: [SkinScanFrame] = []
    private let mergeRadius: Double = 0.08    // 8% of face bbox width/height

    /// Minimum number of frames a candidate must appear in to be reported.
    var minFrameCount = 2

    func add(_ frame: SkinScanFrame) {
        frames.append(frame)
    }

    func reset() {
        frames.removeAll()
    }

    var totalCandidatesObserved: Int {
        frames.reduce(0) { $0 + $1.candidates.count }
    }

    /// Merge all accumulated candidates and return deduplicated results,
    /// sorted by combined confidence (frameCount × severity).
    func mergedCandidates() -> [MergedSkinCandidate] {
        var groups: [[SkinSpotCandidate]] = []

        for frame in frames {
            for candidate in frame.candidates {
                if let idx = groups.indices.first(where: { groupIdx in
                    let existing = groups[groupIdx]
                    guard let rep = existing.first else { return false }
                    let dx = candidate.normalizedPosition.x - rep.normalizedPosition.x
                    let dy = candidate.normalizedPosition.y - rep.normalizedPosition.y
                    return sqrt(dx * dx + dy * dy) < mergeRadius
                }) {
                    groups[idx].append(candidate)
                } else {
                    groups.append([candidate])
                }
            }
        }

        return groups
            .filter { $0.count >= minFrameCount }
            .map { group -> MergedSkinCandidate in
                let avgX = group.map(\.normalizedPosition.x).reduce(0, +) / Double(group.count)
                let avgY = group.map(\.normalizedPosition.y).reduce(0, +) / Double(group.count)
                let avgSeverity = group.map(\.severity).reduce(0, +) / Float(group.count)
                let totalPixels = group.map(\.pixelCount).reduce(0, +)
                let bestColor = group.max(by: { $0.severity < $1.severity })?.avgColor ?? (200, 120, 100)

                // Confidence: severity × detection frequency × cluster size
                let frameWeight = min(1.0, Float(group.count) / 5.0)
                let sizeWeight = min(1.0, Float(totalPixels) / 200.0)
                let confidence = min(0.90, avgSeverity * 0.50 + frameWeight * 0.35 + sizeWeight * 0.15)

                return MergedSkinCandidate(
                    normalizedPosition: CGPoint(x: avgX, y: avgY),
                    severity: avgSeverity,
                    frameCount: group.count,
                    totalPixels: totalPixels,
                    avgColor: bestColor,
                    confidence: confidence
                )
            }
            .sorted { $0.confidence > $1.confidence }
    }
}

/// A deduplicated, multi-frame skin spot candidate ready to be mapped to the face mesh.
struct MergedSkinCandidate {
    /// Position within face bounding box (Vision bbox, top-left origin 0..1).
    let normalizedPosition: CGPoint
    let severity: Float
    /// How many frames this candidate appeared in.
    let frameCount: Int
    let totalPixels: Int
    let avgColor: (r: UInt8, g: UInt8, b: UInt8)
    /// Overall confidence 0..1, accounting for severity + frame count + cluster size.
    let confidence: Float
}
