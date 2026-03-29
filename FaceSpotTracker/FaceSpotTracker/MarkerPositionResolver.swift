import Foundation
import ARKit
import simd

/// A single observation of a marker from one AR frame
struct MarkerObservation {
    let marker2D: CGPoint              // normalized image coords (portrait)
    let nearestVertexIndex: Int        // nearest face mesh vertex projected to 2D
    let distanceToVertex2D: Float      // 2D distance in normalized coords
    let headYaw: Float                 // radians
    let headPitch: Float               // radians
    let headRoll: Float                // radians
    let isBelowMesh: Bool              // true if marker is below projected face boundary
    let nearestJawlineIndex: Int?      // for neck markers: nearest jawline vertex
    let faceLocalOffset: SIMD3<Float>? // for neck markers: 2D-derived offset (fallback)
    let timestamp: TimeInterval
    // Ray in face-local space for triangulation (most accurate for neck)
    let faceLocalRayOrigin: SIMD3<Float>?
    let faceLocalRayDirection: SIMD3<Float>?
}

/// A marker being tracked across multiple frames
struct TrackedMarker {
    let id: UUID
    var lastPosition: CGPoint
    var observations: [MarkerObservation]

    var yawRange: Float {
        guard !observations.isEmpty else { return 0 }
        let yaws = observations.map(\.headYaw)
        return (yaws.max() ?? 0) - (yaws.min() ?? 0)
    }

    var pitchRange: Float {
        guard !observations.isEmpty else { return 0 }
        let pitches = observations.map(\.headPitch)
        return (pitches.max() ?? 0) - (pitches.min() ?? 0)
    }
}

/// Per-marker scanning progress exposed to UI
struct AngleCoverage {
    let yawRange: Float
    let pitchRange: Float
    let observationCount: Int
    let hasNeckObservations: Bool

    /// 0..1 fraction of resolution completeness
    var fraction: Float {
        if hasNeckObservations {
            // Neck: pitch matters more (tilt chin to expose neck), lower yaw requirement
            let yawFrac = min(1.0, yawRange / 0.35)
            let pitchFrac = min(1.0, pitchRange / 0.30)
            let obsFrac = min(1.0, Float(observationCount) / 12.0)
            return yawFrac * 0.35 + obsFrac * 0.30 + pitchFrac * 0.35
        } else {
            let yawFrac = min(1.0, yawRange / 0.35)
            let pitchFrac = min(1.0, pitchRange / 0.22)
            let obsFrac = min(1.0, Float(observationCount) / 12.0)
            return yawFrac * 0.5 + obsFrac * 0.3 + pitchFrac * 0.2
        }
    }
}

/// Accumulates per-frame 2D marker observations paired with head pose and face mesh state,
/// then resolves final 3D positions when sufficient angular diversity is achieved.
///
/// For on-mesh markers: uses vertex voting with outlier rejection.
/// For neck markers: uses ray-based triangulation across multiple viewpoints
/// for head-pose-invariant 3D position estimation.
class MarkerPositionResolver {

    private(set) var trackedMarkers: [TrackedMarker] = []

    // Spatial matching threshold (normalized image distance)
    private let maxSpatialDistance: Float = 0.18

    // Resolution thresholds
    private let requiredYawRange: Float = 0.35   // ~20 degrees
    private let minObservations = 12
    private let minObservationsPartial = 5

    // Jawline vertex Y threshold in face-local coords
    private let jawlineYThreshold: Float = -0.045

    // MARK: - Public API

    /// Feed a set of detected 2D markers from one frame into the resolver.
    func addObservation(
        markers: [DetectedMarker2D],
        faceAnchor: ARFaceAnchor,
        camera: ARCamera,
        viewportSize: CGSize,
        timestamp: TimeInterval
    ) {
        let projectedVertices = projectVertices(
            faceAnchor: faceAnchor,
            camera: camera,
            viewportSize: viewportSize
        )

        let (yaw, pitch, roll) = extractEulerAngles(from: faceAnchor.transform)
        let vertices = faceAnchor.geometry.vertices

        for marker in markers {
            let markerPt = marker.normalizedCenter
            let markerX = Float(markerPt.x)
            let markerY = Float(markerPt.y)

            // Find nearest vertex in 2D
            var bestIdx = 0
            var bestDist: Float = .greatestFiniteMagnitude
            for (idx, projPt) in projectedVertices.enumerated() {
                let dx = Float(markerPt.x - projPt.x)
                let dy = Float(markerPt.y - projPt.y)
                let dist = dx * dx + dy * dy
                if dist < bestDist {
                    bestDist = dist
                    bestIdx = idx
                }
            }
            let dist2D = sqrt(bestDist)

            // Improved below-mesh detection: use local face boundary near marker's X
            let isBelowMesh = checkBelowMesh(
                markerX: markerX,
                markerY: markerY,
                projectedVertices: projectedVertices
            )

            var nearestJawIdx: Int? = nil
            var faceLocalOffset: SIMD3<Float>? = nil

            if isBelowMesh {
                let jawlineResult = findNearestJawlineVertex(
                    to: markerPt,
                    vertices: vertices,
                    projectedVertices: projectedVertices,
                    faceAnchor: faceAnchor
                )
                nearestJawIdx = jawlineResult.index
                faceLocalOffset = jawlineResult.offset
            }

            // Compute face-local ray for triangulation
            let ray = computeFaceLocalRay(
                for: markerPt,
                faceAnchor: faceAnchor,
                camera: camera,
                viewportSize: viewportSize
            )

            let observation = MarkerObservation(
                marker2D: markerPt,
                nearestVertexIndex: bestIdx,
                distanceToVertex2D: dist2D,
                headYaw: yaw,
                headPitch: pitch,
                headRoll: roll,
                isBelowMesh: isBelowMesh,
                nearestJawlineIndex: nearestJawIdx,
                faceLocalOffset: faceLocalOffset,
                timestamp: timestamp,
                faceLocalRayOrigin: ray?.origin,
                faceLocalRayDirection: ray?.direction
            )

            // Match to existing tracked marker or create new
            if let trackIdx = matchMarkerToTrack(marker) {
                trackedMarkers[trackIdx].observations.append(observation)
                trackedMarkers[trackIdx].lastPosition = markerPt
            } else {
                let tracked = TrackedMarker(
                    id: UUID(),
                    lastPosition: markerPt,
                    observations: [observation]
                )
                trackedMarkers.append(tracked)
            }
        }
    }

    /// Get current angle coverage for each tracked marker
    func getAngleCoverage() -> [UUID: AngleCoverage] {
        var result: [UUID: AngleCoverage] = [:]
        for tracked in trackedMarkers {
            let neckCount = tracked.observations.filter(\.isBelowMesh).count
            result[tracked.id] = AngleCoverage(
                yawRange: tracked.yawRange,
                pitchRange: tracked.pitchRange,
                observationCount: tracked.observations.count,
                hasNeckObservations: neckCount > tracked.observations.count / 2
            )
        }
        return result
    }

    /// Resolve all markers that have enough observations into MarkedSpots.
    /// Consumes the tracked markers (removes resolved ones).
    func getResolvedSpots(nextSpotIndex: inout Int, faceAnchor: ARFaceAnchor) -> [MarkedSpot] {
        var resolvedSpots: [MarkedSpot] = []
        var remainingMarkers: [TrackedMarker] = []

        let vertices = faceAnchor.geometry.vertices

        for tracked in trackedMarkers {
            let isResolved = tracked.yawRange >= requiredYawRange &&
                             tracked.observations.count >= minObservations

            if isResolved {
                let spot = resolveMarker(tracked, vertices: vertices, nextIndex: &nextSpotIndex)
                resolvedSpots.append(spot)
            } else if tracked.observations.count >= minObservationsPartial {
                let spot = resolveMarker(tracked, vertices: vertices, nextIndex: &nextSpotIndex)
                resolvedSpots.append(spot)
            } else {
                remainingMarkers.append(tracked)
            }
        }

        trackedMarkers = remainingMarkers
        return resolvedSpots
    }

    func reset() {
        trackedMarkers.removeAll()
    }

    // MARK: - Below-mesh Detection

    /// Check if a marker position is below the face mesh boundary.
    /// Uses the local face boundary near the marker's X position for accuracy,
    /// preventing markers on the side of the face from being misclassified.
    private func checkBelowMesh(
        markerX: Float,
        markerY: Float,
        projectedVertices: [CGPoint]
    ) -> Bool {
        // Find the bottom boundary of the face near the marker's X position
        let xTolerance: Float = 0.08
        var localMaxY: Float = 0
        var foundNearby = false

        for projPt in projectedVertices {
            let vx = Float(projPt.x)
            let vy = Float(projPt.y)
            if abs(vx - markerX) < xTolerance {
                if vy > localMaxY {
                    localMaxY = vy
                    foundNearby = true
                }
            }
        }

        if !foundNearby {
            // Marker is beyond the face laterally — check if it's at jawline level
            let globalMaxY = projectedVertices.map { Float($0.y) }.max() ?? 1.0
            return markerY > globalMaxY - 0.02
        }

        return markerY > localMaxY + 0.015
    }

    // MARK: - Ray Computation

    /// Compute a ray from the camera through the marker's 2D position, transformed
    /// into the face anchor's local coordinate space. This gives a head-pose-invariant
    /// ray that can be triangulated across multiple viewpoints.
    private func computeFaceLocalRay(
        for markerPt: CGPoint,
        faceAnchor: ARFaceAnchor,
        camera: ARCamera,
        viewportSize: CGSize
    ) -> (origin: SIMD3<Float>, direction: SIMD3<Float>)? {
        let viewMatrix = camera.viewMatrix(for: .portrait)
        let projMatrix = camera.projectionMatrix(
            for: .portrait,
            viewportSize: viewportSize,
            zNear: 0.001,
            zFar: 1000
        )

        // Camera position in world space (4th column of inverse view matrix)
        let viewInv = viewMatrix.inverse
        let camWorldPos = SIMD3<Float>(viewInv.columns.3.x, viewInv.columns.3.y, viewInv.columns.3.z)

        // Marker normalized coords → NDC
        let ndcX = Float(markerPt.x) * 2.0 - 1.0
        let ndcY = 1.0 - Float(markerPt.y) * 2.0

        // Unproject NDC to world space
        let combinedInv = (projMatrix * viewMatrix).inverse
        let worldPt4 = combinedInv * SIMD4<Float>(ndcX, ndcY, 0.0, 1.0)
        guard abs(worldPt4.w) > 1e-10 else { return nil }
        let worldPt = SIMD3<Float>(worldPt4.x, worldPt4.y, worldPt4.z) / worldPt4.w

        let rayDirWorld = simd_normalize(worldPt - camWorldPos)

        // Transform ray into face-local space
        let faceInv = faceAnchor.transform.inverse
        let localOrigin4 = faceInv * SIMD4<Float>(camWorldPos.x, camWorldPos.y, camWorldPos.z, 1.0)
        let localOrigin = SIMD3<Float>(localOrigin4.x, localOrigin4.y, localOrigin4.z)

        let localDir4 = faceInv * SIMD4<Float>(rayDirWorld.x, rayDirWorld.y, rayDirWorld.z, 0.0)
        let localDir = simd_normalize(SIMD3<Float>(localDir4.x, localDir4.y, localDir4.z))

        return (localOrigin, localDir)
    }

    // MARK: - Vertex Projection

    /// Project all face mesh vertices to normalized 2D image coordinates (portrait)
    private func projectVertices(
        faceAnchor: ARFaceAnchor,
        camera: ARCamera,
        viewportSize: CGSize
    ) -> [CGPoint] {
        let vertices = faceAnchor.geometry.vertices
        let faceTransform = faceAnchor.transform

        let viewMatrix = camera.viewMatrix(for: .portrait)
        let projMatrix = camera.projectionMatrix(for: .portrait,
                                                  viewportSize: viewportSize,
                                                  zNear: 0.001, zFar: 1000)
        let combined = projMatrix * viewMatrix

        return vertices.map { vertex in
            let world4 = faceTransform * SIMD4<Float>(vertex.x, vertex.y, vertex.z, 1.0)
            let clip = combined * world4
            let ndcX = clip.x / clip.w
            let ndcY = clip.y / clip.w
            let normX = CGFloat((ndcX + 1.0) * 0.5)
            let normY = CGFloat((1.0 - ndcY) * 0.5)
            return CGPoint(x: normX, y: normY)
        }
    }

    // MARK: - Head Pose Extraction

    /// Extract Euler angles (yaw, pitch, roll) from a 4x4 transform matrix
    private func extractEulerAngles(from transform: simd_float4x4) -> (yaw: Float, pitch: Float, roll: Float) {
        let r = transform

        // Standard decomposition: R = Ry * Rx * Rz
        let pitch = asin(-r[2][1])

        let yaw: Float
        let roll: Float
        if abs(r[2][1]) < 0.999 {
            yaw = atan2(r[2][0], r[2][2])
            roll = atan2(r[0][1], r[1][1])
        } else {
            yaw = atan2(-r[0][2], r[0][0])
            roll = 0
        }

        return (yaw, pitch, roll)
    }

    // MARK: - Marker Matching

    /// Match a detected marker to an existing tracked marker by spatial proximity.
    private func matchMarkerToTrack(_ marker: DetectedMarker2D) -> Int? {
        var bestIdx: Int? = nil
        var bestDist: Float = .greatestFiniteMagnitude

        for (idx, tracked) in trackedMarkers.enumerated() {
            let dx = Float(marker.normalizedCenter.x - tracked.lastPosition.x)
            let dy = Float(marker.normalizedCenter.y - tracked.lastPosition.y)
            let spatialDist = sqrt(dx * dx + dy * dy)

            if spatialDist < maxSpatialDistance && spatialDist < bestDist {
                bestDist = spatialDist
                bestIdx = idx
            }
        }

        return bestIdx
    }

    // MARK: - Neck Marker Helpers

    /// Find the nearest jawline vertex to a 2D marker position and compute face-local offset
    private func findNearestJawlineVertex(
        to markerPt: CGPoint,
        vertices: [SIMD3<Float>],
        projectedVertices: [CGPoint],
        faceAnchor: ARFaceAnchor
    ) -> (index: Int, offset: SIMD3<Float>) {
        var bestIdx = 0
        var bestDist: Float = .greatestFiniteMagnitude

        for (idx, vertex) in vertices.enumerated() {
            guard vertex.y < jawlineYThreshold else { continue }

            let projPt = projectedVertices[idx]
            let dx = Float(markerPt.x - projPt.x)
            let dy = Float(markerPt.y - projPt.y)
            let dist = dx * dx + dy * dy
            if dist < bestDist {
                bestDist = dist
                bestIdx = idx
            }
        }

        // Compute offset in face-local coordinates using 2D-to-3D scale
        let projPt = projectedVertices[bestIdx]
        let dx2D = Float(markerPt.x - projPt.x)
        let dy2D = Float(markerPt.y - projPt.y)

        let faceXCoords = projectedVertices.map { Float($0.x) }
        let faceWidth2D = (faceXCoords.max() ?? 1) - (faceXCoords.min() ?? 0)
        let scale = Float(0.12) / max(faceWidth2D, 0.01)

        let offsetX = dx2D * scale
        let offsetY = -dy2D * scale

        // Cylindrical neck Z approximation
        let neckRadius: Float = 0.055
        let lateralDist = abs(offsetX + vertices[bestIdx].x)
        let offsetZ: Float
        if lateralDist < neckRadius {
            offsetZ = -(neckRadius - sqrt(max(0, neckRadius * neckRadius - lateralDist * lateralDist)))
        } else {
            offsetZ = 0
        }

        return (bestIdx, SIMD3<Float>(offsetX, offsetY, offsetZ))
    }

    // MARK: - Ray Triangulation

    /// Find the 3D point in face-local space that best fits all observation rays.
    /// Uses least-squares closest-point-to-multiple-rays with RANSAC outlier rejection.
    private func triangulateRays(_ observations: [MarkerObservation]) -> SIMD3<Float>? {
        let rays: [(origin: SIMD3<Float>, direction: SIMD3<Float>)] = observations.compactMap { obs in
            guard let o = obs.faceLocalRayOrigin, let d = obs.faceLocalRayDirection else { return nil }
            return (o, d)
        }

        guard rays.count >= 3 else { return nil }

        // First pass: triangulate with all rays
        guard let initial = leastSquaresRayIntersection(rays) else { return nil }

        // Compute per-ray distance to the triangulated point
        var distances: [(index: Int, dist: Float)] = []
        for (i, ray) in rays.enumerated() {
            let toPoint = initial - ray.origin
            let proj = simd_dot(toPoint, ray.direction)
            let closest = ray.origin + ray.direction * proj
            let dist = simd_distance(initial, closest)
            distances.append((i, dist))
        }

        // Reject outliers: remove rays with distance > 2.5× median
        distances.sort { $0.dist < $1.dist }
        let medianDist = distances[distances.count / 2].dist
        let threshold = max(medianDist * 2.5, 0.005) // at least 5mm tolerance

        let inlierRays = distances
            .filter { $0.dist <= threshold }
            .map { rays[$0.index] }

        guard inlierRays.count >= 3 else { return initial }

        // Second pass: triangulate with inliers only
        return leastSquaresRayIntersection(inlierRays) ?? initial
    }

    /// Least-squares intersection of multiple rays.
    /// Finds the point p that minimizes sum of squared distances to each ray.
    ///
    /// For ray i with origin o_i and direction d_i:
    ///   S_i = I - d_i * d_i^T  (projection matrix perpendicular to ray)
    ///   Solution: p = (sum S_i)^-1 * sum(S_i * o_i)
    private func leastSquaresRayIntersection(
        _ rays: [(origin: SIMD3<Float>, direction: SIMD3<Float>)]
    ) -> SIMD3<Float>? {
        var col0 = SIMD3<Float>.zero
        var col1 = SIMD3<Float>.zero
        var col2 = SIMD3<Float>.zero
        var bVec = SIMD3<Float>.zero

        for ray in rays {
            let d = ray.direction
            let o = ray.origin

            // S = I - d*d^T, columns of S:
            let s0 = SIMD3<Float>(1 - d.x * d.x, -d.y * d.x, -d.z * d.x)
            let s1 = SIMD3<Float>(-d.x * d.y, 1 - d.y * d.y, -d.z * d.y)
            let s2 = SIMD3<Float>(-d.x * d.z, -d.y * d.z, 1 - d.z * d.z)

            col0 += s0
            col1 += s1
            col2 += s2

            let S = simd_float3x3(s0, s1, s2)
            bVec += S * o
        }

        let A = simd_float3x3(col0, col1, col2)
        guard abs(A.determinant) > 1e-8 else { return nil }
        return A.inverse * bVec
    }

    // MARK: - Resolution

    private func resolveMarker(_ tracked: TrackedMarker, vertices: [SIMD3<Float>], nextIndex: inout Int) -> MarkedSpot {
        let onMeshObs = tracked.observations.filter { !$0.isBelowMesh }
        let neckObs = tracked.observations.filter { $0.isBelowMesh }

        if onMeshObs.count >= neckObs.count {
            return resolveOnMeshMarker(tracked, vertices: vertices, observations: onMeshObs, nextIndex: &nextIndex)
        } else {
            return resolveNeckMarker(tracked, vertices: vertices, observations: neckObs, nextIndex: &nextIndex)
        }
    }

    /// Resolve an on-mesh marker using vertex voting with outlier rejection
    private func resolveOnMeshMarker(
        _ tracked: TrackedMarker,
        vertices: [SIMD3<Float>],
        observations: [MarkerObservation],
        nextIndex: inout Int
    ) -> MarkedSpot {
        // Vote on vertex index, weighted by inverse 2D distance
        var vertexVotes: [Int: Float] = [:]
        for obs in observations {
            let weight = 1.0 / max(obs.distanceToVertex2D, 0.001)
            vertexVotes[obs.nearestVertexIndex, default: 0] += weight
        }

        let winnerIndex = vertexVotes.max(by: { $0.value < $1.value })?.key ?? 0
        let totalVotes = vertexVotes.values.reduce(0, +)
        let winnerVotes = vertexVotes[winnerIndex] ?? 0
        let voteConcentration = winnerVotes / max(totalVotes, 0.001)

        // Outlier rejection: measure agreement ratio
        let agreeingObs = observations.filter { $0.nearestVertexIndex == winnerIndex }
        let agreementRatio = Float(agreeingObs.count) / Float(max(observations.count, 1))

        // Confidence from vote concentration, angle diversity, and agreement
        let angleBonus = min(0.2, tracked.yawRange / 2.0)
        let agreementBonus = agreementRatio * 0.15
        let confidence = min(0.98, voteConcentration * 0.55 + angleBonus + agreementBonus + 0.1)

        let vertexPos = winnerIndex < vertices.count ? vertices[winnerIndex] : SIMD3<Float>.zero
        let region = FaceRegion.classify(localPosition: vertexPos, vertexIndex: winnerIndex)

        let avgVertexDist = observations.map(\.distanceToVertex2D).reduce(0, +) / Float(max(observations.count, 1))

        let spot = MarkedSpot(
            index: nextIndex,
            nearestVertexIndex: winnerIndex,
            localPosition: vertexPos,
            label: "Scanned",
            region: region,
            confidence: confidence,
            vertexDistance: avgVertexDist * 0.12
        )

        nextIndex += 1
        return spot
    }

    /// Resolve a neck marker — tries ray triangulation first, falls back to offset averaging
    private func resolveNeckMarker(
        _ tracked: TrackedMarker,
        vertices: [SIMD3<Float>],
        observations: [MarkerObservation],
        nextIndex: inout Int
    ) -> MarkedSpot {
        // Try ray-based triangulation (most accurate, head-pose-invariant)
        if let triangulated = triangulateRays(observations) {
            return buildNeckSpotFromTriangulation(
                position: triangulated,
                tracked: tracked,
                vertices: vertices,
                observations: observations,
                nextIndex: &nextIndex
            )
        }

        // Fallback: offset averaging with outlier rejection
        return resolveNeckMarkerByOffset(
            tracked: tracked,
            vertices: vertices,
            observations: observations,
            nextIndex: &nextIndex
        )
    }

    /// Build a neck MarkedSpot from a triangulated 3D position in face-local space
    private func buildNeckSpotFromTriangulation(
        position: SIMD3<Float>,
        tracked: TrackedMarker,
        vertices: [SIMD3<Float>],
        observations: [MarkerObservation],
        nextIndex: inout Int
    ) -> MarkedSpot {
        // Find the nearest jawline vertex to use as anchor
        var bestAnchorIdx = 0
        var bestDist: Float = .greatestFiniteMagnitude
        for (idx, v) in vertices.enumerated() {
            guard v.y < jawlineYThreshold else { continue }
            let dist = simd_distance(position, v)
            if dist < bestDist {
                bestDist = dist
                bestAnchorIdx = idx
            }
        }

        let anchorPos = bestAnchorIdx < vertices.count ? vertices[bestAnchorIdx] : SIMD3<Float>.zero
        let offset = position - anchorPos

        // Compute confidence from ray convergence quality
        let rays: [(origin: SIMD3<Float>, direction: SIMD3<Float>)] = observations.compactMap { obs in
            guard let o = obs.faceLocalRayOrigin, let d = obs.faceLocalRayDirection else { return nil }
            return (o, d)
        }

        var convergenceScore: Float = 0.7
        if !rays.isEmpty {
            var totalDist: Float = 0
            for ray in rays {
                let toPoint = position - ray.origin
                let proj = simd_dot(toPoint, ray.direction)
                let closest = ray.origin + ray.direction * proj
                totalDist += simd_distance(position, closest)
            }
            let avgDist = totalDist / Float(rays.count)
            // Good convergence: < 3mm average reprojection error
            convergenceScore = max(0.3, min(1.0, 1.0 - avgDist / 0.006))
        }

        let obsScore = min(1.0, Float(observations.count) / 15.0)
        let angleScore = min(1.0, tracked.yawRange / 0.5)

        // Triangulated neck spots can reach higher confidence than offset-averaged ones
        let confidence = min(0.92, convergenceScore * 0.45 + angleScore * 0.30 + obsScore * 0.25)

        let spot = MarkedSpot(
            index: nextIndex,
            anchorVertexIndex: bestAnchorIdx,
            anchorPosition: anchorPos,
            extrapolationOffset: offset,
            label: "Scanned",
            confidence: confidence,
            vertexDistance: simd_length(offset)
        )

        nextIndex += 1
        return spot
    }

    /// Fallback neck resolution using offset averaging with outlier rejection
    private func resolveNeckMarkerByOffset(
        tracked: TrackedMarker,
        vertices: [SIMD3<Float>],
        observations: [MarkerObservation],
        nextIndex: inout Int
    ) -> MarkedSpot {
        // Vote on jawline anchor vertex
        var jawVotes: [Int: Int] = [:]
        for obs in observations {
            if let jawIdx = obs.nearestJawlineIndex {
                jawVotes[jawIdx, default: 0] += 1
            }
        }
        let anchorIdx = jawVotes.max(by: { $0.value < $1.value })?.key ?? 0

        // Collect offsets with yaw info for the winning anchor
        var offsetData: [(offset: SIMD3<Float>, yaw: Float)] = []
        for obs in observations {
            if let jawIdx = obs.nearestJawlineIndex, jawIdx == anchorIdx,
               let offset = obs.faceLocalOffset {
                offsetData.append((offset, obs.headYaw))
            }
        }

        guard !offsetData.isEmpty else {
            let anchorPos = anchorIdx < vertices.count ? vertices[anchorIdx] : SIMD3<Float>.zero
            let fallbackOffset = SIMD3<Float>(0, -0.03, 0)
            let spot = MarkedSpot(
                index: nextIndex,
                anchorVertexIndex: anchorIdx,
                anchorPosition: anchorPos,
                extrapolationOffset: fallbackOffset,
                label: "Scanned",
                confidence: 0.25,
                vertexDistance: simd_length(fallbackOffset)
            )
            nextIndex += 1
            return spot
        }

        // Outlier rejection: compute median, reject far outliers
        let allOffsets = offsetData.map(\.offset)
        let median = medianSIMD3(allOffsets)
        let distances = allOffsets.map { simd_distance($0, median) }
        let sortedDists = distances.sorted()
        let medDist = sortedDists[sortedDists.count / 2]
        let outlierThreshold = max(medDist * 2.5, 0.005)

        let filtered = zip(offsetData, distances)
            .filter { $0.1 <= outlierThreshold }
            .map { $0.0 }

        let clean = filtered.isEmpty ? offsetData : filtered

        // Yaw-weighted average: extreme angles give better depth estimates
        var sumOffset = SIMD3<Float>.zero
        var totalWeight: Float = 0
        for item in clean {
            let w = 1.0 + abs(item.yaw) * 2.0
            sumOffset += item.offset * w
            totalWeight += w
        }
        let avgOffset = totalWeight > 0 ? sumOffset / totalWeight : median

        // Confidence
        let obsScore = min(1.0, Float(observations.count) / 20.0)
        let angleScore = min(1.0, tracked.yawRange / 0.5)

        var varianceScore: Float = 1.0
        if clean.count > 2 {
            let variance = clean.map { simd_distance($0.offset, avgOffset) }.reduce(0, +) / Float(clean.count)
            varianceScore = max(0.3, 1.0 - variance * 20.0)
        }

        let confidence = min(0.85, obsScore * 0.3 + angleScore * 0.4 + varianceScore * 0.3)

        let anchorPos = anchorIdx < vertices.count ? vertices[anchorIdx] : SIMD3<Float>.zero

        let spot = MarkedSpot(
            index: nextIndex,
            anchorVertexIndex: anchorIdx,
            anchorPosition: anchorPos,
            extrapolationOffset: avgOffset,
            label: "Scanned",
            confidence: confidence,
            vertexDistance: simd_length(avgOffset)
        )

        nextIndex += 1
        return spot
    }

    /// Compute component-wise median of SIMD3 vectors
    private func medianSIMD3(_ vectors: [SIMD3<Float>]) -> SIMD3<Float> {
        guard !vectors.isEmpty else { return .zero }
        let sortedX = vectors.map(\.x).sorted()
        let sortedY = vectors.map(\.y).sorted()
        let sortedZ = vectors.map(\.z).sorted()
        let mid = vectors.count / 2
        return SIMD3<Float>(sortedX[mid], sortedY[mid], sortedZ[mid])
    }
}
