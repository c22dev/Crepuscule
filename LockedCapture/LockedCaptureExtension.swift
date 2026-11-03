// Crepuscule - LockedCaptureExtension.swift
// Constantin Clerc (c22dev) - 0.1
import AVFoundation
import ExtensionKit
import LockedCameraCapture
import Observation
import SwiftUI

@main
struct CrepusculeLockedCapture: LockedCameraCaptureExtension {
    var body: some LockedCameraCaptureExtensionScene {
        LockedCameraCaptureUIScene { session in
            LockedRoot(session: session)
        }
    }
}

@MainActor @Observable
final class LockedStore: CameraStore {
    let burstMerge: Bool
    let bracketMetering: CameraCapture.BracketMetering
    let highlightRetentionStops: Double
    var aspectRatioPreset: AspectRatioPreset
    var perImageDefaults: Grade { didSet { lookChosen = true } }
    let allLooks: [(name: String, grade: Grade)]
    private(set) var shots = 0
    // only a look picked here goes with the shot, else the app default applies on import
    private var lookChosen = false
    private let folder: URL

    init(context: LockedCaptureContext, folder: URL) {
        self.folder = folder
        let json = JSONDecoder()
        burstMerge = context.stack
        bracketMetering = context.bracketMetering.flatMap(CameraCapture.BracketMetering.init(rawValue:)) ?? .locked
        highlightRetentionStops = context.highlightRetentionStops
        aspectRatioPreset = context.aspect.flatMap(AspectRatioPreset.init(rawValue:)) ?? .native
        perImageDefaults = context.look.flatMap { try? json.decode(Grade.self, from: $0) } ?? Grade()
        let looks = context.looks.compactMap { l in (try? json.decode(Grade.self, from: l.grade)).map { (name: l.name, grade: $0) } }
        allLooks = looks.isEmpty ? [("Factory", Presets.factoryDefault), ("Mono", Presets.blackAndWhite)] : looks
    }

    func file(_ r: CaptureResult, bias: Float, aspect: AspectRatioPreset, tag: String?, cropFactor: Double, night: Bool) throws -> (() async throws -> Void)? {
        var shot = LockedShot(base: r.baseURL.lastPathComponent,
                              frames: r.frames.map { .init(name: $0.url.lastPathComponent, scale: Float($0.spec?.exposureScale ?? 1)) },
                              blur: r.blurPixels, created: Date(), night: night)
        shot.aspect = aspect.rawValue
        shot.cropFactor = cropFactor
        shot.bias = bias
        shot.tag = tag
        if lookChosen { shot.look = try? JSONEncoder().encode(perImageDefaults) }
        let url = folder.appendingPathComponent(UUID().uuidString + LockedShot.suffix)
        try JSONEncoder().encode(shot).write(to: url, options: .atomic)
        shots += 1
        return nil
    }

    // the extension has its own UserDefaults, seed them from the app's
    static func seedDefaults(from c: LockedCaptureContext) {
        let d = UserDefaults.standard
        d.set(c.showGrid, forKey: "showGrid")
        d.set(c.showLook, forKey: "showLookInViewfinder")
        d.set(c.shutterLimit, forKey: "shutterLimitDenominator")
        d.set(c.muteShutter, forKey: "muteShutterSound")
        d.set(c.nightBursts, forKey: "nightBursts")
        d.set(false, forKey: "scanCodesInViewfinder")
        d.set(c.defaultLens, forKey: "defaultLens")
        d.set(true, forKey: "lockHintShown")
        d.set(c.vignette, forKey: "appleVignetteAmount")
        if let r = c.lensReadout { d.set(r, forKey: "lensReadout") }
    }
}

struct LockedRoot: View {
    let session: LockedCameraCaptureSession
    @State private var setup: (store: LockedStore, model: CameraModel)?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let setup {
                CameraView(model: setup.model,
                           thumbnail: AnyView(LockedShotsButton(store: setup.store, action: openApp)),
                           captureEnabled: true,
                           openSettings: openApp)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .task {
            let context = (try? await CrepusculeCaptureIntent.appContext) ?? LockedCaptureContext()
            LockedStore.seedDefaults(from: context)
            let store = LockedStore(context: context, folder: session.sessionContentURL)
            let model = CameraModel(store: store, captureDirectory: session.sessionContentURL)
            setup = (store, model)
            await model.start()
        }
        .onDisappear { setup?.model.pause() }
    }

    private func openApp() {
        Task { try? await session.openApplication(for: NSUserActivity(activityType: NSUserActivityTypeLockedCameraCapture)) }
    }
}

private struct LockedShotsButton: View {
    let store: LockedStore
    let action: () -> Void

    var body: some View {
        let shape = ConcentricRectangle(uniformTopCorners: .fixed(Radius.thumb), bottomLeadingCorner: .concentric(minimum: .fixed(Radius.thumb)), bottomTrailingCorner: .fixed(Radius.thumb))
        Button(action: action) {
            ZStack {
                Ink.raised
                if store.shots == 0 {
                    Image(systemName: "photo.on.rectangle").font(.system(size: 20, weight: .medium)).foregroundStyle(Ink.stone)
                } else {
                    Text("\(store.shots)").font(.instrument(20, weight: .semibold)).foregroundStyle(Ink.paper)
                        .contentTransition(.numericText(value: Double(store.shots)))
                }
            }
            .frame(width: 76, height: 76)
            .clipShape(shape)
            .overlay(shape.stroke(Color(white: 0.32), lineWidth: 2.5))
            .contentShape(shape)
            .animation(Motion.snappy, value: store.shots)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(store.shots == 0 ? "Open Crepuscule" : "\(store.shots) photos, open Crepuscule")
    }
}
