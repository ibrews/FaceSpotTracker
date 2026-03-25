# FaceSpotTracker

An iOS ARKit app that lets you tap on spots (pimples, acne treatment sites) on your face and have colored dots stick to them as you move your head. Built as a medical proof-of-concept for tracking healing treatment sites over time.

## How It Works

1. Point the front-facing camera at your face
2. ARKit detects and tracks your face mesh in real time
3. Tap anywhere on your face to place a colored dot
4. Dots stay anchored to the exact spot on your face as you move

Dots are rendered as SceneKit nodes attached to the ARKit face mesh, updating their positions every frame based on the mesh's ~1,220 vertices.

## Features

- Real-time face tracking with ARKit TrueDepth camera
- Tap-to-place colored marker dots on face mesh vertices
- Dots track with head movement (translation + rotation)
- Spot list view with region labels and timestamps
- Undo last spot / clear all spots
- Persistent storage via UserDefaults

## Requirements

- Xcode 15+
- iOS 16+
- **Physical iPhone with TrueDepth camera** (iPhone X or later) — ARKit face tracking does not work in the simulator
- Tested on iPhone 12 Pro and iPhone 15 Pro

## Tech Stack

- Swift 5.9+ / SwiftUI
- ARKit (`ARFaceTrackingConfiguration`)
- SceneKit (`ARSCNView`)

## Building

Open `FaceSpotTracker.xcodeproj` in Xcode, select your physical device, and run.
