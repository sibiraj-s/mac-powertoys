import CoreGraphics
import Foundation
import Vision

/// A line of text Vision found, with where it is in the image.
nonisolated struct RecognizedLine: Hashable, Sendable {
    let text: String
    /// In the image's unit square, with the origin at the bottom left, as Vision gives it.
    let bounds: CGRect
}

/// What an image holds: lines of text in reading order, and the payloads of any QR codes or barcodes.
nonisolated struct ImageText: Hashable, Sendable {
    var lines: [RecognizedLine] = []
    var codes: [String] = []
}

/// Reads text in images on this Mac with Vision, so screenshots can be searched and screen
/// regions turned into text.
enum TextRecognizer {
    /// The lines of text found in the image at `url`, or "" when there are none.
    @concurrent
    nonisolated static func text(in url: URL) async -> String {
        await lines(in: url, languages: nil).map(\.text).joined(separator: "\n")
    }

    /// The lines in the image at `url`. `languages` are BCP 47 codes such as "en-US", most
    /// likely first; empty detects the language, and nil leaves Vision's own default.
    @concurrent
    nonisolated static func lines(in url: URL, languages: [String]? = [], correctsLanguage: Bool = true) async -> [RecognizedLine] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = correctsLanguage
        switch languages {
        case nil: break
        case let languages? where languages.isEmpty: request.automaticallyDetectsLanguage = true
        case let languages?: request.recognitionLanguages = languages.map { Locale.Language(identifier: $0) }
        }
        guard let observations = try? await request.perform(on: url) else { return [] }
        return observations.compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            return RecognizedLine(text: text, bounds: observation.boundingBox.cgRect)
        }
    }

    /// The text in each QR code or barcode in the image at `url`, top to bottom, without repeats.
    @concurrent
    nonisolated static func codes(in url: URL) async -> [String] {
        let request = DetectBarcodesRequest()
        guard let observations = try? await request.perform(on: url) else { return [] }
        var seen: Set<String> = []
        return observations
            .sorted { $0.boundingBox.cgRect.maxY > $1.boundingBox.cgRect.maxY }
            .compactMap(\.payloadString)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The language codes text can be read in, such as "en-US".
    nonisolated static var supportedLanguages: [String] {
        RecognizeTextRequest().supportedRecognitionLanguages.map { $0.maximalIdentifier }
    }
}
