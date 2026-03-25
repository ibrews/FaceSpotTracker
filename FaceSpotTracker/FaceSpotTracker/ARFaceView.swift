import SwiftUI
import ARKit
import SceneKit

/// SwiftUI wrapper for ARSCNView with face tracking
struct ARFaceView: UIViewRepresentable {
    @ObservedObject var trackingManager: FaceTrackingManager
    
    func makeUIView(context: Context) -> ARSCNView {
        let sceneView = trackingManager.sceneView
        sceneView.scene = SCNScene()
        
        // Add tap gesture recognizer
        let tapGesture = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        sceneView.addGestureRecognizer(tapGesture)
        
        // Start the AR session
        trackingManager.startSession()
        
        return sceneView
    }
    
    func updateUIView(_ uiView: ARSCNView, context: Context) {
        // No dynamic updates needed — ARKit handles rendering
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(trackingManager: trackingManager)
    }
    
    static func dismantleUIView(_ uiView: ARSCNView, coordinator: Coordinator) {
        uiView.session.pause()
    }
    
    class Coordinator: NSObject {
        let trackingManager: FaceTrackingManager
        
        init(trackingManager: FaceTrackingManager) {
            self.trackingManager = trackingManager
        }
        
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            let location = gesture.location(in: trackingManager.sceneView)
            trackingManager.handleTap(at: location)
        }
    }
}
