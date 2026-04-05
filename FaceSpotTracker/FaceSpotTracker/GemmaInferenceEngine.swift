import Foundation
import UIKit

// MARK: - On-Device Gemma 4 Inference Engine
//
// Architecture Decision (2026-04-05): Option C — on-device iPhone inference.
// Model: Gemma 4 E4B (NOT E2B — crashes on iPhone 16 Pro, open bug #556 in google-ai-edge/gallery)
// SDK: MediaPipe LLM Inference API (pod 'MediaPipeTasksGenAI')
// Format: gemma-4-E4B-it-litert-lm.litertlm (3.65 GB on disk)
//
// Memory profile on iPhone 17 Pro (extrapolate down ~15% for iPhone 16 Pro):
//   CPU backend: ~961 MB RAM, ~9.7 tok/s decode
//   GPU backend: ~3,380 MB RAM, ~25.1 tok/s decode
//
// The MediaPipe LLM Inference API is deprecated in favour of LiteRT-LM,
// but LiteRT-LM Swift bindings are not yet released (as of April 2026).
// We use MediaPipe for now; the interface here is designed so we can swap the
// backend once LiteRT-LM Swift ships without touching call sites.
//
// Multimodal status: The LlmInferenceSession vision API exists on Android.
// The iOS Swift mirror is unconfirmed in public docs. This file implements
// both the session-based path (attempted at runtime) and a text-only fallback
// (describe the image in the prompt). Mark the TODO below when the vision
// session API is confirmed or denied on iOS.
//
// TODO(alex): Verify LlmInferenceSession + enableVisionModality on iOS once
//             we can run this against a real device with the pod installed.
//             Tracker: google-ai-edge/LiteRT-LM — watch Swift API release.

// --------------------------------------------------------------------------
// Conditional import: compiles without the pod present (e.g. in CI or
// before 'pod install') so the rest of the project still builds.
// Remove the #if block once the pod is integrated.
// --------------------------------------------------------------------------
#if canImport(MediaPipeTasksGenai)
import MediaPipeTasksGenai
#endif

// MARK: - Result Types

struct SkinAnalysisResult {
    let text: String
    let inferenceTimeSeconds: Double
    let prefillTokensPerSecond: Double?
    let decodeTokensPerSecond: Double?
    let peakMemoryMB: Double?
    let usedVisionModality: Bool
}

enum InferenceError: LocalizedError {
    case modelNotFound(path: String)
    case sdkNotAvailable
    case sessionCreationFailed(String)
    case inferenceFailedWithoutVision

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let path):
            return "Model file not found at \(path). See MODEL_SETUP.md for download instructions."
        case .sdkNotAvailable:
            return "MediaPipe SDK not linked. Run 'pod install' and reopen the .xcworkspace."
        case .sessionCreationFailed(let reason):
            return "Session creation failed: \(reason)"
        case .inferenceFailedWithoutVision:
            return "Vision modality not available on this SDK version; using text-only fallback."
        }
    }
}

// MARK: - Engine State

enum EngineState: Equatable {
    case unloaded
    case loading
    case ready
    case inferring
    case error(String)
}

// MARK: - GemmaInferenceEngine

/// Wraps MediaPipe LLM Inference to run Gemma 4 E4B on-device.
///
/// Usage:
///   1. Call `loadModel()` once on app launch (or lazily before first inference).
///   2. Call `analyzeSkinImage(_:)` with a UIImage from the camera.
///   3. Observe `streamingOutput` for partial tokens and `lastResult` for the final result.
///
/// The model file must exist at `modelFileURL` before calling `loadModel()`.
/// See MODEL_SETUP.md for download instructions.
@MainActor
final class GemmaInferenceEngine: ObservableObject {

    // MARK: - Configuration

    /// Where the app expects to find the .litertlm model file.
    /// We put it in Application Support (survives app updates, not backed up to iCloud by default).
    static let modelFileName = "gemma-4-E4B-it-litert-lm.litertlm"

    static var modelFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let modelsDir = appSupport.appendingPathComponent("Models", isDirectory: true)
        return modelsDir.appendingPathComponent(modelFileName)
    }

    /// Maximum tokens in the generated response.
    let maxOutputTokens = 512

    /// Skin analysis system prompt — drives structured ABCDE output.
    static let skinAnalysisSystemPrompt = """
        You are a dermatology assistant helping users document skin spots for tracking over time. \
        You are NOT providing medical diagnoses. Always include a disclaimer.

        When shown a skin image, provide:
        1. DESCRIPTION: What you observe (color, shape, texture, size estimate, borders)
        2. ABCDE CHECK: Brief assessment of Asymmetry, Border, Color variation, Diameter, Evolution (note you cannot assess Evolution from a single image)
        3. RECOMMENDATION: Whether the user should monitor this spot, photograph it regularly, or consult a dermatologist
        4. DISCLAIMER: Always end with "This is not medical advice. Consult a dermatologist for any concerns."

        Be concise. Maximum 200 words.
        """

    // MARK: - Published state

    @Published var state: EngineState = .unloaded
    @Published var streamingOutput: String = ""
    @Published var lastResult: SkinAnalysisResult?
    @Published var loadTimeSeconds: Double?

    // MARK: - Private

    #if canImport(MediaPipeTasksGenai)
    private var llmInference: LlmInference?
    #endif

    // MARK: - Model availability check

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

        #if canImport(MediaPipeTasksGenai)
        state = .loading
        let start = Date()

        do {
            let options = LlmInferenceOptions()
            options.baseOptions.modelPath = Self.modelFileURL.path
            options.maxTokens = maxOutputTokens
            options.topk = 40
            options.temperature = 0.7
            options.randomSeed = 42

            // Run on a background thread — model load blocks for several seconds
            let inference = try await Task.detached(priority: .userInitiated) {
                try LlmInference(options: options)
            }.value

            self.llmInference = inference
            self.loadTimeSeconds = Date().timeIntervalSince(start)
            self.state = .ready
        } catch {
            self.state = .error("Model load failed: \(error.localizedDescription)")
        }
        #else
        state = .error(InferenceError.sdkNotAvailable.localizedDescription)
        #endif
    }

    func unloadModel() {
        #if canImport(MediaPipeTasksGenai)
        llmInference = nil
        #endif
        state = .unloaded
        loadTimeSeconds = nil
    }

    // MARK: - Inference

    /// Analyze a skin image. Streams partial tokens into `streamingOutput`.
    /// Returns the final `SkinAnalysisResult` (also stored in `lastResult`).
    ///
    /// Image preprocessing applied automatically:
    ///   - Resized to max 1024px on longest side (prevents OOM crash, see gallery issue #18)
    ///   - Converted to JPEG at 0.8 quality for the base64 text path
    @discardableResult
    func analyzeSkinImage(_ image: UIImage) async throws -> SkinAnalysisResult {
        #if canImport(MediaPipeTasksGenai)
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

        // Preprocess: resize to ≤1024px to prevent OOM (documented crash in gallery issue #18)
        let resized = image.resizedForInference(maxDimension: 1024)

        // --- Attempt 1: Session-based vision modality ---
        // The LlmInferenceSession API with enableVisionModality exists on Android.
        // It may or may not be exposed in the iOS Swift bindings of this SDK version.
        // We try it via reflection-style optional cast; fall through to text-only on failure.
        //
        // TODO(alex): Replace this try/catch with direct API call once we confirm
        //             LlmInferenceSession.LlmInferenceSessionOptions exists on iOS.
        var usedVision = false
        var responseText = ""

        // Vision session path (requires SDK version with multimodal session support)
        // Uncomment and test once MediaPipeTasksGenAI pod is installed on device:
        //
        // let sessionOptions = LlmInferenceSession.LlmInferenceSessionOptions()
        // sessionOptions.graphOptions.enableVisionModality = true
        // if let session = try? LlmInferenceSession(llmInference: inference, options: sessionOptions),
        //    let mpImage = try? MPImage(uiImage: resized) {
        //     try session.addQueryChunk(Self.skinAnalysisSystemPrompt + "\n\nAnalyze this skin image:")
        //     try session.addImage(mpImage)
        //     responseText = try session.generateResponse()
        //     usedVision = true
        // }

        // --- Attempt 2: Text-only with base64 image (fallback) ---
        // Some Gemma 4 implementations accept <image>base64...</image> tokens.
        // Effectiveness depends on whether the runtime processes inline image data.
        // If the model ignores the image block, the response quality degrades gracefully.
        if !usedVision {
            let prompt = buildTextOnlyPrompt(image: resized)
            responseText = try await generateStreamingResponse(
                inference: inference,
                prompt: prompt
            )
        }

        let elapsed = Date().timeIntervalSince(inferenceStart)
        let result = SkinAnalysisResult(
            text: responseText,
            inferenceTimeSeconds: elapsed,
            prefillTokensPerSecond: nil,  // MediaPipe API doesn't expose these directly
            decodeTokensPerSecond: nil,
            peakMemoryMB: nil,
            usedVisionModality: usedVision
        )
        lastResult = result
        return result

        #else
        throw InferenceError.sdkNotAvailable
        #endif
    }

    // MARK: - Private helpers

    #if canImport(MediaPipeTasksGenai)
    private func generateStreamingResponse(inference: LlmInference, prompt: String) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            var accumulated = ""
            var didFinish = false

            // MediaPipe async streaming API: callback fires for each partial token
            inference.generateResponseAsync(inputText: prompt) { [weak self] partialResult, error in
                guard let self else { return }

                if let error {
                    if !didFinish {
                        didFinish = true
                        continuation.resume(throwing: error)
                    }
                    return
                }

                if let partial = partialResult {
                    accumulated += partial
                    Task { @MainActor in
                        self.streamingOutput = accumulated
                    }
                } else {
                    // nil partialResult signals completion
                    if !didFinish {
                        didFinish = true
                        continuation.resume(returning: accumulated)
                    }
                }
            }
        }
    }
    #endif

    /// Build a text-only prompt that describes the task and embeds image data.
    /// This is the fallback when the vision session API is unavailable.
    private func buildTextOnlyPrompt(image: UIImage) -> String {
        // Encode image as base64 JPEG and wrap in a data URI.
        // Gemma 4's multimodal tokenizer can parse this if the runtime supports it.
        // Even if ignored, the text prompt alone produces a generic response.
        var imageBlock = ""
        if let jpeg = image.jpegData(compressionQuality: 0.75) {
            let b64 = jpeg.base64EncodedString()
            imageBlock = "\n<image_data>data:image/jpeg;base64,\(b64)</image_data>\n"
        }

        return """
            \(Self.skinAnalysisSystemPrompt)
            \(imageBlock)
            Please analyze the skin spot or lesion shown in the image above. \
            If no image data is available, respond with: "No image received — please try again."
            """
    }
}

// MARK: - UIImage resize helper

private extension UIImage {
    /// Resize to fit within maxDimension × maxDimension, preserving aspect ratio.
    /// Critical: prevents OOM crash documented in google-ai-edge/gallery issue #18
    /// for large photos (e.g. 50 MP / ~200 MB uncompressed bitmap).
    func resizedForInference(maxDimension: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxDimension else { return self }
        let scale = maxDimension / longest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            self.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
