import Foundation
import Vision

/// Reads text in images on this Mac with Vision, so screenshots can be searched.
enum TextRecognizer {
    /// The lines of text found in the image at `url`, or "" when there are none.
    @concurrent
    nonisolated static func text(in url: URL) async -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        guard let observations = try? await request.perform(on: url) else { return "" }
        return observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}
