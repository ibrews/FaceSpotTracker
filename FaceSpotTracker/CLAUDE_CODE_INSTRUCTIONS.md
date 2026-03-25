# Claude Code Instructions — FaceSpotTracker

## Project Context
You are building an iOS ARKit face tracking app that lets users tap on a pimple/spot on their face and have a colored dot stick to that spot as they move their head. This is a medical POC for tracking healing acne treatment sites.

## Tech Stack
- Swift 5.9+ / SwiftUI
- ARKit (`ARFaceTrackingConfiguration`) for 3D face mesh
- SceneKit (`ARSCNView`) for dot rendering
- Xcode 15+, iOS 16+ deployment target
- Physical iPhone required (12 Pro or 15 Pro) — ARKit face tracking does NOT work in the simulator

## Your Workflow

### Build Verification Loop
1. After any code change, run: `xcodebuild -project FaceSpotTracker.xcodeproj -scheme FaceSpotTracker -destination 'generic/platform=iOS' -configuration Debug build 2>&1 | tail -80`
2. If build fails, read the errors and fix them yourself. Do NOT ask the user to fix compile errors.
3. Keep iterating until the build succeeds.

### Visual Feedback Loop (when user has iPhone Mirroring open)
1. Run: `bash scripts/capture_phone.sh`
2. Read the captured screenshot to see what the app looks like on the physical device
3. If the screenshot is blocked (DRM), ask the user to paste a screenshot or describe what they see

### Key Files
- `FaceSpotTracker/FaceTrackingManager.swift` — Core ARKit logic, dot placement, hit testing
- `FaceSpotTracker/ContentView.swift` — SwiftUI overlay UI
- `FaceSpotTracker/ARFaceView.swift` — UIViewRepresentable bridge
- `FaceSpotTracker/MarkedSpot.swift` — Data model (Codable, persisted to UserDefaults)

## Critical Technical Notes

1. **SIMD3<Float> is NOT Codable** — MarkedSpot stores localX/Y/Z as separate Floats
2. **ARKit face mesh has ~1,220 vertices** — vertex indices 0-1219
3. **Face mesh origin is at the nose tip** — Y+ is up, X+ is right (from face's perspective), Z+ is toward camera
4. **Dots are SCNNode children of the faceNode** — they automatically move with the face transform
5. **Dot positions update every frame** via `updateDotPositions(with:)` using current vertex positions from `faceAnchor.geometry.vertices`
6. **Hit testing the face mesh**: The transparent `ARSCNFaceGeometry` node is used for SceneKit hit testing. If that misses, the fallback projects all vertices to screen space and finds the closest one to the tap point.

## Common Issues to Watch For
- If dots appear but don't track smoothly: check that `updateDotPositions` is being called in `renderer(_:didUpdate:for:)`
- If taps don't register: the face geometry material must have `isDoubleSided = true` and some alpha > 0 for hit testing
- If the app crashes on launch: probably missing camera permission in Info.plist
- If no face is detected: user needs to be in reasonable lighting, ~arm's length from front camera

## Phase 2 TODO (don't implement unless asked)
- Jaw extrapolation for neck spots
- Barycentric interpolation for sub-vertex precision
- Photo-to-photo comparison using Vision framework
