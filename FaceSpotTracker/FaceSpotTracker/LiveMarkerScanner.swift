import Foundation
import ARKit
import UIKit
import Accelerate

/// A marker detected in a single AR frame
struct DetectedMarker2D {
    let normalizedCenter: CGPoint   // 0..1 in portrait orientation
    let radiusNormalized: Float     // approximate radius in normalized coords
    let matchScore: Float           // confidence 0..1
    let pixelCount: Int             // template area in pixels
}

/// Finds a user-provided marker image in live AR frames using template matching.
///
/// Strategy: Convert the reference image to grayscale templates at multiple scales.
/// Each camera frame, perform normalized cross-correlation (NCC) to find the actual
/// image pattern — not just a color. Coarse-to-fine search on initial detection,
/// focused search window once tracking.
class LiveMarkerScanner {

    private let processingQueue = DispatchQueue(label: "com.facespottracker.scanner", qos: .userInitiated)
    private var frameCount = 0
    private let processEveryNthFrame = 2
    private var isProcessing = false

    // Templates at multiple scales (for different distances from camera)
    private struct MatchTemplate {
        let data: [Float]       // mean-subtracted grayscale pixels
        let width: Int
        let height: Int
        let norm: Float         // L2 norm of mean-subtracted data
    }
    private var templates: [MatchTemplate] = []

    // Tracking state: once found, search near last position
    private var lastDetectionCenter: (x: Int, y: Int)? = nil
    private let searchWindowRadius = 60  // pixels in search-resolution coords
    private var framesWithoutDetection = 0
    private let maxFramesBeforeFullSearch = 8

    // Temporal smoothing
    private var recentDetections: [CGPoint] = []
    private let smoothingWindow = 3

    // Search image resolution (Y plane / downsample factor)
    private let searchDownsample = 3

    // NCC threshold — lower = more permissive, higher = stricter
    private let nccThreshold: Float = 0.3

    var hasTemplate: Bool { !templates.isEmpty }

    // MARK: - Reference Image

    /// Convert the reference image into multi-scale grayscale templates for NCC matching.
    func setReferenceImage(_ image: UIImage) {
        guard let cgImage = image.cgImage else { return }

        // Convert to grayscale
        let gray = toGrayscaleFloat(cgImage)
        guard gray.width > 4, gray.height > 4 else { return }

        // Crop center 80% to remove border/background
        let marginX = gray.width / 10
        let marginY = gray.height / 10
        let cropW = gray.width - 2 * marginX
        let cropH = gray.height - 2 * marginY
        let cropped = cropRegion(gray.data, gray.width, marginX, marginY, cropW, cropH)

        // Create templates at multiple sizes.
        // At the search resolution (~640x360), a 2cm sticker at 40-70cm distance
        // is roughly 12-30 pixels. Create templates spanning that range.
        let targetSizes = [12, 18, 26, 34]

        templates = targetSizes.compactMap { size in
            let resized = resizeNearest(cropped, cropW, cropH, size, size)
            guard !resized.isEmpty else { return nil }

            // Mean-subtract and compute norm
            let count = resized.count
            var mean: Float = 0
            vDSP_meanv(resized, 1, &mean, vDSP_Length(count))

            var centered = resized
            var negMean = -mean
            vDSP_vsadd(resized, 1, &negMean, &centered, 1, vDSP_Length(count))

            var normSq: Float = 0
            vDSP_dotpr(centered, 1, centered, 1, &normSq, vDSP_Length(count))
            let norm = sqrt(normSq)
            guard norm > 1e-6 else { return nil }

            return MatchTemplate(data: centered, width: size, height: size, norm: norm)
        }
    }

    // MARK: - Frame Processing

    func processFrame(_ frame: ARFrame, faceAnchor: ARFaceAnchor, completion: @escaping ([DetectedMarker2D]) -> Void) {
        guard hasTemplate else { return }
        frameCount += 1
        guard frameCount % processEveryNthFrame == 0, !isProcessing else { return }

        isProcessing = true
        let pixelBuffer = frame.capturedImage

        processingQueue.async { [weak self] in
            guard let self else { return }
            let markers = self.findMarker(in: pixelBuffer)
            self.isProcessing = false
            completion(markers)
        }
    }

    func reset() {
        frameCount = 0
        isProcessing = false
        templates.removeAll()
        lastDetectionCenter = nil
        framesWithoutDetection = 0
        recentDetections.removeAll()
    }

    // MARK: - Template Matching Detection

    private func findMarker(in pixelBuffer: CVPixelBuffer) -> [DetectedMarker2D] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 1 else { return [] }

        // Use Y (luminance) plane directly — it's already grayscale
        let yPlane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)!
        let yBPR = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let fullW = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let fullH = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let yPtr = yPlane.assumingMemoryBound(to: UInt8.self)

        // Downsample Y plane to search resolution
        let searchW = fullW / searchDownsample
        let searchH = fullH / searchDownsample
        var searchImage = [Float](repeating: 0, count: searchW * searchH)

        for sy in 0..<searchH {
            let srcRow = sy * searchDownsample
            for sx in 0..<searchW {
                let srcCol = sx * searchDownsample
                searchImage[sy * searchW + sx] = Float(yPtr[srcRow * yBPR + srcCol]) / 255.0
            }
        }

        // Search for best match across all template scales
        var bestScore: Float = -1
        var bestX = 0, bestY = 0
        var bestTmpl: MatchTemplate?

        let useFullSearch = lastDetectionCenter == nil || framesWithoutDetection >= maxFramesBeforeFullSearch

        for template in templates {
            let result: (score: Float, x: Int, y: Int)

            if useFullSearch {
                result = nccSearchCoarseToFine(
                    image: searchImage, imageW: searchW, imageH: searchH,
                    template: template
                )
            } else if let center = lastDetectionCenter {
                result = nccSearchWindow(
                    image: searchImage, imageW: searchW, imageH: searchH,
                    template: template,
                    center: center, radius: searchWindowRadius
                )
            } else {
                continue
            }

            if result.score > bestScore {
                bestScore = result.score
                bestX = result.x
                bestY = result.y
                bestTmpl = template
            }
        }

        // Check if match is good enough
        guard bestScore >= nccThreshold, let tmpl = bestTmpl else {
            framesWithoutDetection += 1
            if framesWithoutDetection > maxFramesBeforeFullSearch {
                lastDetectionCenter = nil
                recentDetections.removeAll()
            }
            return []
        }

        // Update tracking state
        let centerX = bestX + tmpl.width / 2
        let centerY = bestY + tmpl.height / 2
        lastDetectionCenter = (centerX, centerY)
        framesWithoutDetection = 0

        // Convert landscape search coords → portrait normalized coords
        // Camera buffer is landscape; for portrait display:
        // portrait normX corresponds to landscape Y, portrait normY corresponds to landscape X
        let normX = Float(centerY) / Float(searchH)
        let normY = Float(centerX) / Float(searchW)

        // Temporal smoothing
        let rawCenter = CGPoint(x: CGFloat(normX), y: CGFloat(normY))
        recentDetections.append(rawCenter)
        if recentDetections.count > smoothingWindow {
            recentDetections.removeFirst(recentDetections.count - smoothingWindow)
        }

        let smoothed: CGPoint
        if recentDetections.count >= 2 {
            let avgX = recentDetections.map(\.x).reduce(0, +) / CGFloat(recentDetections.count)
            let avgY = recentDetections.map(\.y).reduce(0, +) / CGFloat(recentDetections.count)
            smoothed = CGPoint(x: avgX, y: avgY)
        } else {
            smoothed = rawCenter
        }

        let confidence = min(1.0, bestScore / 0.6)
        let radiusNorm = Float(tmpl.width) / Float(max(searchW, searchH)) / 2.0

        return [DetectedMarker2D(
            normalizedCenter: smoothed,
            radiusNormalized: radiusNorm,
            matchScore: confidence,
            pixelCount: tmpl.width * tmpl.height
        )]
    }

    // MARK: - NCC Search

    /// Coarse-to-fine NCC search over the full image.
    /// Step 1: check every 4th pixel. Step 2: refine ±4 around the best coarse match.
    private func nccSearchCoarseToFine(
        image: [Float], imageW: Int, imageH: Int,
        template: MatchTemplate
    ) -> (score: Float, x: Int, y: Int) {
        let tw = template.width
        let th = template.height
        guard imageW > tw, imageH > th else { return (-1, 0, 0) }

        let coarseStep = 4
        var bestScore: Float = -1
        var bestX = 0, bestY = 0

        for y in stride(from: 0, to: imageH - th, by: coarseStep) {
            for x in stride(from: 0, to: imageW - tw, by: coarseStep) {
                let score = computeNCC(image: image, imageW: imageW, px: x, py: y, template: template)
                if score > bestScore {
                    bestScore = score
                    bestX = x
                    bestY = y
                }
            }
        }

        // Fine refinement around best coarse position
        let fineX0 = max(0, bestX - coarseStep)
        let fineX1 = min(imageW - tw - 1, bestX + coarseStep)
        let fineY0 = max(0, bestY - coarseStep)
        let fineY1 = min(imageH - th - 1, bestY + coarseStep)

        for y in fineY0...fineY1 {
            for x in fineX0...fineX1 {
                let score = computeNCC(image: image, imageW: imageW, px: x, py: y, template: template)
                if score > bestScore {
                    bestScore = score
                    bestX = x
                    bestY = y
                }
            }
        }

        return (bestScore, bestX, bestY)
    }

    /// Focused NCC search in a window around a tracked position (fast for subsequent frames).
    private func nccSearchWindow(
        image: [Float], imageW: Int, imageH: Int,
        template: MatchTemplate,
        center: (x: Int, y: Int), radius: Int
    ) -> (score: Float, x: Int, y: Int) {
        let tw = template.width
        let th = template.height
        guard imageW > tw, imageH > th else { return (-1, 0, 0) }

        let x0 = max(0, center.x - radius - tw / 2)
        let x1 = min(imageW - tw - 1, center.x + radius - tw / 2)
        let y0 = max(0, center.y - radius - th / 2)
        let y1 = min(imageH - th - 1, center.y + radius - th / 2)

        guard x1 > x0, y1 > y0 else { return (-1, 0, 0) }

        var bestScore: Float = -1
        var bestX = x0, bestY = y0

        // Step by 2 for speed, then refine
        let step = 2
        for y in stride(from: y0, through: y1, by: step) {
            for x in stride(from: x0, through: x1, by: step) {
                let score = computeNCC(image: image, imageW: imageW, px: x, py: y, template: template)
                if score > bestScore {
                    bestScore = score
                    bestX = x
                    bestY = y
                }
            }
        }

        // Fine refinement ±step
        let fX0 = max(x0, bestX - step)
        let fX1 = min(x1, bestX + step)
        let fY0 = max(y0, bestY - step)
        let fY1 = min(y1, bestY + step)

        for y in fY0...fY1 {
            for x in fX0...fX1 {
                let score = computeNCC(image: image, imageW: imageW, px: x, py: y, template: template)
                if score > bestScore {
                    bestScore = score
                    bestX = x
                    bestY = y
                }
            }
        }

        return (bestScore, bestX, bestY)
    }

    /// Compute normalized cross-correlation at a single position.
    /// Returns -1..1 where 1 = perfect match.
    @inline(__always)
    private func computeNCC(
        image: [Float], imageW: Int,
        px: Int, py: Int,
        template: MatchTemplate
    ) -> Float {
        let tw = template.width
        let th = template.height
        let tData = template.data

        // Compute patch mean
        var patchSum: Float = 0
        for row in 0..<th {
            let imgOffset = (py + row) * imageW + px
            for col in 0..<tw {
                patchSum += image[imgOffset + col]
            }
        }
        let patchMean = patchSum / Float(tw * th)

        // Compute NCC: dot(template_centered, patch_centered) / (template_norm * patch_norm)
        var dotProduct: Float = 0
        var patchNormSq: Float = 0

        for row in 0..<th {
            let imgOffset = (py + row) * imageW + px
            let tmplOffset = row * tw
            for col in 0..<tw {
                let pv = image[imgOffset + col] - patchMean
                let tv = tData[tmplOffset + col]
                dotProduct += tv * pv
                patchNormSq += pv * pv
            }
        }

        let patchNorm = sqrt(patchNormSq)
        guard patchNorm > 1e-6 else { return 0 }

        return dotProduct / (template.norm * patchNorm)
    }

    // MARK: - Image Processing Helpers

    /// Convert a CGImage to a grayscale float array (0..1 range)
    private func toGrayscaleFloat(_ cgImage: CGImage) -> (data: [Float], width: Int, height: Int) {
        let w = cgImage.width
        let h = cgImage.height
        let bytesPerRow = w * 4
        var pixelData = [UInt8](repeating: 0, count: h * bytesPerRow)
        let cs = CGColorSpaceCreateDeviceRGB()
        let bi = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

        guard let ctx = CGContext(
            data: &pixelData, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: cs, bitmapInfo: bi
        ) else {
            return ([], 0, 0)
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        var gray = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let off = i * 4
            gray[i] = (0.299 * Float(pixelData[off]) +
                        0.587 * Float(pixelData[off + 1]) +
                        0.114 * Float(pixelData[off + 2])) / 255.0
        }

        return (gray, w, h)
    }

    /// Crop a rectangular region from a grayscale image
    private func cropRegion(_ data: [Float], _ srcW: Int,
                            _ cx: Int, _ cy: Int, _ cw: Int, _ ch: Int) -> [Float] {
        var cropped = [Float](repeating: 0, count: cw * ch)
        for row in 0..<ch {
            let srcOffset = (cy + row) * srcW + cx
            let dstOffset = row * cw
            cropped.replaceSubrange(dstOffset..<(dstOffset + cw),
                                    with: data[srcOffset..<(srcOffset + cw)])
        }
        return cropped
    }

    /// Nearest-neighbor resize of a grayscale image
    private func resizeNearest(_ data: [Float], _ srcW: Int, _ srcH: Int,
                                _ dstW: Int, _ dstH: Int) -> [Float] {
        guard srcW > 0, srcH > 0, dstW > 0, dstH > 0 else { return [] }
        var result = [Float](repeating: 0, count: dstW * dstH)
        let xScale = Float(srcW) / Float(dstW)
        let yScale = Float(srcH) / Float(dstH)

        for dy in 0..<dstH {
            let sy = min(Int(Float(dy) * yScale), srcH - 1)
            for dx in 0..<dstW {
                let sx = min(Int(Float(dx) * xScale), srcW - 1)
                result[dy * dstW + dx] = data[sy * srcW + sx]
            }
        }

        return result
    }
}
