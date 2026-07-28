import SwiftUI
import SceneKit
import AVFoundation
import UIKit
import Photos

/// Carries a non-Sendable value across an isolation boundary where the
/// surrounding code guarantees single-threaded access.
///
/// Used for exactly one thing here — handing an `AVAssetWriter` into its own
/// completion handler — and deliberately named so that it reads as a claim
/// being made rather than a warning being silenced.
struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Getting the simulation out of the app.
///
/// A still is for a report; a clip is for showing somebody who is not in the
/// room. Both matter because the most persuasive thing this app produces is
/// motion, and motion does not survive a screenshot.
///
/// Frames are captured from the SceneKit view itself rather than by screen
/// recording, so the export has no interface furniture in it and no notch.
@MainActor
final class SceneRecorder: ObservableObject {

    @Published private(set) var isRecording = false
    @Published private(set) var frameCount = 0
    @Published private(set) var lastExportURL: URL?
    @Published private(set) var status: String?

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var displayLink: CADisplayLink?
    private weak var view: SCNView?
    private var startTime: CFTimeInterval = 0
    private let frameRate: Int32 = 30

    // MARK: Still

    /// A single frame, at twice the screen's scale so it holds up in a report.
    func snapshot(_ view: SCNView?) -> UIImage? {
        guard let view else { return nil }
        return view.snapshot()
    }

    func saveSnapshotToPhotos(_ image: UIImage) async -> Bool {
        let authorised = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard authorised == .authorized || authorised == .limited else {
            status = "Photo library access was declined. The image can still be shared."
            return false
        }
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            } completionHandler: { success, _ in
                Task { @MainActor in
                    self.status = success ? "Saved to your photo library."
                                          : "Could not save to the photo library."
                    continuation.resume(returning: success)
                }
            }
        }
    }

    // MARK: Clip

    func startRecording(_ view: SCNView?) {
        guard !isRecording, let view else { return }
        self.view = view
        frameCount = 0
        status = nil

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("seismic-\(UUID().uuidString.prefix(8)).mp4")
        try? FileManager.default.removeItem(at: url)

        // Even dimensions: H.264 will not encode an odd width or height, and a
        // view on a 3x screen very often has one.
        let scale = view.window?.screen.scale ?? 2
        let width = Int((view.bounds.width * scale).rounded() / 2) * 2
        let height = Int((view.bounds.height * scale).rounded() / 2) * 2
        guard width > 0, height > 0 else { return }

        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: width * height * 6,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                ],
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height,
                ])

            guard writer.canAdd(input) else { return }
            writer.add(input)
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)

            self.writer = writer
            self.input = input
            self.adaptor = adaptor
            self.startTime = CACurrentMediaTime()

            let link = CADisplayLink(target: self, selector: #selector(capture))
            link.preferredFramesPerSecond = Int(frameRate)
            link.add(to: .main, forMode: .common)
            displayLink = link

            isRecording = true
            status = "Recording."
            Haptics.shared.play(.actuatorFired)
        } catch {
            status = "Could not start recording."
        }
    }

    @objc private func capture() {
        guard isRecording, let adaptor, let input, input.isReadyForMoreMediaData,
              let view, let pool = adaptor.pixelBufferPool else { return }

        let image = view.snapshot()
        guard let cgImage = image.cgImage else { return }

        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
              let buffer else { return }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return }

        context.draw(cgImage, in: CGRect(x: 0, y: 0,
                                         width: CVPixelBufferGetWidth(buffer),
                                         height: CVPixelBufferGetHeight(buffer)))

        let elapsed = CACurrentMediaTime() - startTime
        let time = CMTime(seconds: elapsed, preferredTimescale: 600)
        adaptor.append(buffer, withPresentationTime: time)
        frameCount += 1

        // A minute is plenty for any earthquake record and stops a forgotten
        // recording from filling the device.
        if elapsed > 60 { stopRecording() }
    }

    func stopRecording() {
        guard isRecording else { return }
        displayLink?.invalidate()
        displayLink = nil
        isRecording = false

        guard let writer, let input else { return }
        input.markAsFinished()
        status = "Finishing the clip…"

        // `AVAssetWriter` is not Sendable and `finishWriting`'s handler is
        // `@Sendable`, so the writer travels in an explicit box: it is touched
        // only inside its own completion callback, which AVFoundation
        // serialises, and only two plain values cross back to the main actor.
        let url = writer.outputURL
        let box = UncheckedBox(writer)

        writer.finishWriting {
            let succeeded = box.value.status == .completed
            Task { @MainActor [weak self] in
                guard let self else { return }
                if succeeded {
                    self.lastExportURL = url
                    self.status = "Clip ready — \(self.frameCount) frames."
                    Haptics.shared.play(.assessmentComplete)
                } else {
                    self.status = "The clip could not be written."
                }
                self.writer = nil
                self.input = nil
                self.adaptor = nil
            }
        }
    }

    func saveClipToPhotos() async {
        guard let url = lastExportURL else { return }
        let authorised = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard authorised == .authorized || authorised == .limited else {
            status = "Photo library access was declined. The clip can still be shared."
            return
        }
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { success, _ in
                Task { @MainActor in
                    self.status = success ? "Saved to your photo library."
                                          : "Could not save the clip."
                    continuation.resume()
                }
            }
        }
    }
}
