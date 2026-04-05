import Foundation
import UIKit
import MediaPipeTasksGenAI

// MARK: - On-Device Gemma 4 E4B Inference Engine
//
// Architecture Decision (2026-04-05): Option C — on-device iPhone inference.
// Model: gemma-4-E4B-it.litertlm (3.65 GB, NOT E2B — crashes on iPhone 16 Pro, bug #556)
// SDK: MediaPipe LLM Inference API, pod 'MediaPipeTasksGenAI' 0.10.33
//
// Vision modality: enabled at session level via LlmInference.Session.Options.enableVisionModality
// Session.addImage(image: CGImage) is available — takes a CGImage directly.
// visionEncoderPath / visionAdapterPath are optional on LlmInference.Options;
// Gemma 4 E4B may include vision components inside the .litertlm bundle (TBD on first run).
//
// If the model load fails (unsupported format): switch to gemma-3n-E2B-it-int4.task
// from the nostalgic-dhawan branch which is confirmed working text-only.

// MARK: - Result Types

struct SkinAnalysisResult {
    let text: String
    let inferenceTimeSeconds: Double
    let usedVisionModality: Bool
}

enum InferenceError: LocalizedError {
    case modelNotFound(path: String)
    case sessionCreationFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let path):
            return "Model file not found at:\n\(path)\n\nSee MODEL_SETUP.md for download instructions."
        case .sessionCreationFailed(let reason):
            return "Session failed: \(reason)"
        }
    }
}

enum EngineState: Equatable {
    case unloaded
    case loading
    case ready
    case inferring
    case error(String)
}

// MARK: - GemmaInferenceEngine

@MainActor
final class GemmaInferenceEngine: ObservableObject {

    // MARK: - Configuration

    static let modelFileName = "gemma-4-E4B-it.litertlm"

    static var modelFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(modelFileName)
    }

    static let skinAnalysisSystemPrompt = """
        You are a dermatology assistant helping users document skin spots for tracking over time. \
        You are NOT providing medical diagnoses. Always include a disclaimer.

        When shown a skin image, provide:
        1. DESCRIPTION: What you observe (color, shape, texture, size estimate, borders)
        2. ABCDE CHECK: Asymmetry, Border, Color variation, Diameter, Evolution (note you cannot assess Evolution from one image)
        3. RECOMMENDATION: Monitor, photograph regularly, or consult a dermatologist
        4. DISCLAIMER: End with "This is not medical advice. Consult a dermatologist for any concerns."

        Be concise. Maximum 200 words.
        """

    // MARK: - Published state

    @Published var state: EngineState = .unloaded
    @Published var streamingOutput: String = ""
    @Published var lastResult: SkinAnalysisResult?
    @Published var loadTimeSeconds: Double?

    // MARK: - Private

    private var llmInference: LlmInference?

    // MARK: - Model availability

    var isModelFilePresent: Bool {
        FileManager.default.fileExists(atPath: Self.modelFileURL.path)
    }

    var modelFileSizeMB: Double? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: Self.modelFileURL.path),
              let bytes = attrs[.size] as? Int else { return nil }
        return Double(bytes) / 1_048_576
    }

    // MARK: - Load

    func loadModel() async {
        guard isModelFilePresent else {
            state = .error(InferenceError.modelNotFound(path: Self.modelFileURL.path).localizedDescription)
            return
        }

        state = .loading
        let start = Date()

        do {
            // LlmInference.Options — model-level config
            let options = LlmInference.Options(modelPath: Self.modelFileURL.path)
            options.maxTokens = 512
            options.maxTopk = 40      // maxTopk on Options (GPU only; bounds session topk)
            options.maxImages = 1     // allow image input in sessions

            // visionEncoderPath / visionAdapterPath left unset:
            // Gemma 4 E4B .litertlm may include vision components internally.
            // If addImage() fails at inference time, we fall back to text-only.

            let inference = try await Task.detached(priority: .userInitiated) {
                try LlmInference(options: options)
            }.value

            llmInference = inference
            loadTimeSeconds = Date().timeIntervalSince(start)
            state = .ready
        } catch {
            state = .error("Model load failed: \(error.localizedDescription)")
        }
    }

    func unloadModel() {
        llmInference = nil
        state = .unloaded
        loadTimeSeconds = nil
    }

    // MARK: - Inference

    @discardableResult
    func analyzeSkinImage(_ image: UIImage) async throws -> SkinAnalysisResult {
        guard case .ready = state else {
            throw InferenceError.sessionCreationFailed("Engine not in ready state: \(state)")
        }
        guard let inference = llmInference else {
            throw InferenceError.sessionCreationFailed("LlmInference is nil")
        }

        state = .inferring
        streamingOutput = ""
        let inferenceStart = Date()
        defer { state = .ready }

        // Vision modality requires visionEncoderPath + visionAdapterPath in LlmInference.Options.
        // Google has not yet released these files for Gemma 4 E4B in .task format (April 2026).
        // Enabling enableVisionModality without them throws an ObjC NSException (not catchable
        // in Swift). Text-only inference is the active path until encoder files are released.
        // TODO(alex): Re-enable vision session once encoder/adapter paths are set in Options.
        let responseText = try await streamingInferenceResponse(
            inference: inference,
            prompt: buildTextPrompt()
        )
        let usedVision = false

        let result = SkinAnalysisResult(
            text: responseText,
            inferenceTimeSeconds: Date().timeIntervalSince(inferenceStart),
            usedVisionModality: usedVision
        )
        lastResult = result
        return result
    }

    // MARK: - Private streaming helpers

    private func streamingInferenceResponse(inference: LlmInference, prompt: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            var accumulated = ""
            var didFinish = false

            do {
                try inference.generateResponseAsync(
                    inputText: prompt,
                    progress: { [weak self] partial, error in
                        if let error, !didFinish {
                            didFinish = true
                            continuation.resume(throwing: error)
                            return
                        }
                        if let partial {
                            accumulated += partial
                            Task { @MainActor [weak self] in
                                self?.streamingOutput = accumulated
                            }
                        }
                    },
                    completion: {
                        if !didFinish {
                            didFinish = true
                            continuation.resume(returning: accumulated)
                        }
                    }
                )
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func buildTextPrompt() -> String {
        // Text-only until vision encoder files are released by Google.
        // The model gives a generic ABCDE framework response that the user
        // can reference when examining the photo themselves.
        return """
            \(Self.skinAnalysisSystemPrompt)

            The user has captured a photo of a skin spot for documentation. \
            Since image analysis requires hardware vision components not yet available, \
            provide a general guide for what to look for when examining the spot, \
            structured using the ABCDE framework. Include the disclaimer.
            """
    }
}

// MARK: - UIImage resize helper

private extension UIImage {
    func resizedForInference(maxDimension: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxDimension else { return self }
        let scale = maxDimension / longest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in draw(in: CGRect(origin: .zero, size: newSize)) }
    }
}
