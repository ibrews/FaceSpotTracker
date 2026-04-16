# FaceSpotTracker

An iOS ARKit app that lets you tap a spot on your face and have a colored dot stick to that exact location as you move your head. Medical proof-of-concept for tracking acne treatment sites over time.

Built with Swift / SwiftUI, ARKit (`ARFaceTrackingConfiguration`), and SceneKit. Requires a physical iPhone with a front-facing TrueDepth camera (iPhone 12 Pro or later) — ARKit face tracking does not work in the simulator.

## Quick Start

1. Open `FaceSpotTracker.xcodeproj` in Xcode 15+
2. Select a physical iPhone as the target device
3. Build and run (`Cmd+R`)
4. Point the front camera at your face and tap a spot to place a dot

## Things to Try

1. **Run on a physical iPhone, point the front camera at your face, and tap a spot on your cheek** — a colored dot appears anchored to that exact point on your face mesh and tracks with your head in real time.
2. **Nod, tilt, and turn your head after placing a dot** — the dot stays pinned to the same skin location through full 3D head rotation, riding the ARKit face mesh.
3. **Tap multiple spots in different locations** — each tap adds an independent dot; all dots track simultaneously.
4. **Force-quit the app and relaunch** — all marked spots persist via UserDefaults and reappear on the face mesh immediately.
5. **Hold the phone at arm's length and move closer** — ARKit re-fits the face mesh at any range; dots remain locked to the correct vertex positions.

## Tech Stack

- Swift 5.9+ / SwiftUI
- ARKit `ARFaceTrackingConfiguration` (TrueDepth camera, ~1,220-vertex face mesh)
- SceneKit `ARSCNView` for dot rendering as `SCNNode` children of the face anchor
- `MarkedSpot` model persisted to UserDefaults (SIMD components stored as separate Floats)

## Requirements

- iOS 16+
- Physical iPhone with TrueDepth camera (iPhone X or later; 12 Pro+ recommended)
- Xcode 15+
