import Foundation
import ARKit
import SceneKit
import SwiftUI
import Combine
import Vision

/// Manages ARKit face tracking session and spot marking
class FaceTrackingManager: NSObject, ObservableObject {

    // MARK: - Published state
    @Published var isFaceTracked = false
    @Published var markedSpots: [MarkedSpot] = []
    @Published var debugInfo = ""
    @Published var isProcessingImage = false
    @Published var imageProcessingResult = ""

    // MARK: - Scanning state
    @Published var isScanning = false
    @Published var scanProgress: [UUID: AngleCoverage] = [:]
    @Published var detectedMarkerScreenPositions: [CGPoint] = []
    @Published var scanAngleHint = ""

    // MARK: - Back camera state
    @Published var isUsingBackCamera = false
    @Published var backCameraMarkerDetected = false
    @Published var backCameraFaceDetected = false
    @Published var backCameraMarkerScreenPos: CGPoint? = nil

    // MARK: - Skin scan state (back camera, no marker required)
    //
    // Why back camera for skin analysis:
    //   ARFaceTrackingConfiguration (which provides the face mesh and blendshapes) requires
    //   the front-facing TrueDepth camera. The back camera only supports ARWorldTrackingConfiguration,
    //   which gives world pose but NO face mesh. However, the back camera has much higher resolution
    //   (~12MP vs TrueDepth's lower quality), making it better for skin texture analysis.
    //   We use Vision's VNDetectFaceLandmarksRequest for 2D face detection, then SkinSpotDetector
    //   for redness/inflammation analysis across multiple frames.
    @Published var isSkinScanning = false
    @Published var skinScanFrameCount = 0
    @Published var skinScanCandidateCount = 0
    @Published var skinScanHint = ""

    // MARK: - AR state
    let sceneView = ARSCNView()
    private var faceNode: SCNNode?
    private var faceGeometryNode: SCNNode?
    private var currentFaceAnchor: ARFaceAnchor?
    private var dotNodes: [UUID: SCNNode] = [:]
    private var nextSpotIndex = 1

    // MARK: - Scanning internals
    private var liveScanner: LiveMarkerScanner?
    private var positionResolver: MarkerPositionResolver?
    private var currentReferenceImage: UIImage?

    // MARK: - Back camera internals
    private var backCameraImageAnchor: ARImageAnchor?
    private var backCameraFaceObservation: VNFaceObservation?
    private var isRunningVisionFace = false

    // MARK: - Skin scan internals
    private var skinScanAccumulator = SkinScanAccumulator()

    // MARK: - Init

    override init() {
        super.init()
        markedSpots = SpotStore.load()
        nextSpotIndex = (markedSpots.map(\.index).max() ?? 0) + 1
    }

    // MARK: - Session management

    func startSession() {
        guard ARFaceTrackingConfiguration.isSupported else {
            debugInfo = "Face tracking not supported on this device"
            return
        }

        let config = ARFaceTrackingConfiguration()
        config.maximumNumberOfTrackedFaces = 1
        config.isLightEstimationEnabled = true

        sceneView.delegate = self
        sceneView.session.delegate = self
        sceneView.automaticallyUpdatesLighting = true

        sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])

        DispatchQueue.main.async {
            self.isUsingBackCamera = false
            self.isFaceTracked = false
        }
        debugInfo = "Session started, looking for face..."
    }

    func pauseSession() {
        sceneView.session.pause()
    }

    // MARK: - Spot management

    func handleTap(at screenPoint: CGPoint) {
        guard !isUsingBackCamera else { return }
        guard isFaceTracked, let faceAnchor = currentFaceAnchor else {
            debugInfo = "No face tracked — can't place spot"
            return
        }

        let hitResults = sceneView.hitTest(screenPoint, options: [
            .searchMode: SCNHitTestSearchMode.all.rawValue,
            .ignoreHiddenNodes: false
        ])

        guard let faceHit = hitResults.first(where: { $0.node == faceGeometryNode || $0.node.parent == faceNode }) else {
            handleTapFallback(at: screenPoint, faceAnchor: faceAnchor)
            return
        }

        let localPos = faceHit.localCoordinates
        let simdLocal = SIMD3<Float>(localPos.x, localPos.y, localPos.z)

        let vertices = faceAnchor.geometry.vertices
        let (nearestIdx, vertexDist) = findNearestVertex(to: simdLocal, vertices: vertices)
        let confidence = calculateConfidence(vertexDistance: vertexDist, isExtrapolated: false)
        let region = FaceRegion.classify(localPosition: simdLocal, vertexIndex: nearestIdx)

        let spot = MarkedSpot(
            index: nextSpotIndex,
            nearestVertexIndex: nearestIdx,
            localPosition: simdLocal,
            region: region,
            confidence: confidence,
            vertexDistance: vertexDist
        )

        markedSpots.append(spot)
        nextSpotIndex += 1
        SpotStore.save(markedSpots)
        addDotNode(for: spot)

        debugInfo = "Spot \(spot.index) at vertex \(nearestIdx) (\(region.rawValue)) — \(spot.confidenceLabel)"
    }

    private func handleTapFallback(at screenPoint: CGPoint, faceAnchor: ARFaceAnchor) {
        let vertices = faceAnchor.geometry.vertices
        let faceTransform = faceAnchor.transform

        var bestIdx = 0
        var bestDist: Float = .greatestFiniteMagnitude
        var bestScreenPt = CGPoint.zero

        var minScreenX: Float = .greatestFiniteMagnitude
        var maxScreenX: Float = -.greatestFiniteMagnitude
        var minScreenY: Float = .greatestFiniteMagnitude
        var maxScreenY: Float = -.greatestFiniteMagnitude

        for (idx, vertex) in vertices.enumerated() {
            let worldPos4 = faceTransform * SIMD4<Float>(vertex.x, vertex.y, vertex.z, 1.0)
            let worldPos3 = SCNVector3(worldPos4.x, worldPos4.y, worldPos4.z)

            let projected = sceneView.projectPoint(worldPos3)
            let screenPt = CGPoint(x: CGFloat(projected.x), y: CGFloat(projected.y))

            minScreenX = min(minScreenX, projected.x)
            maxScreenX = max(maxScreenX, projected.x)
            minScreenY = min(minScreenY, projected.y)
            maxScreenY = max(maxScreenY, projected.y)

            let dx = Float(screenPt.x - screenPoint.x)
            let dy = Float(screenPt.y - screenPoint.y)
            let dist = dx * dx + dy * dy

            if dist < bestDist {
                bestDist = dist
                bestIdx = idx
                bestScreenPt = screenPt
            }
        }

        let screenBelowOffset = Float(screenPoint.y - bestScreenPt.y)
        if screenBelowOffset > 25 {
            handleNeckTap(
                at: screenPoint,
                anchorVertexIndex: bestIdx,
                anchorScreenPoint: bestScreenPt,
                faceAnchor: faceAnchor,
                faceScreenBounds: (minScreenX, maxScreenX, minScreenY, maxScreenY)
            )
            return
        }

        let faceWidthScreen = maxScreenX - minScreenX
        let pixelsPerMeter = max(faceWidthScreen, 1) / 0.12
        let approxDistance = sqrt(bestDist) / pixelsPerMeter

        let vertexPos = vertices[bestIdx]
        let confidence = calculateConfidence(vertexDistance: approxDistance, isExtrapolated: false)
        let region = FaceRegion.classify(localPosition: vertexPos, vertexIndex: bestIdx)

        let spot = MarkedSpot(
            index: nextSpotIndex,
            nearestVertexIndex: bestIdx,
            localPosition: vertexPos,
            region: region,
            confidence: confidence,
            vertexDistance: approxDistance
        )

        markedSpots.append(spot)
        nextSpotIndex += 1
        SpotStore.save(markedSpots)
        addDotNode(for: spot)

        debugInfo = "Spot \(spot.index) at vertex \(bestIdx) (\(region.rawValue)) — \(spot.confidenceLabel)"
    }

    private func handleNeckTap(
        at screenPoint: CGPoint,
        anchorVertexIndex: Int,
        anchorScreenPoint: CGPoint,
        faceAnchor: ARFaceAnchor,
        faceScreenBounds: (minX: Float, maxX: Float, minY: Float, maxY: Float)
    ) {
        let vertices = faceAnchor.geometry.vertices
        let anchorVertex = vertices[anchorVertexIndex]

        let faceWidthScreen = faceScreenBounds.maxX - faceScreenBounds.minX
        let faceHeightScreen = faceScreenBounds.maxY - faceScreenBounds.minY
        let scaleX = Float(0.12) / max(faceWidthScreen, 1)
        let scaleY = Float(0.13) / max(faceHeightScreen, 1)

        let screenDX = Float(screenPoint.x - anchorScreenPoint.x)
        let screenDY = Float(screenPoint.y - anchorScreenPoint.y)
        let offsetX = screenDX * scaleX
        let offsetY = -screenDY * scaleY
        let offset = SIMD3<Float>(offsetX, offsetY, 0)

        let distFromAnchor = simd_length(offset)
        let confidence = max(0.15, 0.6 - distFromAnchor * 4)

        let spot = MarkedSpot(
            index: nextSpotIndex,
            anchorVertexIndex: anchorVertexIndex,
            anchorPosition: anchorVertex,
            extrapolationOffset: offset,
            confidence: confidence,
            vertexDistance: distFromAnchor
        )

        markedSpots.append(spot)
        nextSpotIndex += 1
        SpotStore.save(markedSpots)
        addDotNode(for: spot)

        debugInfo = "Neck spot \(spot.index) (extrapolated) — \(spot.confidenceLabel) confidence"
    }

    func removeSpot(id: UUID) {
        markedSpots.removeAll { $0.id == id }
        if let node = dotNodes.removeValue(forKey: id) {
            node.removeFromParentNode()
        }
        SpotStore.save(markedSpots)
    }

    func removeLastSpot() {
        guard let last = markedSpots.last else { return }
        removeSpot(id: last.id)
    }

    func clearAllSpots() {
        markedSpots.removeAll()
        dotNodes.values.forEach { $0.removeFromParentNode() }
        dotNodes.removeAll()
        nextSpotIndex = 1
        SpotStore.clear()
    }

    // MARK: - Live scanning (front camera)

    func startScanning(withReferenceImage image: UIImage) {
        guard isFaceTracked else {
            debugInfo = "Need face tracking to scan"
            return
        }

        currentReferenceImage = image

        let scanner = LiveMarkerScanner()
        scanner.setReferenceImage(image)

        guard scanner.hasTemplate else {
            debugInfo = "Could not read marker image"
            return
        }

        liveScanner = scanner
        positionResolver = MarkerPositionResolver()
        isScanning = true
        scanProgress = [:]
        detectedMarkerScreenPositions = []
        scanAngleHint = "Look straight at the camera"
        debugInfo = "Scanning for marker... Move your head slowly"
        imageProcessingResult = ""
    }

    func stopScanning() {
        guard isScanning else { return }

        // If in back camera mode, cancel it first
        if isUsingBackCamera {
            cancelBackCamera()
        }

        isScanning = false

        guard let resolver = positionResolver, let faceAnchor = currentFaceAnchor else {
            liveScanner = nil
            positionResolver = nil
            debugInfo = "Scan ended — no face detected"
            return
        }

        let resolvedSpots = resolver.getResolvedSpots(nextSpotIndex: &nextSpotIndex, faceAnchor: faceAnchor)

        for spot in resolvedSpots {
            markedSpots.append(spot)
            addDotNode(for: spot)
        }

        if !resolvedSpots.isEmpty {
            SpotStore.save(markedSpots)
        }

        let count = resolvedSpots.count
        imageProcessingResult = count > 0 ? "Placed \(count) spot(s) from scan" : "No markers resolved"
        debugInfo = imageProcessingResult

        liveScanner = nil
        positionResolver = nil
        currentReferenceImage = nil
        scanProgress = [:]
        detectedMarkerScreenPositions = []
        scanAngleHint = ""
    }

    private func updateAngleHint(coverage: [UUID: AngleCoverage]) {
        guard let worst = coverage.values.min(by: { $0.fraction < $1.fraction }) else {
            scanAngleHint = "No markers detected — check sticker placement"
            return
        }

        if worst.fraction >= 0.95 {
            scanAngleHint = "Great coverage! Tap Done to place marker."
        } else if worst.hasNeckObservations {
            if worst.pitchRange < 0.25 {
                scanAngleHint = "Tilt your chin up to expose neck, then back down"
            } else if worst.yawRange < 0.30 {
                scanAngleHint = "Slowly turn your head left and right"
            } else {
                scanAngleHint = "Almost there... keep moving slowly"
            }
        } else {
            if worst.yawRange < 0.35 {
                scanAngleHint = "Slowly turn your head left and right"
            } else if worst.observationCount < 12 {
                scanAngleHint = "Keep scanning... (\(worst.observationCount)/12)"
            } else {
                scanAngleHint = "Almost there... keep moving slowly"
            }
        }
    }

    // MARK: - Back camera scanning

    /// Switch from front-camera face tracking to back-camera world tracking with image detection.
    func swapToBackCamera() {
        guard isScanning, let refImage = currentReferenceImage, let cgImage = refImage.cgImage else {
            debugInfo = "Need a reference image to use back camera"
            return
        }

        guard ARWorldTrackingConfiguration.isSupported else {
            debugInfo = "World tracking not supported"
            return
        }

        // Create ARReferenceImage from the user's photo
        let arRefImage = ARReferenceImage(cgImage, orientation: .up, physicalWidth: 0.05) // 5cm default
        arRefImage.name = "UserMarker"

        let config = ARWorldTrackingConfiguration()
        config.detectionImages = [arRefImage]
        config.maximumNumberOfTrackedImages = 1

        // Clear front-camera state
        faceNode = nil
        faceGeometryNode = nil
        currentFaceAnchor = nil
        backCameraImageAnchor = nil
        backCameraFaceObservation = nil
        backCameraMarkerDetected = false
        backCameraFaceDetected = false
        backCameraMarkerScreenPos = nil

        sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])

        isUsingBackCamera = true
        isFaceTracked = false
        debugInfo = "Back camera — point at the marker on your face/neck"
        scanAngleHint = "Ask someone to help, or use a mirror"
    }

    /// Capture the marker position from back camera and switch back to front camera.
    func captureBackCameraResult() {
        guard isUsingBackCamera,
              let imageAnchor = backCameraImageAnchor,
              let faceObs = backCameraFaceObservation else {
            debugInfo = "Need both marker and face detected to capture"
            return
        }

        // Get the marker's position relative to the face bounding box
        guard let faceRelativePos = computeFaceRelativePosition(
            imageAnchor: imageAnchor,
            faceObservation: faceObs
        ) else {
            debugInfo = "Could not compute marker position"
            return
        }

        // Switch back to front camera
        startSession()
        isScanning = false

        // Wait briefly for face tracking to initialize, then place the dot
        let capturedPos = faceRelativePos
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.placeSpotFromBackCameraCapture(faceRelativePosition: capturedPos)
        }

        debugInfo = "Switching to front camera... placing marker"
        imageProcessingResult = ""
    }

    /// Cancel back camera mode and return to front camera scanning.
    func cancelBackCamera() {
        backCameraImageAnchor = nil
        backCameraFaceObservation = nil
        backCameraMarkerDetected = false
        backCameraFaceDetected = false
        backCameraMarkerScreenPos = nil
        isUsingBackCamera = false
        startSession()
        debugInfo = "Returned to front camera"
    }

    // MARK: - Skin scan (back camera, no physical marker required)

    /// Start a multi-frame skin scan using the back camera.
    ///
    /// Unlike the marker-based back camera mode, this requires no physical sticker on the face.
    /// The user points the back camera at the face (via mirror or a second person), and the app
    /// accumulates frames, running redness/inflammation analysis to find potential spots.
    func startSkinScan() {
        guard ARWorldTrackingConfiguration.isSupported else {
            debugInfo = "World tracking not supported on this device"
            return
        }

        let config = ARWorldTrackingConfiguration()
        // No ARReferenceImage needed — Vision handles face detection per-frame

        faceNode = nil
        faceGeometryNode = nil
        currentFaceAnchor = nil
        backCameraImageAnchor = nil
        backCameraFaceObservation = nil
        backCameraMarkerDetected = false
        backCameraFaceDetected = false
        backCameraMarkerScreenPos = nil

        skinScanAccumulator.reset()

        sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])

        isUsingBackCamera = true
        isSkinScanning = true
        isFaceTracked = false
        skinScanFrameCount = 0
        skinScanCandidateCount = 0
        skinScanHint = "Point at the face — move slowly for full coverage"
        debugInfo = "Skin scan active"
    }

    /// Finalize the skin scan: merge multi-frame candidates, place dots, return to front camera.
    func stopSkinScan() {
        let candidates = skinScanAccumulator.mergedCandidates()
        skinScanAccumulator.reset()

        isSkinScanning = false
        isUsingBackCamera = false
        skinScanFrameCount = 0
        skinScanCandidateCount = 0
        skinScanHint = ""

        startSession()

        guard !candidates.isEmpty else {
            imageProcessingResult = "No spots detected — try in better lighting"
            debugInfo = imageProcessingResult
            return
        }

        let captured = candidates
        debugInfo = "Switching to front camera... placing \(captured.count) candidate(s)"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.placeSkinCandidates(captured)
        }
    }

    /// Cancel skin scan and return to front camera without placing anything.
    func cancelSkinScan() {
        skinScanAccumulator.reset()
        isSkinScanning = false
        isUsingBackCamera = false
        skinScanFrameCount = 0
        skinScanCandidateCount = 0
        skinScanHint = ""
        startSession()
        debugInfo = "Skin scan cancelled"
    }

    /// Map merged skin candidates from back-camera face-bbox coords to face mesh positions.
    private func placeSkinCandidates(_ candidates: [MergedSkinCandidate]) {
        guard let faceAnchor = currentFaceAnchor else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                if self.currentFaceAnchor != nil {
                    self.placeSkinCandidates(candidates)
                } else {
                    self.debugInfo = "Face not detected — look at the front camera"
                    self.imageProcessingResult = "Could not place markers — face not found"
                }
            }
            return
        }

        let vertices = faceAnchor.geometry.vertices
        var placed = 0

        for candidate in candidates {
            // Vision face bbox: nose is approximately at normalized (0.50, 0.35) top-left origin.
            // Face mesh local coords: origin at nose, X right ±0.06m, Y up +0.05 / down -0.07m.
            // Back camera is not mirrored (unlike the front camera selfie view).
            let meshX = Float(candidate.normalizedPosition.x - 0.5) * 0.12
            let meshY = -Float(candidate.normalizedPosition.y - 0.35) * 0.16
            let meshPos = SIMD3<Float>(meshX, meshY, 0)

            if meshY < -0.065 {
                let jawlineVerts = findJawlineVertices(vertices: vertices)
                guard let nearest = jawlineVerts.min(by: { abs($0.pos.x - meshX) < abs($1.pos.x - meshX) }) else {
                    continue
                }
                let offset = meshPos - nearest.pos
                let spot = MarkedSpot(
                    index: nextSpotIndex,
                    anchorVertexIndex: nearest.index,
                    anchorPosition: nearest.pos,
                    extrapolationOffset: offset,
                    label: "Skin scan",
                    confidence: candidate.confidence,
                    vertexDistance: simd_length(offset)
                )
                markedSpots.append(spot)
                nextSpotIndex += 1
                addDotNode(for: spot)
                placed += 1
            } else {
                let (nearestIdx, dist) = findNearestVertex(to: meshPos, vertices: vertices)
                let region = FaceRegion.classify(localPosition: meshPos, vertexIndex: nearestIdx)
                let spot = MarkedSpot(
                    index: nextSpotIndex,
                    nearestVertexIndex: nearestIdx,
                    localPosition: vertices[nearestIdx],
                    label: "Skin scan",
                    region: region,
                    confidence: candidate.confidence,
                    vertexDistance: dist
                )
                markedSpots.append(spot)
                nextSpotIndex += 1
                addDotNode(for: spot)
                placed += 1
            }
        }

        if placed > 0 {
            SpotStore.save(markedSpots)
        }

        imageProcessingResult = placed > 0
            ? "Placed \(placed) skin spot(s) from scan"
            : "No spots could be placed — face mesh not ready"
        debugInfo = imageProcessingResult
    }

    /// Compute where the marker is relative to the detected face (normalized 0..1 within face bbox).
    private func computeFaceRelativePosition(
        imageAnchor: ARImageAnchor,
        faceObservation: VNFaceObservation
    ) -> CGPoint? {
        let camera = sceneView.session.currentFrame?.camera
        let viewportSize = sceneView.bounds.size
        guard let camera, viewportSize.width > 0 else { return nil }

        // Project image anchor center to 2D screen coordinates
        let anchorWorldPos = SIMD3<Float>(
            imageAnchor.transform.columns.3.x,
            imageAnchor.transform.columns.3.y,
            imageAnchor.transform.columns.3.z
        )
        let projected = camera.projectPoint(anchorWorldPos, orientation: .portrait, viewportSize: viewportSize)
        let markerScreenX = projected.x
        let markerScreenY = projected.y

        // Vision face bbox is in normalized image coords (bottom-left origin, 0..1)
        // Convert to screen coords (top-left origin)
        let bbox = faceObservation.boundingBox
        let faceLeft = bbox.origin.x * viewportSize.width
        let faceTop = (1 - bbox.origin.y - bbox.height) * viewportSize.height
        let faceWidth = bbox.width * viewportSize.width
        let faceHeight = bbox.height * viewportSize.height

        guard faceWidth > 10, faceHeight > 10 else { return nil }

        // Normalize marker position within face bounding box
        let relX = (markerScreenX - faceLeft) / faceWidth
        let relY = (markerScreenY - faceTop) / faceHeight

        return CGPoint(x: relX, y: relY)
    }

    /// Place a dot on the face mesh using a face-relative position from back camera capture.
    private func placeSpotFromBackCameraCapture(faceRelativePosition relPos: CGPoint) {
        guard let faceAnchor = currentFaceAnchor else {
            // Face not tracked yet — retry after a short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, self.currentFaceAnchor != nil else {
                    self?.debugInfo = "Face not detected — please look at the camera"
                    self?.imageProcessingResult = "Could not place marker — face lost"
                    return
                }
                self.placeSpotFromBackCameraCapture(faceRelativePosition: relPos)
            }
            return
        }

        let vertices = faceAnchor.geometry.vertices

        // Mirror X: back camera sees face's right as image-right,
        // but face mesh local coords have X positive to face's right.
        // Back camera is not mirrored, so relX=0 is face's right side.
        // No X flip needed since face mesh X+ is also face's right.
        let mirroredRelX = relPos.x

        // Map face-relative position to face mesh local coordinates.
        // Face bbox ~covers from forehead to chin. Nose is at roughly (0.5, 0.35).
        // Face mesh: origin at nose, X right (~±0.06m), Y up (~+0.05 to -0.07m)
        let meshX = Float(mirroredRelX - 0.5) * 0.12
        let meshY = -Float(relPos.y - 0.35) * 0.16

        let meshPos = SIMD3<Float>(meshX, meshY, 0)

        // Check if below the face mesh (neck region)
        if meshY < -0.065 {
            let jawlineVerts = findJawlineVertices(vertices: vertices)
            guard let nearest = jawlineVerts.min(by: { abs($0.pos.x - meshX) < abs($1.pos.x - meshX) }) else {
                debugInfo = "Could not find jawline anchor"
                return
            }

            let offset = meshPos - nearest.pos
            let spot = MarkedSpot(
                index: nextSpotIndex,
                anchorVertexIndex: nearest.index,
                anchorPosition: nearest.pos,
                extrapolationOffset: offset,
                label: "Back cam",
                confidence: 0.80,
                vertexDistance: simd_length(offset)
            )
            markedSpots.append(spot)
            nextSpotIndex += 1
            SpotStore.save(markedSpots)
            addDotNode(for: spot)
            imageProcessingResult = "Placed neck spot from back camera"
            debugInfo = imageProcessingResult
        } else {
            let (nearestIdx, dist) = findNearestVertex(to: meshPos, vertices: vertices)
            let region = FaceRegion.classify(localPosition: meshPos, vertexIndex: nearestIdx)
            let confidence = calculateConfidence(vertexDistance: dist, isExtrapolated: false)

            let spot = MarkedSpot(
                index: nextSpotIndex,
                nearestVertexIndex: nearestIdx,
                localPosition: vertices[nearestIdx],
                label: "Back cam",
                region: region,
                confidence: min(0.90, confidence),
                vertexDistance: dist
            )
            markedSpots.append(spot)
            nextSpotIndex += 1
            SpotStore.save(markedSpots)
            addDotNode(for: spot)
            imageProcessingResult = "Placed spot from back camera"
            debugInfo = imageProcessingResult
        }

        // Clean up scanning state
        liveScanner = nil
        positionResolver = nil
        currentReferenceImage = nil
        scanProgress = [:]
        detectedMarkerScreenPositions = []
        scanAngleHint = ""
    }

    // MARK: - Image marker detection (photo fallback)

    func processMarkerImage(_ image: UIImage) {
        guard currentFaceAnchor != nil else {
            debugInfo = "Need active face tracking to place auto-detected spots"
            return
        }

        isProcessingImage = true
        imageProcessingResult = ""

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let detected = ImageMarkerDetector.detectMarkers(in: image)
            DispatchQueue.main.async {
                self?.placeDetectedMarkers(detected)
            }
        }
    }

    private func placeDetectedMarkers(_ detectedPositions: [(position: SIMD3<Float>, confidence: Float)]) {
        defer { isProcessingImage = false }

        guard let faceAnchor = currentFaceAnchor else {
            imageProcessingResult = "Face lost during processing"
            return
        }

        if detectedPositions.isEmpty {
            imageProcessingResult = "No markers detected in image"
            debugInfo = imageProcessingResult
            return
        }

        let vertices = faceAnchor.geometry.vertices
        var placedCount = 0

        for detected in detectedPositions {
            let pos = detected.position
            let markerConfidence = detected.confidence

            if pos.y < -0.065 {
                let jawlineVerts = findJawlineVertices(vertices: vertices)
                guard let nearest = jawlineVerts.min(by: { abs($0.pos.x - pos.x) < abs($1.pos.x - pos.x) }) else { continue }

                let offset = pos - nearest.pos
                let spot = MarkedSpot(
                    index: nextSpotIndex,
                    anchorVertexIndex: nearest.index,
                    anchorPosition: nearest.pos,
                    extrapolationOffset: offset,
                    label: "Auto-detected",
                    confidence: markerConfidence * 0.7,
                    vertexDistance: simd_length(offset)
                )
                markedSpots.append(spot)
                nextSpotIndex += 1
                addDotNode(for: spot)
                placedCount += 1
            } else {
                let (nearestIdx, dist) = findNearestVertex(to: pos, vertices: vertices)
                let baseConfidence = calculateConfidence(vertexDistance: dist, isExtrapolated: false)
                let region = FaceRegion.classify(localPosition: pos, vertexIndex: nearestIdx)

                let spot = MarkedSpot(
                    index: nextSpotIndex,
                    nearestVertexIndex: nearestIdx,
                    localPosition: vertices[nearestIdx],
                    label: "Auto-detected",
                    region: region,
                    confidence: baseConfidence * markerConfidence,
                    vertexDistance: dist
                )
                markedSpots.append(spot)
                nextSpotIndex += 1
                addDotNode(for: spot)
                placedCount += 1
            }
        }

        SpotStore.save(markedSpots)
        imageProcessingResult = "Placed \(placedCount) spot(s) from image"
        debugInfo = imageProcessingResult
    }

    // MARK: - Visual dot rendering

    private func addDotNode(for spot: MarkedSpot) {
        let sphere = SCNSphere(radius: 0.003)
        let spotColor = UIColor(Color(hex: spot.colorHex))
        let material = SCNMaterial()
        material.diffuse.contents = spotColor
        material.emission.contents = spotColor.withAlphaComponent(0.5)
        material.isDoubleSided = true
        sphere.materials = [material]

        let node = SCNNode(geometry: sphere)
        node.name = "spot_\(spot.id.uuidString)"

        if spot.isExtrapolated, let anchorIdx = spot.anchorVertexIndex, let offset = spot.extrapolationOffset {
            if let vertices = currentFaceAnchor?.geometry.vertices, anchorIdx < vertices.count {
                let v = vertices[anchorIdx]
                node.simdPosition = SIMD3<Float>(v.x + offset.x, v.y + offset.y, v.z + offset.z + 0.002)
            } else {
                node.simdPosition = SIMD3<Float>(spot.localX, spot.localY, spot.localZ + 0.002)
            }
        } else {
            node.simdPosition = SIMD3<Float>(spot.localX, spot.localY, spot.localZ + 0.002)
        }

        let ringRadius = CGFloat(spot.marginOfError)
        let ring = SCNTorus(ringRadius: ringRadius, pipeRadius: 0.0004)
        let ringMaterial = SCNMaterial()
        let ringColor = confidenceUIColor(spot.confidence)
        ringMaterial.diffuse.contents = ringColor.withAlphaComponent(0.4)
        ringMaterial.emission.contents = ringColor.withAlphaComponent(0.2)
        ringMaterial.isDoubleSided = true
        ring.materials = [ringMaterial]
        let ringNode = SCNNode(geometry: ring)
        ringNode.eulerAngles.x = .pi / 2
        node.addChildNode(ringNode)

        if spot.isExtrapolated {
            let outerRing = SCNTorus(ringRadius: 0.005, pipeRadius: 0.0003)
            let outerMaterial = SCNMaterial()
            outerMaterial.diffuse.contents = UIColor.systemOrange.withAlphaComponent(0.5)
            outerMaterial.emission.contents = UIColor.systemOrange.withAlphaComponent(0.3)
            outerMaterial.isDoubleSided = true
            outerRing.materials = [outerMaterial]
            let outerNode = SCNNode(geometry: outerRing)
            outerNode.eulerAngles.x = .pi / 2
            node.addChildNode(outerNode)
        }

        faceNode?.addChildNode(node)
        dotNodes[spot.id] = node
    }

    private func rebuildAllDotNodes() {
        dotNodes.values.forEach { $0.removeFromParentNode() }
        dotNodes.removeAll()
        for spot in markedSpots {
            addDotNode(for: spot)
        }
    }

    private func updateDotPositions(with faceAnchor: ARFaceAnchor) {
        let vertices = faceAnchor.geometry.vertices
        for spot in markedSpots {
            guard let node = dotNodes[spot.id] else { continue }

            if spot.isExtrapolated, let anchorIdx = spot.anchorVertexIndex, let offset = spot.extrapolationOffset {
                if anchorIdx < vertices.count {
                    let v = vertices[anchorIdx]

                    var adjustedOffset = offset
                    if abs(adjustedOffset.z) < 0.0001 {
                        let neckRadius: Float = 0.055
                        let lateralDist = abs(adjustedOffset.x + v.x)
                        if lateralDist < neckRadius {
                            adjustedOffset.z = -(neckRadius - sqrt(max(0, neckRadius * neckRadius - lateralDist * lateralDist)))
                        }
                    }

                    node.simdPosition = SIMD3<Float>(
                        v.x + adjustedOffset.x,
                        v.y + adjustedOffset.y,
                        v.z + adjustedOffset.z + 0.002
                    )
                }
            } else if spot.nearestVertexIndex < vertices.count {
                let v = vertices[spot.nearestVertexIndex]
                node.simdPosition = SIMD3<Float>(v.x, v.y, v.z + 0.002)
            }
        }
    }

    // MARK: - Helpers

    private func findNearestVertex(to point: SIMD3<Float>, vertices: [SIMD3<Float>]) -> (index: Int, distance: Float) {
        var bestIdx = 0
        var bestDistSq: Float = .greatestFiniteMagnitude
        for (idx, v) in vertices.enumerated() {
            let dist = simd_distance_squared(point, v)
            if dist < bestDistSq {
                bestDistSq = dist
                bestIdx = idx
            }
        }
        return (bestIdx, sqrt(bestDistSq))
    }

    private func calculateConfidence(vertexDistance: Float, isExtrapolated: Bool) -> Float {
        var confidence = max(0.1, 1.0 - (vertexDistance / 0.008))
        if isExtrapolated {
            confidence *= 0.6
        }
        return min(1.0, max(0.1, confidence))
    }

    private func confidenceUIColor(_ confidence: Float) -> UIColor {
        if confidence >= 0.9 { return .systemGreen }
        if confidence >= 0.7 { return .systemYellow }
        if confidence >= 0.5 { return .systemOrange }
        return .systemRed
    }

    private func findJawlineVertices(vertices: [SIMD3<Float>]) -> [(index: Int, pos: SIMD3<Float>)] {
        let indexed = vertices.enumerated().map { ($0.offset, $0.element) }
        let sorted = indexed.sorted { $0.1.y < $1.1.y }
        let bottomCount = max(10, vertices.count / 20)
        return Array(sorted.prefix(bottomCount)).map { (index: $0.0, pos: $0.1) }
    }
}

// MARK: - ARSCNViewDelegate

extension FaceTrackingManager: ARSCNViewDelegate {

    func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
        guard anchor is ARFaceAnchor else { return nil }

        let device = sceneView.device!
        let faceGeometry = ARSCNFaceGeometry(device: device, fillMesh: true)!

        let material = SCNMaterial()
        material.diffuse.contents = UIColor.white.withAlphaComponent(0.1)
        material.isDoubleSided = true
        material.fillMode = .fill
        faceGeometry.materials = [material]

        let geometryNode = SCNNode(geometry: faceGeometry)
        faceGeometryNode = geometryNode

        let node = SCNNode()
        node.addChildNode(geometryNode)
        faceNode = node

        DispatchQueue.main.async {
            self.rebuildAllDotNodes()
        }

        return node
    }

    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard let faceAnchor = anchor as? ARFaceAnchor else { return }

        currentFaceAnchor = faceAnchor

        if let faceGeometry = faceGeometryNode?.geometry as? ARSCNFaceGeometry {
            faceGeometry.update(from: faceAnchor.geometry)
        }

        updateDotPositions(with: faceAnchor)

        DispatchQueue.main.async {
            self.isFaceTracked = true
        }
    }

    func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
        guard anchor is ARFaceAnchor else { return }
        faceNode = nil
        faceGeometryNode = nil
        currentFaceAnchor = nil
        DispatchQueue.main.async {
            self.isFaceTracked = false
        }
    }
}

// MARK: - ARSessionDelegate

extension FaceTrackingManager: ARSessionDelegate {

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        if isUsingBackCamera {
            handleBackCameraFrame(frame)
        } else if isScanning {
            handleFrontCameraScanFrame(frame)
        }
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        guard isUsingBackCamera else { return }
        for anchor in anchors {
            if let imageAnchor = anchor as? ARImageAnchor,
               imageAnchor.referenceImage.name == "UserMarker" {
                backCameraImageAnchor = imageAnchor
                DispatchQueue.main.async {
                    self.backCameraMarkerDetected = true
                    self.debugInfo = "Marker detected! Now detecting face..."
                }
            }
        }
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard isUsingBackCamera else { return }
        for anchor in anchors {
            if let imageAnchor = anchor as? ARImageAnchor,
               imageAnchor.referenceImage.name == "UserMarker" {
                backCameraImageAnchor = imageAnchor

                DispatchQueue.main.async {
                    self.backCameraMarkerDetected = imageAnchor.isTracked
                }
            }
        }
    }

    // MARK: Back camera frame processing

    private func handleBackCameraFrame(_ frame: ARFrame) {
        // Route to skin scan handler when in that mode
        if isSkinScanning {
            handleSkinScanFrame(frame)
            return
        }

        // Update marker screen position from current anchor
        if let anchor = backCameraImageAnchor {
            let viewportSize = sceneView.bounds.size
            guard viewportSize.width > 0 else { return }
            let pos3D = SIMD3<Float>(
                anchor.transform.columns.3.x,
                anchor.transform.columns.3.y,
                anchor.transform.columns.3.z
            )
            let projected = frame.camera.projectPoint(pos3D, orientation: .portrait, viewportSize: viewportSize)
            DispatchQueue.main.async {
                self.backCameraMarkerScreenPos = CGPoint(x: CGFloat(projected.x), y: CGFloat(projected.y))
            }
        }

        // Run Vision face detection (throttled)
        guard !isRunningVisionFace else { return }
        isRunningVisionFace = true

        let pixelBuffer = frame.capturedImage
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer { self?.isRunningVisionFace = false }

            let faceRequest = VNDetectFaceLandmarksRequest()
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right)

            do {
                try handler.perform([faceRequest])
                if let face = faceRequest.results?.first {
                    self?.backCameraFaceObservation = face
                    DispatchQueue.main.async {
                        self?.backCameraFaceDetected = true
                        if self?.backCameraMarkerDetected == true {
                            self?.debugInfo = "Marker + face detected! Tap Capture."
                        }
                    }
                } else {
                    DispatchQueue.main.async {
                        self?.backCameraFaceDetected = false
                    }
                }
            } catch {
                // Vision error — ignore, will retry next frame
            }
        }
    }

    // MARK: Front camera scan frame processing

    private func handleFrontCameraScanFrame(_ frame: ARFrame) {
        guard let scanner = liveScanner,
              let resolver = positionResolver,
              let faceAnchor = currentFaceAnchor else { return }

        let viewportSize = sceneView.bounds.size
        guard viewportSize.width > 0 && viewportSize.height > 0 else { return }

        let anchorSnapshot = faceAnchor
        let camera = frame.camera

        scanner.processFrame(frame, faceAnchor: faceAnchor) { [weak self] markers in
            guard let self = self, self.isScanning, !self.isUsingBackCamera else { return }

            resolver.addObservation(
                markers: markers,
                faceAnchor: anchorSnapshot,
                camera: camera,
                viewportSize: viewportSize,
                timestamp: frame.timestamp
            )

            DispatchQueue.main.async {
                self.detectedMarkerScreenPositions = markers.map { marker in
                    CGPoint(
                        x: marker.normalizedCenter.x * viewportSize.width,
                        y: marker.normalizedCenter.y * viewportSize.height
                    )
                }

                self.scanProgress = resolver.getAngleCoverage()
                self.updateAngleHint(coverage: self.scanProgress)
            }
        }
    }

    // MARK: Skin scan frame processing

    /// Process one back-camera frame for the skin scan mode.
    /// Detects the face with Vision, then runs SkinSpotDetector on the face region.
    /// Accumulates results across frames; UI polls `skinScanCandidateCount` for progress.
    private func handleSkinScanFrame(_ frame: ARFrame) {
        guard !isRunningVisionFace else { return }
        isRunningVisionFace = true

        let pixelBuffer = frame.capturedImage

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer { self?.isRunningVisionFace = false }
            guard let self, self.isSkinScanning else { return }

            // Detect face in back-camera frame.
            // Back camera in portrait locks to .right orientation for Vision.
            let faceRequest = VNDetectFaceLandmarksRequest()
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right)

            do {
                try handler.perform([faceRequest])
            } catch {
                return
            }

            guard let faceObs = faceRequest.results?.first else {
                DispatchQueue.main.async {
                    self.backCameraFaceDetected = false
                    self.skinScanHint = "No face found — aim camera at the face"
                }
                return
            }

            // Run skin analysis on this frame
            let candidates = SkinSpotDetector.detectSpots(
                in: pixelBuffer,
                faceObservation: faceObs,
                captureOrientation: .right
            )

            let scanFrame = SkinScanFrame(
                candidates: candidates,
                faceBBox: faceObs.boundingBox,
                frameIndex: self.skinScanFrameCount
            )
            self.skinScanAccumulator.add(scanFrame)

            let merged = self.skinScanAccumulator.mergedCandidates()

            DispatchQueue.main.async {
                self.backCameraFaceDetected = true
                self.skinScanFrameCount += 1
                self.skinScanCandidateCount = merged.count

                let fc = self.skinScanFrameCount
                if fc < 8 {
                    self.skinScanHint = "Scanning... (\(fc) frames) — keep the face centered"
                } else if merged.isEmpty {
                    self.skinScanHint = "No anomalies detected yet — try different lighting or angle"
                } else if merged.count == 1 {
                    self.skinScanHint = "1 candidate found — keep scanning for better coverage"
                } else {
                    self.skinScanHint = "\(merged.count) candidate spot(s) — tap Done when ready"
                }
            }
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async {
            self.debugInfo = "Session error: \(error.localizedDescription)"
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        DispatchQueue.main.async {
            self.debugInfo = "Session interrupted"
            self.isFaceTracked = false
        }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        DispatchQueue.main.async {
            self.debugInfo = "Session resumed"
        }
    }
}
