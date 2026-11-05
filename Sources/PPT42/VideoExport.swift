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

    enum Failure: Error { case writer(String) }

    static func export(_ deck: Deck, to url: URL, options o: Options = Options(), progress: ((Double) -> Void)? = nil) throws {
        try? FileManager.default.removeItem(at: url)
        let w = o.width - o.width % 2
        let h = Int((Double(w) * deck.size.height / deck.size.width).rounded()) / 2 * 2
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: w * h * 4],
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
        let slides = deck.slides.indices.filter { o.includeHidden || !deck.slides[$0].hidden }
        var t = 0.0
        let frame = 1.0 / Double(o.fps)
        func append(_ img: CGImage, at time: Double) throws {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
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
            adaptor.append(pb, withPresentationTime: CMTime(seconds: time, preferredTimescale: 600))
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
                guard let img = Renderer.image(s.animated(after: g, size: deck.size), deck: deck, pixelWidth: w, options: opts) else { continue }
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
    }
}

extension DeckWindowController {
    @objc func exportMovieAction(_ sender: Any?) {
        guard let window else { return }
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
