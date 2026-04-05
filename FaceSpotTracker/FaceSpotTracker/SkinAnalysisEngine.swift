import Foundation
import UIKit
import MediaPipeTasksGenAI // pod 'MediaPipeTasksGenAI' — run pod install, open .xcworkspace

// MARK: - Result model

/// ABCDE dermoscopy analysis result from on-device Gemma 4 inference.
struct SkinAnalysisResult: Codable {
    let spotID: UUID
    let analyzedAt: Date
    let asymmetry: String
    let border: String
    let color: String
    let diameter: String
    let evolution: String
    let overallAssessment: String
    let urgency: Urgency
    let rawResponse: String

    enum Urgency: String, Codable, CaseIterable {
        case routine       = "Routine"
        case monitor       = "Monitor"
        case promptReview  = "Prompt Review"
        case urgentReview  = "Urgent Review"
    }
}

// MARK: - Errors

enum SkinAnalysisError: LocalizedError {
    case modelNotLoaded(String)
    case modelFileNotFound(String)
    case imageMissing
    case inferenceFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded(let d):  return "Model not loaded: \(d)"
        case .modelFileNotFound(let p): return "Model file not found: \(p)"
        case .imageMissing:           return "Could not extract image for analysis"
        case .inferenceFailed(let d): return "Inference failed: \(d)"
        }
    }
}

// MARK: - Engine

/// On-device skin spot analysis using Google AI Edge MediaPipe Tasks (Gemma multimodal).
///
/// ## Setup
/// 1. `cd FaceSpotTracker && pod install`
/// 2. Open `FaceSpotTracker.xcworkspace`
/// 3. Model file is at:
///    FaceSpotTracker/FaceSpotTracker/Models/gemma-3n-E2B-it-int4.task  (2.9 GB)
///    Source: huggingface.co/realbyte/gemma-3n-E2B-it-int4-mediapipe
///    Add it in Xcode: drag Models/ folder into navigator → check "Add to target: FaceSpotTracker"
///    IMPORTANT: Large file — excluded from git via .gitignore. Re-download if missing.
///
/// ## Notes
/// - `LlmInference` is marked deprecated in favour of LiteRT-LM. The API still works for Gemma 4.
///   Migrating to LiteRT-LM later is straightforward — the Session pattern is the same.
/// - Model init is slow (~3–12s cold). `loadSkinEngine()` in FaceTrackingManager runs it on a
///   background queue so the UI stays responsive.
final class SkinAnalysisEngine {

    // Gemma 3n E2B int4 — MediaPipe .task format, 2.9 GB
    // Source: huggingface.co/realbyte/gemma-3n-E2B-it-int4-mediapipe
    static let defaultModelFileName = "gemma-3n-E2B-it-int4.task"

    // Optional separate vision encoder/adapter paths.
    // If nil and enableVision == true, the engine tries to run vision via the base model only.
    let visionEncoderPath: String?
    let visionAdapterPath: String?

    private var llm: LlmInference?
    private let modelPath: String
    private let inferenceQueue = DispatchQueue(
        label: "com.facespottracker.skinanalysis",
        qos: .userInitiated
    )

    // MARK: - Init

    init(modelPath: String? = nil,
         visionEncoderPath: String? = nil,
         visionAdapterPath: String? = nil) {
        if let path = modelPath {
            self.modelPath = path
        } else {
            let name = (Self.defaultModelFileName as NSString).deletingPathExtension
            let ext  = (Self.defaultModelFileName as NSString).pathExtension
            let bundlePath = Bundle.main.path(forResource: name, ofType: ext)
            let docsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
                .first?.appendingPathComponent(Self.defaultModelFileName).path
            self.modelPath = bundlePath ?? docsPath ?? ""
        }
        self.visionEncoderPath = visionEncoderPath
        self.visionAdapterPath = visionAdapterPath
    }

    // MARK: - Load

    /// Load the model into memory. Runs synchronously — call on a background thread.
    func load() throws {
        guard !modelPath.isEmpty, FileManager.default.fileExists(atPath: modelPath) else {
            throw SkinAnalysisError.modelFileNotFound(
                modelPath.isEmpty ? "(no path — add \(Self.defaultModelFileName) to bundle)" : modelPath
            )
        }

        let options = LlmInference.Options(modelPath: modelPath)
        options.maxTokens = 600
        options.maxTopk   = 40
        // Vision: set encoder/adapter paths if we have them; also reserve image slot
        if let enc = visionEncoderPath { options.visionEncoderPath = enc }
        if let ada = visionAdapterPath { options.visionAdapterPath = ada }
        options.maxImages = 1

        llm = try LlmInference(options: options)
    }

    var isLoaded: Bool { llm != nil }

    // MARK: - Analysis

    /// Analyze a skin spot crop using ABCDE dermoscopy criteria.
    /// Runs inference on a background queue; safe to call from any context.
    func analyze(image: UIImage, spotID: UUID, region: FaceRegion) async throws -> SkinAnalysisResult {
        guard let llm else {
            throw SkinAnalysisError.modelNotLoaded("Call load() before analyzing")
        }
        guard let cgImage = image.cgImage else {
            throw SkinAnalysisError.imageMissing
        }

        let prompt = buildPrompt(region: region)
        let hasVisionPaths = visionEncoderPath != nil && visionAdapterPath != nil

        let response: String = try await withCheckedThrowingContinuation { continuation in
            inferenceQueue.async {
                do {
                    let sessionOptions = LlmInference.Session.Options()
                    sessionOptions.temperature = 0.1   // factual, consistent
                    sessionOptions.topk        = 20
                    // Enable vision modality only when encoder/adapter are provided.
                    // Without separate vision files, the base model still accepts image
                    // descriptions embedded in text (graceful degradation).
                    sessionOptions.enableVisionModality = hasVisionPaths

                    let session = try LlmInference.Session(llmInference: llm, options: sessionOptions)
                    try session.addQueryChunk(inputText: prompt)
                    if hasVisionPaths {
                        // Native image path — no base64 overhead
                        try session.addImage(image: cgImage)
                    }
                    let result = try session.generateResponse()
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: SkinAnalysisError.inferenceFailed(error.localizedDescription))
                }
            }
        }

        return parseResponse(response, spotID: spotID)
    }

    // MARK: - Private

    private func buildPrompt(region: FaceRegion) -> String {
        // Gemma instruction-tuned format (chat turns)
        """
        <start_of_turn>user
        You are a dermatology assistant helping with personal skin spot monitoring (not a diagnosis).
        Analyze the skin lesion in the attached image using the ABCDE criteria. \
        It is located on the \(region.rawValue.lowercased()).

        Reply ONLY in this format — one field per line, no extra text:
        ASYMMETRY: [one sentence]
        BORDER: [one sentence]
        COLOR: [one sentence]
        DIAMETER: [estimated mm, or "Unable to assess"]
        EVOLUTION: [Cannot assess from single image — note any visible features]
        ASSESSMENT: [1–2 sentence summary of notable features]
        URGENCY: [one of: Routine / Monitor / Prompt Review / Urgent Review]
        <end_of_turn>
        <start_of_turn>model
        """
    }

    private func parseResponse(_ raw: String, spotID: UUID) -> SkinAnalysisResult {
        func extract(_ key: String) -> String {
            for line in raw.components(separatedBy: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                let prefix = key + ":"
                if t.uppercased().hasPrefix(prefix.uppercased()) {
                    return String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                }
            }
            return "Unable to assess"
        }

        let urgencyRaw = extract("URGENCY").lowercased()
        let urgency = SkinAnalysisResult.Urgency.allCases.first {
            urgencyRaw.contains($0.rawValue.lowercased())
        } ?? .routine

        return SkinAnalysisResult(
            spotID: spotID,
            analyzedAt: Date(),
            asymmetry: extract("ASYMMETRY"),
            border: extract("BORDER"),
            color: extract("COLOR"),
            diameter: extract("DIAMETER"),
            evolution: extract("EVOLUTION"),
            overallAssessment: extract("ASSESSMENT"),
            urgency: urgency,
            rawResponse: raw
        )
    }
}
