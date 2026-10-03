import CoreGraphics
import Vision

enum TextRecognizer {
    /// Recognizes text in an image using the on-device Vision framework.
    static func recognize(_ image: CGImage, keepLineBreaks: Bool) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            return lines.joined(separator: keepLineBreaks ? "\n" : " ")
        }.value
    }
}
