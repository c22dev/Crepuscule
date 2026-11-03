// Crepuscule - LockedImport.swift
// Constantin Clerc (c22dev) - 0.1
import Foundation
import LockedCameraCapture

@MainActor
enum LockedImport {
    static func importAll(into camera: CameraModel) async {
        let manager = LockedCameraCaptureManager.shared
        for folder in manager.sessionContentURLs {
            if importSession(folder, into: camera) { try? await manager.invalidateSessionContent(at: folder) }
        }
    }

    private static func importSession(_ folder: URL, into camera: CameraModel) -> Bool {
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
                try camera.file(lockedShot: shot, in: folder)
                try? fm.removeItem(at: manifest)
            } catch {
                clean = false
                camera.notice = error.localizedDescription
            }
        }
        return clean
    }
}
