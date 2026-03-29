import UIKit
import Vision
import CoreImage

/// Detects colored markers/targets on a face in a photo and maps them to face mesh coordinates
enum ImageMarkerDetector {

    struct DetectedMarker {
        let normalizedPosition: CGPoint // Position within face bounding box (0-1, top-left origin)
        let avgR: UInt8
        let avgG: UInt8
        let avgB: UInt8
        let size: Int // cluster pixel count
    }

    /// Detect colored markers on a face in the given image.
    /// Returns marker positions mapped to ARKit face mesh local coordinates.
    /// Call from a background thread — this runs synchronously.
    static func detectMarkers(in image: UIImage) -> [(position: SIMD3<Float>, confidence: Float)] {
        guard let cgImage = image.cgImage else { return [] }

        let orientation = visionOrientation(from: image.imageOrientation)
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])

        // Detect face with landmarks
        var faceObservation: VNFaceObservation?
        let faceRequest = VNDetectFaceLandmarksRequest { request, _ in
            faceObservation = (request.results as? [VNFaceObservation])?.first
        }

        do {
            try handler.perform([faceRequest])
        } catch {
            return []
        }

        guard let face = faceObservation else { return [] }

        // Find colored markers in the face region
        let markers = findColoredMarkers(in: cgImage, face: face, imageOrientation: orientation)

        // Map marker positions to face mesh coordinates
        return markers.map { marker in
            let meshPos = mapToFaceMesh(normalizedPosition: marker.normalizedPosition, face: face)
            // Confidence: moderate for image detection, scaled by marker size
            let sizeConfidence = min(1.0, Float(marker.size) / 50.0)
            let confidence = 0.55 * sizeConfidence + 0.15
            return (meshPos, min(0.75, confidence))
        }
    }

    // MARK: - Marker Detection

    /// Find colored marker blobs within the face region using saturation analysis
    private static func findColoredMarkers(
        in cgImage: CGImage,
        face: VNFaceObservation,
        imageOrientation: CGImagePropertyOrientation
    ) -> [DetectedMarker] {
        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)

        // Face bounding box in pixel coordinates (top-left origin)
        let bbox = face.boundingBox
        let faceRect = CGRect(
            x: bbox.origin.x * imageWidth,
            y: (1 - bbox.origin.y - bbox.height) * imageHeight,
            width: bbox.width * imageWidth,
            height: bbox.height * imageHeight
        )

        // Expand to include neck area below the face
        let expandedRect = CGRect(
            x: faceRect.origin.x - faceRect.width * 0.15,
            y: faceRect.origin.y - faceRect.height * 0.1,
            width: faceRect.width * 1.3,
            height: faceRect.height * 1.5
        )
        let clippedRect = expandedRect.intersection(
            CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight)
        )

        guard let croppedCG = cgImage.cropping(to: clippedRect) else { return [] }

        // Downsample for performance
        let maxDim: CGFloat = 500
        let scale = min(maxDim / CGFloat(croppedCG.width), maxDim / CGFloat(croppedCG.height), 1.0)
        let analyzedWidth = max(1, Int(CGFloat(croppedCG.width) * scale))
        let analyzedHeight = max(1, Int(CGFloat(croppedCG.height) * scale))

        // Render into RGBA bitmap
        let bytesPerRow = analyzedWidth * 4
        var pixelData = [UInt8](repeating: 0, count: analyzedHeight * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

        guard let ctx = CGContext(
            data: &pixelData,
            width: analyzedWidth,
            height: analyzedHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return [] }

        ctx.draw(croppedCG, in: CGRect(x: 0, y: 0, width: analyzedWidth, height: analyzedHeight))

        // Find highly saturated pixel clusters (markers are bright colored stickers)
        var saturatedPoints: [(x: Int, y: Int, r: UInt8, g: UInt8, b: UInt8)] = []

        for y in stride(from: 0, to: analyzedHeight, by: 2) {
            for x in stride(from: 0, to: analyzedWidth, by: 2) {
                let offset = y * bytesPerRow + x * 4
                let r = pixelData[offset]
                let g = pixelData[offset + 1]
                let b = pixelData[offset + 2]

                let (h, s, v) = rgbToHSV(r: r, g: g, b: b)

                // Detect non-skin colored regions:
                // - Lower saturation threshold (0.30 vs old 0.55)
                // - Exclude skin-tone hues (orange range 0.03-0.12) unless very vivid
                let isSkinHue = h >= 0.03 && h <= 0.12
                let isLikelySkin = isSkinHue && s < 0.70
                if s > 0.30 && v > 0.30 && !isLikelySkin {
                    saturatedPoints.append((x, y, r, g, b))
                }
            }
        }

        // Cluster saturated points by proximity
        let clusterRadius = max(10, max(analyzedWidth, analyzedHeight) / 18)
        let maxClusterSize = max(200, (analyzedWidth / 2) * (analyzedHeight / 2) / 15)
        var clusters: [[(x: Int, y: Int, r: UInt8, g: UInt8, b: UInt8)]] = []
        var used = Set<Int>()

        for (i, point) in saturatedPoints.enumerated() {
            if used.contains(i) { continue }
            var cluster = [point]
            used.insert(i)

            for (j, other) in saturatedPoints.enumerated() where j > i {
                if used.contains(j) { continue }
                if abs(point.x - other.x) < clusterRadius && abs(point.y - other.y) < clusterRadius {
                    cluster.append(other)
                    used.insert(j)
                }
            }

            // Filter by cluster size: must be a visible marker but not the whole face
            if cluster.count >= 5 && cluster.count < maxClusterSize {
                clusters.append(cluster)
            }
        }

        // Convert clusters to detected markers
        let xScale = clippedRect.width / CGFloat(analyzedWidth)
        let yScale = clippedRect.height / CGFloat(analyzedHeight)

        return clusters.map { cluster in
            let avgX = CGFloat(cluster.map(\.x).reduce(0, +)) / CGFloat(cluster.count)
            let avgY = CGFloat(cluster.map(\.y).reduce(0, +)) / CGFloat(cluster.count)

            // Position in original image (top-left origin)
            let origX = clippedRect.origin.x + avgX * xScale
            let origY = clippedRect.origin.y + avgY * yScale

            // Position relative to face bounding box (top-left origin, 0-1)
            let normalizedX = (origX - faceRect.origin.x) / faceRect.width
            let normalizedY = (origY - faceRect.origin.y) / faceRect.height

            let avgR = UInt8(cluster.map { Int($0.r) }.reduce(0, +) / cluster.count)
            let avgG = UInt8(cluster.map { Int($0.g) }.reduce(0, +) / cluster.count)
            let avgB = UInt8(cluster.map { Int($0.b) }.reduce(0, +) / cluster.count)

            return DetectedMarker(
                normalizedPosition: CGPoint(x: normalizedX, y: normalizedY),
                avgR: avgR, avgG: avgG, avgB: avgB,
                size: cluster.count
            )
        }
    }

    // MARK: - Coordinate Mapping

    /// Map a normalized face-bbox position to ARKit face mesh local coordinates
    private static func mapToFaceMesh(normalizedPosition pos: CGPoint, face: VNFaceObservation) -> SIMD3<Float> {
        // Get nose position in face-bbox normalized coords (bottom-left origin from Vision)
        var noseVisionX: CGFloat = 0.5
        var noseVisionY: CGFloat = 0.35

        if let landmarks = face.landmarks, let noseCrest = landmarks.noseCrest {
            let points = noseCrest.normalizedPoints
            if let tip = points.last {
                noseVisionX = CGFloat(tip.x)
                noseVisionY = CGFloat(tip.y)
            }
        }

        // Convert nose to top-left origin to match our marker positions
        let noseTopLeftX = noseVisionX
        let noseTopLeftY = 1.0 - noseVisionY

        // Map from face-bbox normalized (top-left origin) to ARKit face-local coordinates
        // ARKit face: X right (from face perspective), Y up, origin at nose
        // Face width ~0.12m, height ~0.14m (extended for neck)
        let meshX = Float(pos.x - noseTopLeftX) * 0.12
        let meshY = -Float(pos.y - noseTopLeftY) * 0.14  // negate: image Y down, ARKit Y up

        return SIMD3<Float>(meshX, meshY, 0)
    }

    // MARK: - Helpers

    private static func rgbToHSV(r: UInt8, g: UInt8, b: UInt8) -> (h: Float, s: Float, v: Float) {
        let rf = Float(r) / 255.0
        let gf = Float(g) / 255.0
        let bf = Float(b) / 255.0

        let maxC = max(rf, gf, bf)
        let minC = min(rf, gf, bf)
        let delta = maxC - minC

        let v = maxC
        let s = maxC > 0 ? delta / maxC : 0

        var h: Float = 0
        if delta > 0 {
            if maxC == rf {
                h = (gf - bf) / delta
            } else if maxC == gf {
                h = 2 + (bf - rf) / delta
            } else {
                h = 4 + (rf - gf) / delta
            }
            h /= 6
            if h < 0 { h += 1 }
        }

        return (h, s, v)
    }

    private static func visionOrientation(from imageOrientation: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch imageOrientation {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}
