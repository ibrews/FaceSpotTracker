import Foundation
import SwiftUI
import simd

/// Represents a marked spot on the face mesh
struct MarkedSpot: Identifiable, Codable {
    let id: UUID
    let index: Int
    let nearestVertexIndex: Int

    // On-device Gemma 4 skin analysis (populated after user taps Analyze)
    var skinAnalysis: SkinAnalysisResult?

    // Store as plain floats for Codable (SIMD3 doesn't conform)
    let localX: Float
    let localY: Float
    let localZ: Float

    let createdAt: Date
    var label: String?
    let colorHex: String
    let region: FaceRegion

    // Confidence & accuracy
    let confidence: Float       // 0.0 to 1.0
    let vertexDistance: Float    // distance in meters from tap to nearest vertex

    // Neck extrapolation
    let isExtrapolated: Bool
    let anchorVertexIndex: Int?
    let extrapolationOffsetX: Float?
    let extrapolationOffsetY: Float?
    let extrapolationOffsetZ: Float?

    /// Convenience accessor for SIMD position
    var localPosition: SIMD3<Float> {
        SIMD3<Float>(localX, localY, localZ)
    }

    /// Extrapolation offset vector for neck spots
    var extrapolationOffset: SIMD3<Float>? {
        guard let x = extrapolationOffsetX,
              let y = extrapolationOffsetY,
              let z = extrapolationOffsetZ else { return nil }
        return SIMD3<Float>(x, y, z)
    }

    var color: Color {
        Color(hex: colorHex)
    }

    var confidenceLabel: String {
        if confidence >= 0.9 { return "High" }
        if confidence >= 0.7 { return "Good" }
        if confidence >= 0.5 { return "Fair" }
        return "Low"
    }

    var confidenceColor: Color {
        if confidence >= 0.9 { return .green }
        if confidence >= 0.7 { return .yellow }
        if confidence >= 0.5 { return .orange }
        return .red
    }

    /// Margin of error radius in meters (for visualization)
    var marginOfError: Float {
        max(0.002, (1.0 - confidence) * 0.012)
    }

    private static let colorPalette = [
        "#FF6B6B", "#4ECDC4", "#45B7D1", "#96CEB4",
        "#FFEAA7", "#DDA0DD", "#98D8C8", "#FF8C94",
        "#A8E6CF", "#FFD3B6", "#FF677D", "#D4A5A5"
    ]

    /// Standard init for on-mesh spots
    init(
        index: Int,
        nearestVertexIndex: Int,
        localPosition: SIMD3<Float>,
        label: String? = nil,
        region: FaceRegion = .unknown,
        confidence: Float = 1.0,
        vertexDistance: Float = 0.0
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
        self.confidence = confidence
        self.vertexDistance = vertexDistance
        self.isExtrapolated = false
        self.anchorVertexIndex = nil
        self.extrapolationOffsetX = nil
        self.extrapolationOffsetY = nil
        self.extrapolationOffsetZ = nil
        self.colorHex = Self.colorPalette[index % Self.colorPalette.count]
    }

    /// Init for extrapolated neck spots anchored to a jawline vertex
    init(
        index: Int,
        anchorVertexIndex: Int,
        anchorPosition: SIMD3<Float>,
        extrapolationOffset: SIMD3<Float>,
        label: String? = nil,
        confidence: Float = 0.5,
        vertexDistance: Float = 0.0
    ) {
        self.id = UUID()
        self.index = index
        self.nearestVertexIndex = anchorVertexIndex
        let finalPos = anchorPosition + extrapolationOffset
        self.localX = finalPos.x
        self.localY = finalPos.y
        self.localZ = finalPos.z
        self.createdAt = Date()
        self.label = label
        self.region = .neck
        self.confidence = confidence
        self.vertexDistance = vertexDistance
        self.isExtrapolated = true
        self.anchorVertexIndex = anchorVertexIndex
        self.extrapolationOffsetX = extrapolationOffset.x
        self.extrapolationOffsetY = extrapolationOffset.y
        self.extrapolationOffsetZ = extrapolationOffset.z
        self.colorHex = Self.colorPalette[index % Self.colorPalette.count]
    }

    /// Backward-compatible decoder for existing saved spots
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        index = try c.decode(Int.self, forKey: .index)
        nearestVertexIndex = try c.decode(Int.self, forKey: .nearestVertexIndex)
        localX = try c.decode(Float.self, forKey: .localX)
        localY = try c.decode(Float.self, forKey: .localY)
        localZ = try c.decode(Float.self, forKey: .localZ)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        colorHex = try c.decode(String.self, forKey: .colorHex)
        region = try c.decode(FaceRegion.self, forKey: .region)
        // New fields with defaults for old data
        confidence = try c.decodeIfPresent(Float.self, forKey: .confidence) ?? 1.0
        vertexDistance = try c.decodeIfPresent(Float.self, forKey: .vertexDistance) ?? 0.0
        isExtrapolated = try c.decodeIfPresent(Bool.self, forKey: .isExtrapolated) ?? false
        anchorVertexIndex = try c.decodeIfPresent(Int.self, forKey: .anchorVertexIndex)
        extrapolationOffsetX = try c.decodeIfPresent(Float.self, forKey: .extrapolationOffsetX)
        extrapolationOffsetY = try c.decodeIfPresent(Float.self, forKey: .extrapolationOffsetY)
        extrapolationOffsetZ = try c.decodeIfPresent(Float.self, forKey: .extrapolationOffsetZ)
        skinAnalysis = try c.decodeIfPresent(SkinAnalysisResult.self, forKey: .skinAnalysis)
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
    case neck = "Neck"
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

    /// Backward-compatible decoder: migrates old "Neck (extrapolated)" to "Neck"
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        if let region = FaceRegion(rawValue: rawValue) {
            self = region
        } else if rawValue == "Neck (extrapolated)" {
            self = .neck
        } else {
            self = .unknown
        }
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
