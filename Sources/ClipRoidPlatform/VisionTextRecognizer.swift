import Foundation
import Vision
import ClipRoidCore
import ClipRoidImaging
import os.log

/// Vision-backed OCR for image and screenshot clips (spec §4.8).
///
/// This is what makes "find that screenshot of the error message" work — the extracted text lands
/// in `clips.ocr_text`, which is an FTS-indexed column, so the clip becomes searchable by its
/// visible text a second or two after it was copied.
public struct VisionTextRecognizer: TextRecognizing {
    private let logger = Logger(subsystem: "dev.philtronic.ClipRoid", category: "OCR")

    public init() {}

    public func recognizeText(in imageData: Data) async throws -> String? {
        // Vision is markedly faster on a downsampled image and accuracy on screen text does not
        // improve above ~2000px (spec §8.3).
        let prepared = Thumbnailer.downsampleForOCR(imageData) ?? imageData

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.isEmpty ? nil : lines.joined(separator: "\n"))
            }
            // .accurate over .fast: this runs off the interactive path on a queue of one, so the
            // extra time costs the user nothing, and screenshots of UI text are exactly the case
            // where .fast misreads.
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            do {
                try VNImageRequestHandler(data: prepared, options: [:]).perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
