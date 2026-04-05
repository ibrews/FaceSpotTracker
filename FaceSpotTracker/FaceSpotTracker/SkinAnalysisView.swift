import SwiftUI
import PhotosUI

// MARK: - Skin Analysis PoC View
//
// Standalone SwiftUI view that demonstrates on-device Gemma 4 E4B inference
// for skin spot analysis. Can be presented as a sheet from ContentView.
//
// To wire into the main app:
//   1. Add a button in ContentView's bottom toolbar:
//        Button("Analyze") { showingAnalysis = true }
//   2. Add .sheet(isPresented: $showingAnalysis) { SkinAnalysisView() }
//   3. Optionally pass a captured UIImage directly instead of using the photo picker.
//
// Integration with the face tracking flow:
//   - The ideal UX is: user marks a spot → taps "Analyze" → back camera captures
//     a close-up of the spot → GemmaInferenceEngine analyzes it.
//   - For this PoC, we use PhotosPicker + live camera option instead since the
//     full ARKit+back-camera capture integration is a separate task.

struct SkinAnalysisView: View {

    @StateObject private var engine = GemmaInferenceEngine()
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var selectedImage: UIImage?
    @State private var showingModelSetup = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // MARK: Model status banner
                    ModelStatusBanner(engine: engine)

                    // MARK: Image picker
                    ImagePickerSection(
                        selectedPhoto: $selectedPhoto,
                        selectedImage: $selectedImage,
                        engine: engine
                    )

                    // MARK: Inference result
                    if let result = engine.lastResult {
                        ResultCard(result: result)
                    }

                    // MARK: Streaming output (live while inferring)
                    if case .inferring = engine.state, !engine.streamingOutput.isEmpty {
                        StreamingCard(text: engine.streamingOutput)
                    }

                    // MARK: Error display
                    if case .error(let msg) = engine.state {
                        ErrorCard(message: msg, showSetup: {
                            showingModelSetup = true
                        })
                    }
                }
                .padding()
            }
            .navigationTitle("Skin Analysis")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingModelSetup) {
                ModelSetupSheet()
            }
            .onChange(of: selectedPhoto) { newItem in
                Task {
                    guard let item = newItem,
                          let data = try? await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) else { return }
                    selectedImage = image
                    selectedPhoto = nil
                    await runAnalysis(on: image)
                }
            }
        }
    }

    private func runAnalysis(on image: UIImage) async {
        // Load model if not yet loaded
        if case .unloaded = engine.state {
            await engine.loadModel()
        }
        guard case .ready = engine.state else { return }

        do {
            try await engine.analyzeSkinImage(image)
        } catch {
            // State is already set to .error in the engine
        }
    }
}

// MARK: - Model Status Banner

private struct ModelStatusBanner: View {
    @ObservedObject var engine: GemmaInferenceEngine

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: statusIcon)
                .foregroundColor(statusColor)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.subheadline.bold())
                Text(statusDetail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if case .unloaded = engine.state {
                if engine.isModelFilePresent {
                    Button("Load") {
                        Task { await engine.loadModel() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if case .loading = engine.state {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(statusBackgroundColor.opacity(0.12))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(statusColor.opacity(0.3), lineWidth: 1)
        )
    }

    private var statusIcon: String {
        switch engine.state {
        case .unloaded:    return engine.isModelFilePresent ? "cpu" : "arrow.down.circle"
        case .loading:     return "hourglass"
        case .ready:       return "checkmark.circle.fill"
        case .inferring:   return "sparkles"
        case .error:       return "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch engine.state {
        case .unloaded:  return engine.isModelFilePresent ? .blue : .orange
        case .loading:   return .blue
        case .ready:     return .green
        case .inferring: return .purple
        case .error:     return .red
        }
    }

    private var statusBackgroundColor: Color { statusColor }

    private var statusTitle: String {
        switch engine.state {
        case .unloaded:
            return engine.isModelFilePresent ? "Gemma 4 E4B — Ready to Load" : "Model Not Found"
        case .loading:
            return "Loading Gemma 4 E4B..."
        case .ready:
            let loadTime = engine.loadTimeSeconds.map { String(format: " (loaded in %.1fs)", $0) } ?? ""
            return "Gemma 4 E4B — On Device\(loadTime)"
        case .inferring:
            return "Analyzing..."
        case .error:
            return "Error"
        }
    }

    private var statusDetail: String {
        switch engine.state {
        case .unloaded:
            if engine.isModelFilePresent {
                let sizeMB = engine.modelFileSizeMB.map { String(format: "%.1f MB", $0) } ?? "?"
                return "gemma-4-E4B-it-litert-lm.litertlm · \(sizeMB)"
            }
            return "Download required — see setup instructions"
        case .loading:
            return "First load takes ~10–20 seconds on iPhone 15/16 Pro"
        case .ready:
            return "CPU: ~961 MB RAM · ~9 tok/s · GPU: ~3.4 GB · ~25 tok/s"
        case .inferring:
            return "Running on-device inference..."
        case .error(let msg):
            return msg
        }
    }
}

// MARK: - Image Picker Section

private struct ImagePickerSection: View {
    @Binding var selectedPhoto: PhotosPickerItem?
    @Binding var selectedImage: UIImage?
    @ObservedObject var engine: GemmaInferenceEngine

    var body: some View {
        VStack(spacing: 12) {
            // Selected image preview
            if let image = selectedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 280)
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.1))
                    .frame(height: 200)
                    .overlay(
                        VStack(spacing: 8) {
                            Image(systemName: "photo.on.rectangle")
                                .font(.system(size: 36))
                                .foregroundColor(.secondary)
                            Text("Select a skin image to analyze")
                                .font(.callout)
                                .foregroundColor(.secondary)
                        }
                    )
            }

            // Picker button
            PhotosPicker(
                selection: $selectedPhoto,
                matching: .images,
                photoLibrary: .shared()
            ) {
                Label("Choose Photo", systemImage: "photo.badge.plus")
                    .font(.callout)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.blue.opacity(0.15))
                    .foregroundColor(.blue)
                    .cornerRadius(10)
            }
            .disabled(engine.state == .loading || engine.state == .inferring)

            // Analyze button (if image selected and engine ready)
            if let image = selectedImage, case .ready = engine.state {
                Button {
                    Task {
                        do {
                            try await engine.analyzeSkinImage(image)
                        } catch { }
                    }
                } label: {
                    Label("Analyze Skin Spot", systemImage: "magnifyingglass.circle.fill")
                        .font(.callout.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.purple.opacity(0.85))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
            }

            if case .inferring = engine.state {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.purple)
                    Text("Running on-device Gemma 4 E4B...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

// MARK: - Streaming Output Card

private struct StreamingCard: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Generating...", systemImage: "sparkles")
                .font(.caption.bold())
                .foregroundColor(.purple)

            Text(text)
                .font(.callout)
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(Color.purple.opacity(0.08))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.purple.opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - Result Card

private struct ResultCard: View {
    let result: SkinAnalysisResult
    @State private var isCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header with stats
            HStack {
                Label("Analysis Complete", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.bold())
                    .foregroundColor(.green)

                Spacer()

                Button {
                    UIPasteboard.general.string = result.text
                    isCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { isCopied = false }
                } label: {
                    Label(isCopied ? "Copied" : "Copy", systemImage: isCopied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            // Performance stats
            HStack(spacing: 16) {
                StatBadge(
                    label: "Time",
                    value: String(format: "%.1fs", result.inferenceTimeSeconds),
                    icon: "clock",
                    color: .blue
                )
                StatBadge(
                    label: "Vision",
                    value: result.usedVisionModality ? "Yes" : "Text fallback",
                    icon: result.usedVisionModality ? "eye.fill" : "text.bubble",
                    color: result.usedVisionModality ? .green : .orange
                )
                StatBadge(
                    label: "Backend",
                    value: "On-device",
                    icon: "cpu",
                    color: .purple
                )
            }

            Divider()

            // Result text
            Text(result.text)
                .font(.callout)
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Disclaimer notice
            if !result.text.lowercased().contains("not medical advice") {
                Label("Not medical advice — consult a dermatologist for any concerns.", systemImage: "cross.circle")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
            }
        }
        .padding(14)
        .background(Color.green.opacity(0.06))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.green.opacity(0.2), lineWidth: 1)
        )
    }
}

private struct StatBadge: View {
    let label: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(color)
            Text(value)
                .font(.system(size: 11, weight: .semibold))
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(color.opacity(0.1))
        .cornerRadius(6)
    }
}

// MARK: - Error Card

private struct ErrorCard: View {
    let message: String
    let showSetup: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Error", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.bold())
                .foregroundColor(.red)

            Text(message)
                .font(.callout)
                .foregroundColor(.primary)

            if message.contains("not found") || message.contains("not linked") || message.contains("pod install") {
                Button("View Setup Instructions", action: showSetup)
                    .font(.callout)
                    .foregroundColor(.blue)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.red.opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - Model Setup Sheet

private struct ModelSetupSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // SDK setup
                    SetupSection(
                        number: "1",
                        title: "Install MediaPipe SDK",
                        color: .blue,
                        content: """
                            Run in the FaceSpotTracker Xcode project directory:

                            pod install

                            Then open FaceSpotTracker.xcworkspace (not .xcodeproj).

                            Required pods (already in Podfile):
                            • MediaPipeTasksGenAI
                            • MediaPipeTasksGenAIC
                            """
                    )

                    // Model download
                    SetupSection(
                        number: "2",
                        title: "Download Gemma 4 E4B Model",
                        color: .purple,
                        content: """
                            Model: gemma-4-E4B-it-litert-lm.litertlm
                            Source: huggingface.co/litert-community/gemma-4-E4B-it-litert-lm
                            Size: 3.65 GB

                            Download via Hugging Face CLI:

                            pip install huggingface-hub
                            huggingface-cli download \\
                              litert-community/gemma-4-E4B-it-litert-lm \\
                              gemma-4-E4B-it-litert-lm.litertlm \\
                              --local-dir ~/Downloads/gemma4

                            ⚠️  Do NOT use E2B — crashes on iPhone 16 Pro (bug #556).
                            """
                    )

                    // Model placement
                    SetupSection(
                        number: "3",
                        title: "Copy Model to Device",
                        color: .green,
                        content: """
                            The app looks for the model in:
                            Application Support/Models/
                            gemma-4-E4B-it-litert-lm.litertlm

                            Options to get it there:
                            A) Via Xcode Devices: Window → Devices and Simulators → your device → FaceSpotTracker → drag model file into app container
                            B) Via Files app: Copy .litertlm to the FaceSpotTracker app's On My iPhone folder, then the app can move it on first launch
                            C) Download-at-runtime (future): Add a model download manager that fetches from a CDN or Hugging Face

                            ⚠️  3.65 GB — cannot ship in the app bundle (App Store 4 GB limit, but bundle + assets would exceed limit). Runtime download is the production path.
                            """
                    )

                    // Memory note
                    SetupSection(
                        number: "4",
                        title: "Device Requirements",
                        color: .orange,
                        content: """
                            Minimum: iPhone 15 Pro (A17 Pro, 8 GB RAM)
                            Recommended: iPhone 16 Pro (A18 Pro, 8 GB RAM)

                            Memory budget:
                            • iOS + ARKit: ~2 GB
                            • Gemma 4 E4B CPU: ~961 MB
                            • Gemma 4 E4B GPU: ~3,380 MB
                            • Total GPU mode: ~5.4 GB (tight on 8 GB — use CPU mode first)

                            ⚠️  iPhone 15 / 16 (non-Pro, 6 GB) — E4B likely fails on GPU.
                                Use CPU backend. Slower (~9 tok/s) but stable.
                            """
                    )
                }
                .padding()
            }
            .navigationTitle("Setup Instructions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct SetupSection: View {
    let number: String
    let title: String
    let color: Color
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle()
                    .fill(color)
                    .frame(width: 26, height: 26)
                    .overlay(
                        Text(number)
                            .font(.caption.bold())
                            .foregroundColor(.white)
                    )
                Text(title)
                    .font(.headline)
            }

            Text(content)
                .font(.callout)
                .foregroundColor(.primary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(color.opacity(0.07))
                .cornerRadius(8)
        }
    }
}
