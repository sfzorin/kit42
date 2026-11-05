import AppKit
import AVFoundation
import Kit42
import UniformTypeIdentifiers

/// A video or audio clip on a slide (the object is a picture showing its poster frame).
struct MediaClip: Equatable {
    /// Name in Deck.media.
    var media: String
    var audio = false
    var autoplay = false
    var loop = false

    var ext: String { (media as NSString).pathExtension.lowercased() }

    static func mime(_ ext: String) -> String {
        switch ext.lowercased() {
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "m4a": return "audio/mp4"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "aac": return "audio/aac"
        default: return "application/octet-stream"
        }
    }

    static func isAudio(_ ext: String) -> Bool { ["m4a", "mp3", "wav", "aac", "aif", "aiff"].contains(ext.lowercased()) }
}

enum MediaFiles {
    /// A temporary file for a clip (AVPlayer plays URLs); removed when the app quits.
    static func url(_ name: String, data: Data) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PPT42-media-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(abs(data.count ^ data.prefix(64).hashValue))-\(name)")
        if !FileManager.default.fileExists(atPath: url.path) {
            do { try data.write(to: url) } catch { return nil }
        }
        return url
    }

    static func cleanUp() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PPT42-media-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: dir)
    }

    /// Picture shown for audio clips.
    static func audioPoster() -> Data? {
        let size = NSSize(width: 256, height: 256)
        let img = NSImage(size: size, flipped: false) { r in
            NSColor(srgbRed: 0.18, green: 0.43, blue: 0.86, alpha: 1).setFill()
            NSBezierPath(roundedRect: r, xRadius: 48, yRadius: 48).fill()
            if let s = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 120, weight: .regular)) {
                let tinted = NSImage(size: s.size, flipped: false) { b in s.draw(in: b); NSColor.white.set(); b.fill(using: .sourceAtop); return true }
                tinted.draw(in: CGRect(x: (r.width - s.size.width) / 2, y: (r.height - s.size.height) / 2, width: s.size.width, height: s.size.height))
            }
            return true
        }
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// The poster frame, waiting for it (a couple of seconds at most).
    static func posterNow(_ url: URL) -> (Data, CGSize)? {
        final class Box: @unchecked Sendable { var value: (Data, CGSize)? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task.detached { box.value = await poster(url); done.signal() }
        _ = done.wait(timeout: .now() + 5)
        return box.value
    }

    /// First frame (at 0.5 s or the start) and natural size of a video.
    static func poster(_ url: URL) async -> (Data, CGSize)? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1920, height: 1920)
        var cg: CGImage?
        if let r = try? await gen.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)) { cg = r.image }
        else if let r = try? await gen.image(at: .zero) { cg = r.image }
        guard let cg, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return nil }
        return (png, CGSize(width: cg.width, height: cg.height))
    }
}

extension Deck {
    /// Unique media name for a clip.
    mutating func addClip(_ data: Data, ext: String) -> String {
        for (k, v) in media where v == data { return k }
        var n = 1
        while media["media\(n).\(ext)"] != nil { n += 1 }
        let name = "media\(n).\(ext)"
        media[name] = data
        return name
    }
}

extension DeckWindowController {
    @objc func insertMediaAction(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .audio, .mpeg4Movie, .quickTimeMovie, .mp3, .mpeg4Audio]
        panel.message = L("Choose a video or audio file")
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let url = panel.url else { return }
            self?.insertMedia(url)
        }
    }

    func insertMedia(_ url: URL, autoplay: Bool = false) {
        guard currentSlide != nil, let data = try? Data(contentsOf: url) else { return }
        let ext = url.pathExtension.lowercased()
        let audio = MediaClip.isAudio(ext)
        do {
            var poster: Data?, size = CGSize(width: 96, height: 96)
            if audio { poster = MediaFiles.audioPoster() } else if let (p, s) = MediaFiles.posterNow(url) { poster = p; size = s }
            if poster == nil { poster = MediaFiles.audioPoster() }
            var d = self.deck
            let clipName = d.addClip(data, ext: ext)
            let posterName = d.addMedia(poster ?? Data(), ext: "png")
            if !audio {
                let k = min(1, self.deck.size.width * 0.6 / max(1, size.width), self.deck.size.height * 0.6 / max(1, size.height))
                size = CGSize(width: size.width * k, height: size.height * k)
            }
            var o = SlideObject(id: 0, kind: .picture, frame: CGRect(x: (self.deck.size.width - size.width) / 2, y: (self.deck.size.height - size.height) / 2, width: size.width, height: size.height))
            o.media = posterName
            o.clip = MediaClip(media: clipName, audio: audio, autoplay: autoplay)
            o.name = url.deletingPathExtension().lastPathComponent
            let media = d.media
            var s = self.displayedSlide
            o.id = s.maxID + 1
            s.objects.append(o)
            let i = self.current
            self.doc?.change(audio ? L("Insert Audio") : L("Insert Video")) { deck in
                deck.media = media
                deck.slides[i] = s
            }
            self.selection = [o.id]
        }
    }
}

/// Video and audio on the slide shown in the slide show.
final class ShowMedia {
    struct Item {
        let id: Int
        let rect: CGRect   // slide coordinates
        let player: AVPlayer
        let layer: AVPlayerLayer?
        let clip: MediaClip
    }
    private(set) var items: [Item] = []
    private var observers: [NSObjectProtocol] = []

    func load(_ slide: Slide, deck: Deck) {
        clear()
        for o in slide.objects {
            guard let clip = o.clip, let data = deck.media[clip.media], let url = MediaFiles.url(clip.media, data: data) else { continue }
            let player = AVPlayer(url: url)
            // Test runs never make a sound.
            if PresentationDocument.testMode { player.isMuted = true; player.volume = 0 }
            var layer: AVPlayerLayer?
            if !clip.audio {
                let l = AVPlayerLayer(player: player)
                l.videoGravity = .resizeAspect
                l.isHidden = true
                layer = l
            }
            if clip.loop {
                observers.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak player] _ in
                    player?.seek(to: .zero); player?.play()
                })
            }
            items.append(Item(id: o.id, rect: o.frame, player: player, layer: layer, clip: clip))
        }
    }

    func attach(to view: NSView, slideRect: CGRect, slideSize: CGSize) {
        let sx = slideRect.width / slideSize.width, sy = slideRect.height / slideSize.height
        for it in items {
            guard let l = it.layer else { continue }
            if l.superlayer == nil { view.layer?.addSublayer(l) }
            // The view is flipped; layer frames follow the view's coordinates.
            l.frame = CGRect(x: slideRect.minX + it.rect.minX * sx, y: slideRect.minY + it.rect.minY * sy, width: it.rect.width * sx, height: it.rect.height * sy)
        }
    }

    func startAutoplay() {
        for it in items where it.clip.autoplay { play(it) }
    }

    func play(_ it: Item) {
        it.layer?.isHidden = false
        it.player.play()
    }

    /// Click in the show: toggles the clip under the point (slide coordinates). Returns false when no clip is there.
    func toggle(at p: CGPoint) -> Bool {
        guard let it = items.last(where: { $0.rect.contains(p) }) else { return false }
        if it.player.rate > 0 { it.player.pause() } else {
            if let item = it.player.currentItem, item.currentTime() >= item.duration, item.duration.isNumeric { it.player.seek(to: .zero) }
            play(it)
        }
        return true
    }

    var isPlaying: Bool { items.contains { $0.player.rate > 0 } }

    func clear() {
        for it in items { it.player.pause(); it.layer?.removeFromSuperlayer() }
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        items = []
    }
}
