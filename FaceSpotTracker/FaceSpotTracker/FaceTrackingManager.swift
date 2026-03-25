import Foundation
import ARKit
import SceneKit
import SwiftUI
import Combine

/// Manages ARKit face tracking session and spot marking
class FaceTrackingManager: NSObject, ObservableObject {
    
    // MARK: - Published state
    @Published var isFaceTracked = false
    @Published var markedSpots: [MarkedSpot] = []
    @Published var debugInfo = ""
    
    // MARK: - AR state
    let sceneView = ARSCNView()
    private var faceNode: SCNNode?
    private var faceGeometryNode: SCNNode?
    private var currentFaceAnchor: ARFaceAnchor?
    private var dotNodes: [UUID: SCNNode] = [:]
    private var nextSpotIndex = 1
    
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
        
        // Use front camera
        sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        
        debugInfo = "Session started, looking for face..."
    }
    
    func pauseSession() {
        sceneView.session.pause()
    }
    
    // MARK: - Spot management
    
    func handleTap(at screenPoint: CGPoint) {
        guard isFaceTracked, let faceAnchor = currentFaceAnchor else {
            debugInfo = "No face tracked — can't place spot"
            return
        }
        
        // Hit test against the scene
        let hitResults = sceneView.hitTest(screenPoint, options: [
            .searchMode: SCNHitTestSearchMode.all.rawValue,
            .ignoreHiddenNodes: false
        ])
        
        // Find a hit on the face geometry node
        guard let faceHit = hitResults.first(where: { $0.node == faceGeometryNode || $0.node.parent == faceNode }) else {
            // Fallback: project the tap onto the face mesh manually
            handleTapFallback(at: screenPoint, faceAnchor: faceAnchor)
            return
        }
        
        // Convert hit position to face-local coordinates
        let localPos = faceHit.localCoordinates
        let simdLocal = SIMD3<Float>(localPos.x, localPos.y, localPos.z)
        
        // Find nearest vertex
        let vertices = faceAnchor.geometry.vertices
        let nearestIdx = findNearestVertex(to: simdLocal, vertices: vertices)
        let region = FaceRegion.classify(localPosition: simdLocal, vertexIndex: nearestIdx)
        
        let spot = MarkedSpot(
            index: nextSpotIndex,
            nearestVertexIndex: nearestIdx,
            localPosition: simdLocal,
            region: region
        )
        
        markedSpots.append(spot)
        nextSpotIndex += 1
        SpotStore.save(markedSpots)
        
        // Create visual dot
        addDotNode(for: spot)
        
        debugInfo = "Placed spot \(spot.index) at vertex \(nearestIdx) (\(region.rawValue))"
    }
    
    /// Fallback when hit test misses the face geometry node
    private func handleTapFallback(at screenPoint: CGPoint, faceAnchor: ARFaceAnchor) {
        // Project screen point into the face coordinate system
        // Use the face anchor transform to find the closest point
        let vertices = faceAnchor.geometry.vertices
        
        // Find the vertex that projects closest to the tap point on screen
        var bestIdx = 0
        var bestDist: Float = .greatestFiniteMagnitude
        
        let faceTransform = faceAnchor.transform
        
        for (idx, vertex) in vertices.enumerated() {
            // Transform vertex to world space
            let worldPos4 = faceTransform * SIMD4<Float>(vertex.x, vertex.y, vertex.z, 1.0)
            let worldPos3 = SCNVector3(worldPos4.x, worldPos4.y, worldPos4.z)
            
            // Project to screen
            let projected = sceneView.projectPoint(worldPos3)
            let screenPt = CGPoint(x: CGFloat(projected.x), y: CGFloat(projected.y))
            
            let dx = Float(screenPt.x - screenPoint.x)
            let dy = Float(screenPt.y - screenPoint.y)
            let dist = dx * dx + dy * dy
            
            if dist < bestDist {
                bestDist = dist
                bestIdx = idx
            }
        }
        
        let vertexPos = vertices[bestIdx]
        let region = FaceRegion.classify(localPosition: vertexPos, vertexIndex: bestIdx)
        
        let spot = MarkedSpot(
            index: nextSpotIndex,
            nearestVertexIndex: bestIdx,
            localPosition: vertexPos,
            region: region
        )
        
        markedSpots.append(spot)
        nextSpotIndex += 1
        SpotStore.save(markedSpots)
        addDotNode(for: spot)
        
        debugInfo = "Placed spot \(spot.index) at vertex \(bestIdx) (\(region.rawValue)) [fallback]"
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
    
    // MARK: - Visual dot rendering
    
    private func addDotNode(for spot: MarkedSpot) {
        let sphere = SCNSphere(radius: 0.003) // ~3mm dot
        let material = SCNMaterial()
        material.diffuse.contents = UIColor(Color(hex: spot.colorHex))
        material.emission.contents = UIColor(Color(hex: spot.colorHex)).withAlphaComponent(0.5)
        material.isDoubleSided = true
        sphere.materials = [material]
        
        let node = SCNNode(geometry: sphere)
        node.name = "spot_\(spot.id.uuidString)"
        
        // Position at the vertex location
        let pos = spot.localPosition
        node.simdPosition = SIMD3<Float>(pos.x, pos.y, pos.z + 0.002) // slight offset outward
        
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
    
    /// Update dot positions based on current mesh vertices for maximum accuracy
    private func updateDotPositions(with faceAnchor: ARFaceAnchor) {
        let vertices = faceAnchor.geometry.vertices
        for spot in markedSpots {
            guard let node = dotNodes[spot.id] else { continue }
            if spot.nearestVertexIndex < vertices.count {
                let v = vertices[spot.nearestVertexIndex]
                // Position dot at the actual current vertex position + small outward offset
                node.simdPosition = SIMD3<Float>(v.x, v.y, v.z + 0.002)
            }
        }
    }
    
    // MARK: - Helpers
    
    private func findNearestVertex(to point: SIMD3<Float>, vertices: [SIMD3<Float>]) -> Int {
        var bestIdx = 0
        var bestDist: Float = .greatestFiniteMagnitude
        for (idx, v) in vertices.enumerated() {
            let dist = simd_distance_squared(point, v)
            if dist < bestDist {
                bestDist = dist
                bestIdx = idx
            }
        }
        return bestIdx
    }
}

// MARK: - ARSCNViewDelegate

extension FaceTrackingManager: ARSCNViewDelegate {
    
    func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
        guard let faceAnchor = anchor as? ARFaceAnchor else { return nil }
        
        // Create face geometry for hit testing
        let device = sceneView.device!
        let faceGeometry = ARSCNFaceGeometry(device: device, fillMesh: true)!
        
        // Make the face mesh mostly transparent but hittable
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
        
        // Re-add any persisted dots
        DispatchQueue.main.async {
            self.rebuildAllDotNodes()
        }
        
        return node
    }
    
    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard let faceAnchor = anchor as? ARFaceAnchor else { return }
        
        currentFaceAnchor = faceAnchor
        
        // Update the face mesh geometry
        if let faceGeometry = faceGeometryNode?.geometry as? ARSCNFaceGeometry {
            faceGeometry.update(from: faceAnchor.geometry)
        }
        
        // Update dot positions to track with mesh deformation
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
