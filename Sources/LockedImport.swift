// Crepuscule - LockedImport.swift
// Constantin Clerc (c22dev) - 0.1
import Foundation
import LockedCameraCapture

@MainActor
enum LockedImport {
    static func importAll(into library: Library, camera: CameraModel) async {
        let manager = LockedCameraCaptureManager.shared
        for folder in manager.sessionContentURLs {
            if importSession(folder, into: library, camera: camera) { try? await manager.invalidateSessionContent(at: folder) }
        }
    }

    private static func importSession(_ folder: URL, into library: Library, camera: CameraModel) -> Bool {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        let shots = names.filter { $0.hasSuffix(LockedShot.suffix) }.compactMap { name -> (URL, LockedShot)? in
            let url = folder.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url), let shot = try? JSONDecoder().decode(LockedShot.self, from: data) else { return nil }
            return (url, shot)
        }.sorted { $0.1.created < $1.1.created }
        var clean = true
        for (manifest, shot) in shots {
            do {
                if let job = try library.file(lockedShot: shot, in: folder) { camera.runAfterCapture(job) }
                try? fm.removeItem(at: manifest)
            } catch {
                clean = false
                camera.notice = error.localizedDescription
            }
        }
        return clean
    }
}

extension Library {
    func file(lockedShot shot: LockedShot, in folder: URL) throws -> (() async throws -> Void)? {
        let item = try ingest(base: folder.appendingPathComponent(shot.base),
                              frames: shot.frames.map { (folder.appendingPathComponent($0.name), $0.scale) },
                              blur: shot.blur, bias: shot.bias ?? 0,
                              aspect: shot.aspect.flatMap(AspectRatioPreset.init(rawValue:)) ?? settings.aspectRatioPreset,
                              tag: shot.tag, cropFactor: shot.cropFactor ?? 1, night: shot.night == true,
                              look: shot.look.flatMap { try? JSONDecoder().decode(Grade.self, from: $0) })
        guard settings.autoExport else { return nil }
        return { [self] in _ = try await saveToPhotos(item) }
    }
}
