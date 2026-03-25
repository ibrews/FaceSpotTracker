import Foundation
import SwiftUI
import simd

/// Represents a marked spot on the face mesh
struct MarkedSpot: Identifiable, Codable {
    let id: UUID
    let index: Int // sequential index for display
    let nearestVertexIndex: Int // ARKit face mesh vertex index (0-1219)
    
    // Store as plain floats for Codable (SIMD3 doesn't conform)
    let localX: Float
    let localY: Float
    let localZ: Float
    
    let createdAt: Date
    var label: String?
    let colorHex: String
    let region: FaceRegion
    
    /// Convenience accessor for SIMD position
    var localPosition: SIMD3<Float> {
        SIMD3<Float>(localX, localY, localZ)
    }
    
    var color: Color {
        Color(hex: colorHex)
    }
    
    init(
        index: Int,
        nearestVertexIndex: Int,
        localPosition: SIMD3<Float>,
        label: String? = nil,
        region: FaceRegion = .unknown
    ) {
        self.id = UUID()
        self.index = index
        self.nearestVertexIndex = nearestVertexIndex
        self.localX = localPosition.x
        self.localY = localPosition.y
        self.localZ = localPosition.z
        self.createdAt = Date()
        self.label = label
        self.region = region
        
        // Assign a distinct color from a palette
        let colors = [
            "#FF6B6B", "#4ECDC4", "#45B7D1", "#96CEB4",
            "#FFEAA7", "#DDA0DD", "#98D8C8", "#FF8C94",
            "#A8E6CF", "#FFD3B6", "#FF677D", "#D4A5A5"
        ]
        self.colorHex = colors[index % colors.count]
    }
}

/// Classifies which region of the face a spot is in
enum FaceRegion: String, Codable, CaseIterable {
    case forehead = "Forehead"
    case leftCheek = "Left Cheek"
    case rightCheek = "Right Cheek"
    case nose = "Nose"
    case chin = "Chin"
    case jawline = "Jawline"
    case neck = "Neck (extrapolated)"
    case unknown = "Unknown"
    
    /// Classify based on the local position on the face mesh
    /// ARKit face mesh: origin at nose tip, Y up, X right (from face's perspective)
    static func classify(localPosition pos: SIMD3<Float>, vertexIndex: Int) -> FaceRegion {
        if pos.y > 0.035 {
            return .forehead
        } else if pos.y < -0.045 {
            if pos.y < -0.065 {
                return .neck
            }
            return pos.x.magnitude < 0.025 ? .chin : .jawline
        } else if pos.x.magnitude < 0.015 && pos.y > -0.01 {
            return .nose
        } else if pos.x > 0.015 {
            return .leftCheek
        } else if pos.x < -0.015 {
            return .rightCheek
        }
        return .unknown
    }
}

/// Persistence for marked spots
class SpotStore {
    private static let key = "com.facespottracker.spots"
    
    static func save(_ spots: [MarkedSpot]) {
        if let data = try? JSONEncoder().encode(spots) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
    
    static func load() -> [MarkedSpot] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let spots = try? JSONDecoder().decode([MarkedSpot].self, from: data) else {
            return []
        }
        return spots
    }
    
    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

// MARK: - Color hex extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255.0
        let g = Double((int >> 8) & 0xFF) / 255.0
        let b = Double(int & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}
