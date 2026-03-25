import SwiftUI

struct ContentView: View {
    @StateObject private var trackingManager = FaceTrackingManager()
    @State private var showingSpotList = false
    @State private var statusMessage = "Point camera at your face"
    
    var body: some View {
        ZStack {
            // AR Camera View (full screen)
            ARFaceView(trackingManager: trackingManager)
                .ignoresSafeArea()
            
            // Overlay UI
            VStack {
                // Status bar at top
                HStack {
                    Circle()
                        .fill(trackingManager.isFaceTracked ? Color.green : Color.red)
                        .frame(width: 12, height: 12)
                    Text(trackingManager.isFaceTracked ? "Face Tracked" : "No Face Detected")
                        .font(.caption)
                        .foregroundColor(.white)
                    Spacer()
                    Text("\(trackingManager.markedSpots.count) spot(s)")
                        .font(.caption)
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.black.opacity(0.5))
                
                Spacer()
                
                // Info text
                if trackingManager.markedSpots.isEmpty && trackingManager.isFaceTracked {
                    Text("Tap on a spot on your face to mark it")
                        .font(.callout)
                        .foregroundColor(.white)
                        .padding(12)
                        .background(.black.opacity(0.6))
                        .cornerRadius(8)
                        .padding(.bottom, 8)
                }
                
                // Bottom controls
                HStack(spacing: 20) {
                    // Clear all spots
                    Button(action: {
                        trackingManager.clearAllSpots()
                    }) {
                        Label("Clear", systemImage: "trash")
                            .font(.callout)
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.red.opacity(0.7))
                            .cornerRadius(8)
                    }
                    .disabled(trackingManager.markedSpots.isEmpty)
                    
                    // Toggle spot labels
                    Button(action: {
                        showingSpotList.toggle()
                    }) {
                        Label("Spots", systemImage: "list.bullet")
                            .font(.callout)
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.blue.opacity(0.7))
                            .cornerRadius(8)
                    }
                    
                    // Undo last spot
                    Button(action: {
                        trackingManager.removeLastSpot()
                    }) {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                            .font(.callout)
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.orange.opacity(0.7))
                            .cornerRadius(8)
                    }
                    .disabled(trackingManager.markedSpots.isEmpty)
                }
                .padding(.bottom, 30)
            }
            
            // Spot list overlay
            if showingSpotList {
                SpotListView(
                    spots: trackingManager.markedSpots,
                    onDismiss: { showingSpotList = false },
                    onDelete: { spot in
                        trackingManager.removeSpot(id: spot.id)
                    }
                )
            }
        }
    }
}

struct SpotListView: View {
    let spots: [MarkedSpot]
    let onDismiss: () -> Void
    let onDelete: (MarkedSpot) -> Void
    
    var body: some View {
        VStack {
            HStack {
                Text("Marked Spots")
                    .font(.headline)
                Spacer()
                Button("Done") { onDismiss() }
            }
            .padding()
            
            if spots.isEmpty {
                Text("No spots marked yet")
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                List {
                    ForEach(spots) { spot in
                        HStack {
                            Circle()
                                .fill(spot.color)
                                .frame(width: 16, height: 16)
                            VStack(alignment: .leading) {
                                Text(spot.label ?? "Spot \(spot.index)")
                                    .font(.body)
                                Text("Vertex \(spot.nearestVertexIndex) • \(spot.region.rawValue)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(spot.createdAt, style: .relative)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button(action: { onDelete(spot) }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.red.opacity(0.7))
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: 400)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .padding()
    }
}
