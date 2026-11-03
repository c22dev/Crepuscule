// Crepuscule - CrepusculeApp.swift
// Constantin Clerc (c22dev) - 0.1
import Crepuscule
import LockedCameraCapture
import SwiftUI
import UIKit

@main
struct CrepusculeApp: App {
    var body: some Scene {
        WindowGroup {
            RootView().preferredColorScheme(.dark).tint(Ink.dusk)
        }
    }
}

struct RootView: View {
    @State private var library: Library
    @State private var camera: CameraModel
    @State private var libraryOpen = false
    @State private var settingsOpen = ProcessInfo.processInfo.arguments.contains("-demoSettings")
    @State private var introOpen = !UserDefaults.standard.bool(forKey: IntroductionView.shownKey)
        && !ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("-demo") }
    @Environment(\.scenePhase) private var phase
    @Namespace private var hero
    private let router = IntentRouter.shared

    init() {
        let l = Library()
        _library = State(initialValue: l)
        _camera = State(initialValue: CameraModel(store: l))
    }

    var body: some View {
        CameraView(model: camera, thumbnail: AnyView(NewestPhotoButton(library: library, hero: hero, action: { libraryOpen = true })), captureEnabled: !libraryOpen && !settingsOpen && !introOpen, openSettings: { settingsOpen = true })
            .statusBarHidden(true)
            .task {
                #if targetEnvironment(simulator)
                DemoSeed.requestIntents(router)
                async let started: Void = camera.start()
                await DemoSeed.apply(library: library, camera: camera) { libraryOpen = true }
                await started
                #else
                await camera.start()
                #endif
                Task.detached(priority: .utility) {
                    ShaderWarmup.mergeKernels()
                    await RenderEngine.shared.prewarm()
                    await DetailEngine.shared.prewarm()
                }
            }
            .task {
                for await _ in LockedCameraCaptureManager.shared.sessionContentUpdates where UIApplication.shared.applicationState == .active {
                    await LockedImport.importAll(into: library, camera: camera)
                }
            }
            .onChange(of: router.pending) { drain() }
            .onChange(of: camera.phase) { drain() }
            .onContinueUserActivity(NSUserActivityTypeLockedCameraCapture) { _ in
                Task {
                    await LockedImport.importAll(into: library, camera: camera)
                    router.request(.library)
                }
            }
            .onChange(of: phase) { _, new in
                switch new {
                case .active:
                    if !libraryOpen, camera.phase == .running { camera.resume() }
                    Task {
                        await LockedImport.importAll(into: library, camera: camera)
                        await library.retryStaleThumbnails()
                    }
                    drain()
                case .background: camera.pause()
                default: break
                }
            }
            .onChange(of: libraryOpen) { _, open in
                if camera.phase == .running { if open { camera.pause() } else { camera.resume() } }
            }
            .sheet(isPresented: $settingsOpen) { SettingsScreen(library: library, camera: camera) }
            .onChange(of: settingsOpen) { _, open in if !open { camera.refreshSettings() } }
            .fullScreenCover(isPresented: $libraryOpen) {
                LibraryScreen(library: library, openNewest: DemoFlags.openGrid ? false : true) { libraryOpen = false }
                    .navigationTransition(.zoom(sourceID: NewestPhotoButton.heroID, in: hero))
            }
            .fullScreenCover(isPresented: $introOpen) { IntroductionView { introOpen = false } }
    }

    private func drain() {
        guard phase == .active, camera.phase != .starting else { return }
        while let action = router.take() {
            switch action {
            case .camera:
                libraryOpen = false
                settingsOpen = false
                introOpen = false
            case .shoot(let drive, let timer):
                libraryOpen = false
                settingsOpen = false
                introOpen = false
                camera.shootWhenReady(drive: drive, timer: timer)
            case .library:
                settingsOpen = false
                introOpen = false
                libraryOpen = true
            case .look(let name):
                libraryOpen = false
                settingsOpen = false
                introOpen = false
                if let look = camera.looks.first(where: { $0.name == name }) { camera.chooseLook(look.grade) }
            }
        }
    }
}

enum DemoFlags {
    static var openGrid: Bool { ProcessInfo.processInfo.arguments.contains("-demoGrid") }
    static var openEditor: Bool { ProcessInfo.processInfo.arguments.contains("-demoEdit") }
}
