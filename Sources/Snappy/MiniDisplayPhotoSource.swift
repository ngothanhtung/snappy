import AppKit
import Photos

/// A photo album the slideshow can use.
struct MiniDisplayPhotoAlbum: Identifiable, Hashable {
    /// PhotoKit local identifier; empty for the whole library.
    let id: String
    let title: String
    let count: Int

    static let allPhotosID = ""
}

/// Shape of the photo card (width:height). The card is always full height.
struct MiniDisplayPhotoAspect: Hashable, Identifiable {
    let w: Int
    let h: Int
    var id: String { "\(w):\(h)" }
    var ratio: CGFloat { CGFloat(w) / CGFloat(h) }

    static let all: [MiniDisplayPhotoAspect] = [
        .init(w: 16, h: 9), .init(w: 3, h: 2), .init(w: 7, h: 5), .init(w: 4, h: 3),
        .init(w: 5, h: 4), .init(w: 1, h: 1), .init(w: 4, h: 5), .init(w: 3, h: 4),
    ]
    static let standard = MiniDisplayPhotoAspect(w: 4, h: 3)

    init(w: Int, h: Int) { self.w = w; self.h = h }

    /// Parses "16:9"; nil if not one of `all`.
    init?(_ s: String) {
        guard let a = Self.all.first(where: { $0.id == s }) else { return nil }
        self = a
    }
}

/// What the photo card shows: the current photo, and during a change the
/// previous one with the crossfade progress (0 → 1).
struct MiniDisplayPhotoFrame {
    var image: CGImage?
    var previous: CGImage?
    var progress: Double
    var aspect: CGFloat = MiniDisplayPhotoAspect.standard.ratio
    var isTransitioning: Bool { progress < 1 }
}

/// Slideshow of the user's macOS Photos library (or one album) for the mini
/// display's photo panel: picks a random still image every `interval` seconds
/// via PhotoKit, crossfades to it, and keeps the frame ready for the engine thread.
@MainActor
final class MiniDisplayPhotoSource {
    /// Current photo + transition; read from the engine thread.
    let current = ImageBox()

    /// What went wrong, for the menu/settings (nil when fine).
    private(set) var problem: String?
    var onChange: (() -> Void)?

    /// Seconds between photos. Changing it restarts the timer.
    var interval: TimeInterval = 15 {
        didSet { if isRunning { scheduleTimer() } }
    }

    /// Album to show (`MiniDisplayPhotoAlbum.allPhotosID` for the whole library).
    var albumID = MiniDisplayPhotoAlbum.allPhotosID {
        didSet { if isRunning, albumID != oldValue { load() } }
    }

    /// Card shape; sets the requested image size too.
    var aspect = MiniDisplayPhotoAspect.standard {
        didSet { current.setAspect(aspect.ratio) }
    }

    /// The card is 430 px tall and the panel shows pixels 1:1, so ask for the
    /// card's own size. Bigger requests exceed the local derivatives (~1024 px)
    /// and force a cloud-only original download, which fails.
    private var targetSize: CGSize { CGSize(width: (430 * aspect.ratio).rounded(), height: 430) }
    private var assets: PHFetchResult<PHAsset>?
    private var timer: Timer?
    private var request: PHImageRequestID?
    private var recent: [Int] = []
    /// Indices whose original is not on this Mac (cloud-only); skipped from then on.
    private var unavailable = Set<Int>()

    var isRunning: Bool { timer != nil }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.showNext() }
        }
    }

    func start() {
        guard timer == nil else { return }
        scheduleTimer()
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited:
            load()
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.load() }
                }
            }
        default:
            report("No access to Photos")
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let request { PHImageManager.default().cancelImageRequest(request) }
        request = nil
        assets = nil
        current.set(nil)
        report(nil)
    }

    private func load() {
        guard isRunning else { return }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            report("No access to Photos")
            return
        }
        let opts = Self.imagesOnly()
        var result = PHAsset.fetchAssets(with: opts)
        var name = "All Photos"
        if !albumID.isEmpty {
            if let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil)
                .firstObject {
                result = PHAsset.fetchAssets(in: album, options: opts)
                name = album.localizedTitle ?? "album"
            } else {
                MiniDisplayLog.log("photos: album \(albumID) not found, using All Photos")
            }
        }
        assets = result
        unavailable.removeAll()
        recent.removeAll()
        MiniDisplayLog.log("photos: \(name): \(result.count) images")
        guard result.count > 0 else {
            report(albumID.isEmpty ? "Photos library is empty" : "Album has no photos")
            return
        }
        report(nil)
        showNext()
    }

    /// Picks a random photo that is stored on this Mac. With "Optimize Mac
    /// Storage" most originals live only in iCloud, and PhotoKit fails to fetch
    /// them for us (PHPhotosErrorDomain 3164 locally, CloudPhotoLibrary 1005 with
    /// network access), so cloud-only photos are skipped and remembered.
    private func showNext(attempt: Int = 0) {
        guard let assets, assets.count > 0 else { return }
        guard unavailable.count < assets.count else {
            report("No photos stored on this Mac")
            return
        }
        var i = Int.random(in: 0..<assets.count)
        let avoid = min(assets.count - unavailable.count - 1, 20)
        while unavailable.contains(i) || recent.suffix(max(0, avoid)).contains(i) {
            i = Int.random(in: 0..<assets.count)
        }

        let opts = PHImageRequestOptions()
        opts.deliveryMode = .highQualityFormat
        opts.resizeMode = .fast
        opts.isNetworkAccessAllowed = false
        opts.isSynchronous = false
        if let request { PHImageManager.default().cancelImageRequest(request) }
        request = PHImageManager.default().requestImage(
            for: assets.object(at: i), targetSize: targetSize, contentMode: .aspectFill, options: opts
        ) { [weak self] image, info in
            let cancelled = (info?[PHImageCancelledKey] as? Bool) == true
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
            let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isRunning, !cancelled, !degraded else { return }
                    if let cg {
                        self.recent.append(i)
                        if self.recent.count > 40 { self.recent.removeFirst(self.recent.count - 40) }
                        self.current.set(cg)
                        self.report(nil)
                        if attempt > 0 {
                            MiniDisplayLog.log("photos: showing \(cg.width)x\(cg.height) "
                                               + "after skipping \(attempt) cloud-only")
                        }
                    } else {
                        self.unavailable.insert(i)
                        // Keep looking right away; keep the current photo meanwhile.
                        if attempt < 60 { self.showNext(attempt: attempt + 1) }
                        else if self.current.get() == nil { self.report("Photos are only in iCloud") }
                    }
                }
            }
        }
    }

    private static func imagesOnly() -> PHFetchOptions {
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        return opts
    }

    /// Albums with at least one photo: All Photos, then smart albums
    /// (Favorites, Selfies, …), then the user's own albums, by name.
    static func albums() -> [MiniDisplayPhotoAlbum] {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return [] }
        let opts = imagesOnly()
        var list = [MiniDisplayPhotoAlbum(id: MiniDisplayPhotoAlbum.allPhotosID, title: "All Photos",
                                          count: PHAsset.fetchAssets(with: opts).count)]
        func collect(_ type: PHAssetCollectionType) -> [MiniDisplayPhotoAlbum] {
            var out: [MiniDisplayPhotoAlbum] = []
            PHAssetCollection.fetchAssetCollections(with: type, subtype: .any, options: nil)
                .enumerateObjects { c, _, _ in
                    guard c.assetCollectionSubtype != .smartAlbumAllHidden,
                          c.assetCollectionSubtype != .smartAlbumUserLibrary else { return }
                    let n = PHAsset.fetchAssets(in: c, options: opts).count
                    if n > 0 { out.append(.init(id: c.localIdentifier, title: c.localizedTitle ?? "Untitled", count: n)) }
                }
            return out.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
        list += collect(.smartAlbum)
        list += collect(.album)
        return list
    }

    private func report(_ p: String?) {
        guard p != problem else { return }
        problem = p
        if let p { MiniDisplayLog.log("photos: \(p)") }
        onChange?()
    }

    /// Thread-safe holder of the current and previous photo plus the time of
    /// the last change, so the engine can crossfade without touching the main actor.
    final class ImageBox: @unchecked Sendable {
        static let transition: TimeInterval = 1.0

        private let lock = NSLock()
        private var image: CGImage?
        private var previous: CGImage?
        private var changedAt = Date.distantPast
        private var aspect = MiniDisplayPhotoAspect.standard.ratio

        func setAspect(_ a: CGFloat) { lock.lock(); aspect = a; lock.unlock() }

        func set(_ img: CGImage?) {
            lock.lock()
            defer { lock.unlock() }
            previous = img == nil ? nil : image
            image = img
            changedAt = img == nil ? .distantPast : Date()
        }

        func get() -> CGImage? { lock.lock(); defer { lock.unlock() }; return image }

        func frame(at now: Date = Date()) -> MiniDisplayPhotoFrame {
            lock.lock()
            defer { lock.unlock() }
            let t = now.timeIntervalSince(changedAt) / Self.transition
            let progress = min(1, max(0, t))
            return MiniDisplayPhotoFrame(image: image, previous: progress < 1 ? previous : nil,
                                         progress: progress, aspect: aspect)
        }
    }
}
