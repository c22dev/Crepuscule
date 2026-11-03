// Crepuscule - Library.swift
// Constantin Clerc (c22dev) - 0.1
import Crepuscule
import ImageIO
import Observation
import Photos
import UIKit

struct PhotoItem: Codable, Identifiable {
    var id = UUID()
    var created = Date()
    var rawName: String
    var extraFrames: [String] = []
    var archivedBase: String?
    var frameScales: [String: Float]?
    var frameBlur: [String: Float]?
    var mergeAlg: Int?
    var captureBias: Float?
    var mergeAttempts: Int?
    var grade: Grade
    var seed = Float.random(in: 0..<1_000_000)
    var number: Int
    var driveTag: String?
    var aspect: AspectRatioPreset = .native
    var cropFactor: Double?
    var superResolved: Bool?
    var nightBurst: Bool?
}

extension PhotoItem {
    var frameCount: Int { max(frameScales?.count ?? 0, extraFrames.count + 1) }
    private var baseFrameCount: Int { frameScales?.values.filter { abs($0 - 1) < 0.001 }.count ?? 0 }
    var isNightBurst: Bool { nightBurst == true || baseFrameCount > 8 }
    var stackSummary: String? {
        guard frameCount > 1 else { return nil }
        var parts: [String] = []
        if isNightBurst { parts.append("Night burst") }
        if superResolved == true { parts.append(parts.isEmpty ? "Super-resolution" : "super-resolution") }
        parts.append("\(frameCount) frames")
        return parts.joined(separator: ", ")
    }
}

struct NamedLook: Codable, Identifiable {
    var id = UUID()
    var name: String
    var grade: Grade
}

enum LibraryError: LocalizedError {
    case notRaw(String)
    var errorDescription: String? {
        switch self { case .notRaw(let n): return "\(n) isn't a RAW file Crepuscule can read." }
    }
}

@MainActor @Observable
final class Library {
    private(set) var items: [PhotoItem] = []
    private(set) var thumbRevision: [UUID: Int] = [:]
    private(set) var looks: [NamedLook] = []
    var settings: AppSettings {
        didSet { try? settings.save() }
    }
    var attachRaw: Bool {
        didSet { UserDefaults.standard.set(attachRaw, forKey: "attachRaw") }
    }
    var captureFrameStack: Bool {
        didSet { UserDefaults.standard.set(captureFrameStack, forKey: "captureFrameStack") }
    }
    var burstMerge: Bool {
        didSet { UserDefaults.standard.set(burstMerge, forKey: "burstMerge") }
    }
    var bracketMetering: CameraCapture.BracketMetering {
        didSet { UserDefaults.standard.set(bracketMetering.rawValue, forKey: "bracketMetering") }
    }
    var appleVignetteAmount: Double {
        didSet {
            UserDefaults.standard.set(appleVignetteAmount, forKey: "appleVignetteAmount")
            let v = appleVignetteAmount
            Task { await RenderEngine.shared.setVignette(v) }
        }
    }
    private(set) var merging: Set<UUID> = []
    private(set) var mergeProgress: [UUID: Double] = [:]
    private(set) var mergeStamp: [UUID: Int] = [:]
    private var mergeWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    private let root: URL
    private var thumbs = NSCache<NSUUID, UIImage>()

    init() {
        root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Library")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var s = AppSettings.load()
        if !UserDefaults.standard.bool(forKey: "exportSizeMatchesOriginal.v1") {
            if s.exportLongSide == nil { s.exportLongSide = AppSettings().exportLongSide; try? s.save() }
            UserDefaults.standard.set(true, forKey: "exportSizeMatchesOriginal.v1")
        }
        settings = s
        attachRaw = UserDefaults.standard.object(forKey: "attachRaw") as? Bool ?? true
        captureFrameStack = UserDefaults.standard.bool(forKey: "captureFrameStack")
        burstMerge = UserDefaults.standard.object(forKey: "burstMerge") as? Bool ?? true
        appleVignetteAmount = UserDefaults.standard.object(forKey: "appleVignetteAmount") as? Double ?? 1
        bracketMetering = UserDefaults.standard.string(forKey: "bracketMetering").flatMap(CameraCapture.BracketMetering.init(rawValue:))
            ?? (UserDefaults.standard.bool(forKey: "bracketClosedLoop") ? .closedLoop : .locked)
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        items = dirs.compactMap { dir in
            guard let d = try? Data(contentsOf: dir.appendingPathComponent("item.json")) else { return nil }
            return try? JSONDecoder().decode(PhotoItem.self, from: d)
        }.sorted { $0.created > $1.created }
        if let d = try? Data(contentsOf: looksURL), let l = try? JSONDecoder().decode([NamedLook].self, from: d) { looks = l }
        Task { @MainActor in
            await self.housekeepMerges()
            try? await Task.sleep(for: .seconds(2))
            await self.rebuildThumbnailsOnce()
        }
    }

    private var looksURL: URL { root.deletingLastPathComponent().appendingPathComponent("looks.json") }
    func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString) }
    func rawURL(_ item: PhotoItem) -> URL { folder(item.id).appendingPathComponent(item.rawName) }
    func thumbURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("thumb.jpg") }
    func item(_ id: UUID) -> PhotoItem? { items.first { $0.id == id } }
    var newest: PhotoItem? { items.first }

    func thumbnail(_ id: UUID) -> UIImage? {
        _ = thumbRevision[id]
        if let t = thumbs.object(forKey: id as NSUUID) { return t }
        guard let t = UIImage(contentsOfFile: thumbURL(id).path) else { return nil }
        thumbs.setObject(t, forKey: id as NSUUID)
        return t
    }

    private func touchThumb(_ id: UUID) {
        thumbs.removeObject(forKey: id as NSUUID)
        thumbRevision[id, default: 0] += 1
    }

    private func persist(_ item: PhotoItem) {
        guard let d = try? JSONEncoder().encode(item) else { return }
        try? d.write(to: folder(item.id).appendingPathComponent("item.json"), options: .atomic)
    }

    // fresh captures on userInitiated (p cores), housekeeping remerges stay utility
    func mergeBurst(_ id: UUID, scales: [String: Float]? = nil, blur: [String: Float]? = nil, bias: Float? = nil, priority: TaskPriority = .utility) {
        guard let i = items.firstIndex(where: { $0.id == id }), !items[i].extraFrames.isEmpty, !merging.contains(id) else { return }
        if let scales { items[i].frameScales = scales }
        if let blur { items[i].frameBlur = blur }
        if let bias { items[i].captureBias = bias }
        items[i].mergeAttempts = (items[i].mergeAttempts ?? 0) + 1
        let item = items[i]
        let raw = rawURL(item), dir = folder(id), keep = captureFrameStack || item.archivedBase != nil
        guard item.mergeAlg == nil || item.archivedBase != nil else { return }
        merging.insert(id)
        persist(item)
        let baseName = item.archivedBase ?? item.rawName
        let s = item.frameScales ?? [:], b = item.frameBlur ?? [:]
        let names = [baseName] + item.extraFrames
        let frames = names.map { (url: dir.appendingPathComponent($0), scale: $0 == baseName ? Float(1) : s[$0] ?? 1) }
        let blurs: [Float?] = names.map { $0 == baseName ? (b[item.rawName] ?? b[baseName]) : b[$0] }
        let captureBias = item.captureBias ?? 0
        let crop = item.cropFactor ?? 1
        let trySuperRes = crop >= BurstZoom.superResCrop && frames.filter({ abs($0.scale - 1) < 0.001 }).count >= 3
        var background = UIBackgroundTaskIdentifier.invalid
        background = UIApplication.shared.beginBackgroundTask(withName: "Burst merge") {
            UIApplication.shared.endBackgroundTask(background)
            background = .invalid
        }
        let release: @MainActor () -> Void = {
            if background != .invalid { UIApplication.shared.endBackgroundTask(background); background = .invalid }
        }
        mergeProgress[id] = 0
        let report: MergeProgress = { p in Task { @MainActor in self.reportProgress(id, p) } }
        Task.detached(priority: priority) {
            let temp = dir.appendingPathComponent("merging.dng")
            var archived = item.archivedBase
            let ok: Bool
            var superRes = false
            do {
                if trySuperRes {
                    do {
                        let base = frames.indices.filter { abs(frames[$0].scale - 1) < 0.001 }
                        try SuperResolution.reconstructFiles(base.map { frames[$0].url }, cropFactor: crop, blurPixels: base.map { blurs[$0] }, progress: report, to: temp)
                        superRes = true
                    } catch {
                        try? FileManager.default.removeItem(at: temp)
                    }
                }
                if !superRes { try BurstMerger.mergeFiles(frames, blurPixels: blurs, exposureBiasStops: captureBias, progress: report, to: temp) }
                if keep, archived == nil {
                    let name = "base_" + item.rawName
                    try FileManager.default.copyItem(at: raw, to: dir.appendingPathComponent(name))
                    archived = name
                }
                _ = try FileManager.default.replaceItemAt(raw, withItemAt: temp)
                ok = true
            } catch {
                try? FileManager.default.removeItem(at: temp)
                ok = false
            }
            await self.finishMerge(id, merged: ok, keepFrames: keep, archived: archived, superResolved: superRes)
            await release()
        }
    }

    func remerge(_ id: UUID) { mergeBurst(id) }

    func canRemerge(_ item: PhotoItem) -> Bool { item.archivedBase != nil && !item.extraFrames.isEmpty }

    func awaitMerge(_ id: UUID) async {
        guard merging.contains(id) else { return }
        await withCheckedContinuation { mergeWaiters[id, default: []].append($0) }
    }

    private func housekeepMerges() async {
        let fm = FileManager.default
        // go by id, a stale index after the await deleted another photos raw
        for id in items.map(\.id) {
            guard !merging.contains(id), let snapshot = item(id) else { continue }
            let dir = folder(id), raw = rawURL(snapshot)
            let marked = await Task.detached(priority: .utility) { (try? DNGMetadata(url: raw))?.burstMerge != nil }.value
            guard !merging.contains(id), let i = items.firstIndex(where: { $0.id == id }) else { continue }
            let archive = "base_" + items[i].rawName
            var changed = false
            if items[i].archivedBase == nil, fm.fileExists(atPath: dir.appendingPathComponent(archive).path), marked {
                items[i].archivedBase = archive; changed = true
            }
            if marked, items[i].mergeAlg == nil {
                items[i].mergeAlg = BurstMerger.algorithmVersion; changed = true
                if items[i].archivedBase == nil {
                    for name in items[i].extraFrames { try? fm.removeItem(at: dir.appendingPathComponent(name)) }
                    items[i].extraFrames = []
                }
            } else if !marked, items[i].mergeAlg != nil {
                items[i].mergeAlg = nil; changed = true
            }
            if changed { persist(items[i]) }
            var known = Set(items[i].extraFrames + [items[i].rawName])
            if let a = items[i].archivedBase { known.insert(a) }
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for f in files where f.pathExtension.lowercased() == "dng" && !known.contains(f.lastPathComponent) && !merging.contains(id) {
                try? fm.removeItem(at: f)
            }
        }
        for dir in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        where UUID(uuidString: dir.lastPathComponent) != nil && !fm.fileExists(atPath: dir.appendingPathComponent("item.json").path) {
            try? fm.removeItem(at: dir)
        }
        let captures = fm.temporaryDirectory.appendingPathComponent("Captures")
        for f in (try? fm.contentsOfDirectory(at: captures, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantFuture
            if Date().timeIntervalSince(date) > 86_400 { try? fm.removeItem(at: f) }
        }
        let resetKey = "mergeAttemptsReset.v1"
        if !UserDefaults.standard.bool(forKey: resetKey) {
            for i in items.indices where items[i].mergeAlg == nil && items[i].mergeAttempts != nil {
                items[i].mergeAttempts = 0
                persist(items[i])
            }
            UserDefaults.standard.set(true, forKey: resetKey)
        }
        for item in items where !item.extraFrames.isEmpty {
            if item.mergeAlg == nil {
                if item.frameScales != nil, (item.mergeAttempts ?? 0) < 3 { mergeBurst(item.id) }
            } else if canRemerge(item), item.mergeAlg != BurstMerger.algorithmVersion {
                remerge(item.id)
            }
        }
    }

    private func reportProgress(_ id: UUID, _ p: Double) {
        guard merging.contains(id), p > mergeProgress[id] ?? 0 else { return }
        mergeProgress[id] = p
    }

    private func finishMerge(_ id: UUID, merged: Bool, keepFrames: Bool, archived: String?, superResolved: Bool = false) async {
        merging.remove(id)
        mergeProgress.removeValue(forKey: id)
        defer { mergeWaiters.removeValue(forKey: id)?.forEach { $0.resume() } }
        guard merged, let i = items.firstIndex(where: { $0.id == id }) else { return }
        mergeStamp[id, default: 0] += 1
        items[i].mergeAlg = BurstMerger.algorithmVersion
        items[i].archivedBase = archived
        if superResolved != (items[i].superResolved ?? false), let size = Self.uprightSize(of: rawURL(items[i])) {
            items[i].grade.cropInsets = items[i].aspect.uprightCropInsets(imageWidth: size.width, imageHeight: size.height,
                                                                          cropFactor: superResolved ? 1 : (items[i].cropFactor ?? 1))
        }
        items[i].superResolved = superResolved ? true : nil
        if !keepFrames {
            for name in items[i].extraFrames + [archived].compactMap({ $0 }) {
                try? FileManager.default.removeItem(at: folder(id).appendingPathComponent(name))
            }
            items[i].extraFrames = []
            items[i].archivedBase = nil
        }
        persist(items[i])
        await RenderEngine.shared.invalidate(rawURL(items[i]))
        await refreshThumbnail(id)
    }

    @discardableResult
    func add(raw source: URL, frames: [URL] = [], aspect: AspectRatioPreset, driveTag: String?, move: Bool = true, cropFactor: Double = 1, nightBurst: Bool = false) throws -> PhotoItem {
        guard let size = Self.uprightSize(of: source) else { throw LibraryError.notRaw(source.lastPathComponent) }
        var grade = settings.perImageDefaults
        grade.cropInsets = aspect.uprightCropInsets(imageWidth: size.width, imageHeight: size.height, cropFactor: cropFactor)
        grade.nightClean = nightBurst ? true : nil
        let number = (items.map(\.number).max() ?? 0) + 1
        var item = PhotoItem(rawName: UUID().uuidString + ".dng", grade: grade, number: number, driveTag: driveTag, aspect: aspect)
        if cropFactor > 1 { item.cropFactor = cropFactor }
        if nightBurst, frames.count > 1 { item.nightBurst = true }
        let fm = FileManager.default
        try fm.createDirectory(at: folder(item.id), withIntermediateDirectories: true)
        if move { try fm.moveItem(at: source, to: rawURL(item)) } else { try fm.copyItem(at: source, to: rawURL(item)) }
        for f in frames where f != source {
            try? fm.moveItem(at: f, to: folder(item.id).appendingPathComponent(f.lastPathComponent))
            item.extraFrames.append(f.lastPathComponent)
        }
        persist(item)
        items.insert(item, at: 0)
        let raw = rawURL(item), thumb = thumbURL(item.id)
        Task.detached(priority: .userInitiated) {
            Self.writeEmbeddedPreview(from: raw, to: thumb)
            await self.touchThumb(item.id)
            await self.refreshThumbnail(item.id)
        }
        return item
    }

    @discardableResult
    func ingest(base: URL, frames: [(url: URL, scale: Float)], blur: [String: Float], bias: Float, aspect: AspectRatioPreset, tag: String?, cropFactor: Double = 1, night: Bool = false) throws -> PhotoItem {
        let item = try add(raw: base, frames: frames.map(\.url), aspect: aspect, driveTag: tag, cropFactor: cropFactor, nightBurst: night)
        if frames.count > 1 {
            var scales: [String: Float] = [:]
            for f in frames { scales[f.url.lastPathComponent] = f.scale }
            var renamed: [String: Float] = [:]
            for (name, px) in blur { renamed[name == base.lastPathComponent ? item.rawName : name] = px }
            mergeBurst(item.id, scales: scales, blur: renamed, bias: bias, priority: .userInitiated)
        }
        return item
    }

    nonisolated static func storedLookNames() -> [String] {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("looks.json")
        let saved = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([NamedLook].self, from: $0) } ?? []
        return builtInLookNames + saved.map(\.name)
    }

    func refreshThumbnail(_ id: UUID) async {
        guard let item = item(id) else { return }
        do {
            try await RenderEngine.shared.writeThumbnail(url: rawURL(item), grade: item.grade, seed: item.seed, to: thumbURL(id), useDisk: settings.useDiskCache)
            staleThumbs.remove(id)
        } catch {
            staleThumbs.insert(id)
        }
        touchThumb(id)
    }

    private var staleThumbs: Set<UUID> = []

    func retryStaleThumbnails() async {
        for id in staleThumbs { await refreshThumbnail(id) }
    }

    private func rebuildThumbnailsOnce() async {
        let key = "thumbnailsRebuilt.v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        for item in items { await refreshThumbnail(item.id) }
        if staleThumbs.isEmpty { UserDefaults.standard.set(true, forKey: key) }
    }

    func setGrade(_ grade: Grade, aspect: AspectRatioPreset, for id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].grade = grade
        items[i].aspect = aspect
        persist(items[i])
        Task { await refreshThumbnail(id) }
    }

    func delete(_ id: UUID) {
        items.removeAll { $0.id == id }
        let files = (try? FileManager.default.contentsOfDirectory(at: folder(id), includingPropertiesForKeys: nil)) ?? []
        try? FileManager.default.removeItem(at: folder(id))
        Task { await RenderEngine.shared.forget(files) }
        touchThumb(id)
    }

    func saveLook(named name: String, grade: Grade) {
        var g = grade
        g.cropInsets = CropInsets(); g.mirrored = false; g.rotationQuarterTurns = 0; g.fineRotationDegrees = 0
        g.nightClean = nil
        looks.append(NamedLook(name: name, grade: g))
        if let d = try? JSONEncoder().encode(looks) { try? d.write(to: looksURL, options: .atomic) }
    }

    @discardableResult
    func saveToPhotos(_ item: PhotoItem) async throws -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw SaveError.denied }
        await awaitMerge(item.id)
        let raw = rawURL(item)
        let file = try await RenderEngine.shared.export(url: raw, grade: item.grade, seed: item.seed, settings: settings)
        defer { try? FileManager.default.removeItem(at: file) }
        if attachRaw {
            do {
                try await Self.addAsset(photo: file, raw: raw)
                return true
            } catch {
                try await Self.addAsset(photo: file, raw: nil)
                return false
            }
        }
        try await Self.addAsset(photo: file, raw: nil)
        return true
    }

    enum SaveError: LocalizedError {
        case denied
        var errorDescription: String? { "Crepuscule isn't allowed to add to Photos. You can change this in Settings." }
    }

    private nonisolated static func addAsset(photo: URL, raw: URL?) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, fileURL: photo, options: nil)
            if let raw { request.addResource(with: .alternatePhoto, fileURL: raw, options: nil) }
        }
    }

    nonisolated static func uprightSize(of url: URL) -> (width: Double, height: Double)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Double, let h = p[kCGImagePropertyPixelHeight] as? Double else { return nil }
        let orientation = p[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? (h, w) : (w, h)
    }

    nonisolated private static func writeEmbeddedPreview(from raw: URL, to file: URL) {
        guard let src = CGImageSourceCreateWithURL(raw as CFURL, nil) else { return }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageIfAbsent: false, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 720]
        guard let t = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary),
              let data = try? ExportEncoder.encode(t, format: .jpeg, quality: 0.8) else { return }
        try? data.write(to: file, options: .atomic)
    }

    nonisolated static func details(of url: URL) -> [(String, String)] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return [] }
        var out: [(String, String)] = []
        let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        if let m = tiff[kCGImagePropertyTIFFModel] as? String { out.append(("Camera", m)) }
        if let l = exif[kCGImagePropertyExifLensModel] as? String { out.append(("Lens", l)) }
        if let f = exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int { out.append(("Focal length", "\(f) mm eq.")) }
        if let a = exif[kCGImagePropertyExifFNumber] as? Double { out.append(("Aperture", String(format: "f/%.1f", a))) }
        if let t = exif[kCGImagePropertyExifExposureTime] as? Double { out.append(("Shutter", ExposureText.shutter(t))) }
        if let i = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { out.append(("ISO", "\(i)")) }
        if let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int { out.append(("Size", "\(w) × \(h)")) }
        if let s = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int {
            out.append(("RAW", ByteCountFormatter.string(fromByteCount: Int64(s), countStyle: .file)))
        }
        return out
    }
}

enum ExposureText {
    static func shutter(_ s: Double) -> String {
        guard s > 0 else { return "—" }
        if s >= 0.3 { return String(format: "%.1f″", s) }
        return "1/\(Int((1 / s).rounded()))"
    }
    static func ev(_ v: Float) -> String { String(format: "%+.1f", v) }
    static func aperture(_ f: Float) -> String { f >= 10 ? String(format: "ƒ/%.0f", f) : String(format: "ƒ/%.1f", f) }
}
