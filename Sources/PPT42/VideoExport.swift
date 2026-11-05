import AppKit
import AVFoundation
import Kit42
import UniformTypeIdentifiers

/// File › Export as Movie: the show as an H.264 .mp4 — each slide for its timing (or a fixed time), animation steps,
/// cross-fades for transitions.
enum VideoExport {
    struct Options {
        var width = 1920
        var secondsPerSlide: Double = 5
        var secondsPerStep: Double = 1.5
        var fps: Int32 = 30
        var includeHidden = false
    }

    enum Failure: LocalizedError {
        case writer(String)
        var errorDescription: String? {
            switch self { case .writer(let message): return message }
        }
    }

    static func export(_ deck: Deck, to url: URL, options o: Options = Options(), progress: ((Double) -> Void)? = nil) throws {
        guard o.width >= 2, o.width <= 16_384, o.fps > 0, o.fps <= 240,
              deck.size.width.isFinite, deck.size.width > 0, deck.size.height.isFinite, deck.size.height > 0,
              o.secondsPerSlide.isFinite, o.secondsPerSlide > 0, o.secondsPerStep.isFinite, o.secondsPerStep > 0,
              o.secondsPerSlide < Double(Int64.max) / 600, o.secondsPerStep < Double(Int64.max) / 600 else {
            throw Failure.writer("Invalid movie dimensions or timing")
        }
        let w = o.width - o.width % 2
        let height = (Double(w) * deck.size.height / deck.size.width).rounded()
        guard height.isFinite, height >= 2, height <= 16_384, Double(w) * height <= 64_000_000 else { throw Failure.writer("Invalid movie height") }
        let h = Int(height) / 2 * 2
        let slides = deck.slides.indices.filter { o.includeHidden || !deck.slides[$0].hidden }
        guard !slides.isEmpty else { throw Failure.writer("No visible slides to export") }
        guard slides.allSatisfy({ i in
            let transition = deck.slides[i].transition
            return transition.duration.isFinite && transition.duration >= 0 &&
                (transition.advanceAfter.map { $0.isFinite && $0 >= 0 && $0 < Double(Int64.max) / 600 } ?? true)
        }) else { throw Failure.writer("Invalid movie dimensions or timing") }
        // Publish only a finished movie. Failed exports must leave an existing destination intact.
        let movie = url.pathExtension.lowercased() == "mov"
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".PPT42-\(UUID().uuidString)." + (movie ? "mov" : "mp4"))
        defer { try? FileManager.default.removeItem(at: temporary) }
        let writer = try AVAssetWriter(outputURL: temporary, fileType: movie ? .mov : .mp4)
        defer { if writer.status == .writing { writer.cancelWriting() } }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: Double(w) * Double(h) * 4],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ])
        guard writer.canAdd(input) else { throw Failure.writer("input") }
        writer.add(input)
        guard writer.startWriting() else { throw Failure.writer(writer.error?.localizedDescription ?? "start") }
        writer.startSession(atSourceTime: .zero)

        // Frames: (image, seconds shown), with cross-fades between slides that have a transition.
        var t = 0.0
        let frame = 1.0 / Double(o.fps)
        func append(_ img: CGImage, at time: Double) throws {
            guard time.isFinite, time >= 0, time < Double(Int64.max) / 600 else { throw Failure.writer("Invalid movie dimensions or timing") }
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else { throw Failure.writer(writer.error?.localizedDescription ?? "write") }
                Thread.sleep(forTimeInterval: 0.005)
            }
            guard let pool = adaptor.pixelBufferPool else { throw Failure.writer("pool") }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let pb else { throw Failure.writer("buffer") }
            CVPixelBufferLockBaseAddress(pb, [])
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) {
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            guard adaptor.append(pb, withPresentationTime: CMTime(seconds: time, preferredTimescale: 600)) else {
                throw Failure.writer(writer.error?.localizedDescription ?? "frame")
            }
        }
        func blend(_ a: CGImage, _ b: CGImage, _ k: CGFloat) -> CGImage? {
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            let r = CGRect(x: 0, y: 0, width: w, height: h)
            ctx.draw(a, in: r)
            ctx.setAlpha(k)
            ctx.draw(b, in: r)
            return ctx.makeImage()
        }
        var previous: CGImage?
        for (n, i) in slides.enumerated() {
            let s = deck.slides[i]
            let groups = AnimationTimeline(s.animations).groups.count
            var opts = RenderOptions()
            opts.number = Renderer.number(of: i, deck: deck)
            for g in 0...groups {
                guard let img = Renderer.image(s.animated(after: g, size: deck.size), deck: deck, pixelWidth: w, options: opts) else { throw Failure.writer("Could not render the slide") }
                if g == 0, let prev = previous, s.transition.kind != .none {
                    let d = max(0.2, min(2, s.transition.duration))
                    var k = 0.0
                    while k < d {
                        if let f = blend(prev, img, CGFloat(k / d)) { try append(f, at: t) }
                        t += frame; k += frame
                    }
                }
                try append(img, at: t)
                let hold = g < groups ? o.secondsPerStep : (s.transition.advanceAfter ?? o.secondsPerSlide)
                t += max(frame, hold)
                previous = img
            }
            progress?(Double(n + 1) / Double(max(1, slides.count)))
        }
        if let last = previous { try append(last, at: max(0, t - frame)) }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed { throw Failure.writer(writer.error?.localizedDescription ?? "finish") }
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }
}

extension DeckWindowController {
    @objc func exportMovieAction(_ sender: Any?) {
        guard let window else { return }
        commitEditing()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = ((doc?.displayName ?? L("Untitled")) as NSString).deletingPathExtension + ".mp4"
        let seconds = NSTextField(string: "5")
        seconds.translatesAutoresizingMaskIntoConstraints = false
        seconds.widthAnchor.constraint(equalToConstant: 50).isActive = true
        let size = NSPopUpButton()
        size.addItems(withTitles: ["1280 × 720", "1920 × 1080", "3840 × 2160"])
        size.selectItem(at: 1)
        let row = NSStackView(views: [NSTextField(labelWithString: L("Seconds per slide:")), seconds, NSTextField(labelWithString: L("Size:")), size])
        row.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        panel.accessoryView = row
        let deck = self.deck
        panel.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let url = panel.url else { return }
            var o = VideoExport.Options()
            o.secondsPerSlide = max(0.5, Double(seconds.stringValue.replacingOccurrences(of: ",", with: ".")) ?? 5)
            o.width = [1280, 1920, 3840][max(0, size.indexOfSelectedItem)]
            self?.banner.show(.info, L("Exporting the movie…"))
            // Rendering shares caches with the window: on the main thread, after the banner is drawn.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                let result = Result { try VideoExport.export(deck, to: url, options: o) }
                self?.banner.hide()
                if case .failure(let e) = result { NSAlert(error: e).beginSheetModal(for: window) }
            }
        }
    }
}
