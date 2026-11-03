// Crepuscule - LockedCaptureExtension.swift
// Constantin Clerc (c22dev) - 0.1
import AVFoundation
import AVKit
import Crepuscule
import ExtensionKit
import LockedCameraCapture
import Observation
import SwiftUI

@main
struct CrepusculeLockedCapture: LockedCameraCaptureExtension {
    var body: some LockedCameraCaptureExtensionScene {
        LockedCameraCaptureUIScene { session in
            LockedCameraView(model: LockedCameraModel(session: session))
        }
    }
}

@MainActor @Observable
final class LockedCameraModel {
    enum Phase { case starting, running, needsApp, failed }

    private(set) var phase = Phase.starting
    private(set) var shots = 0
    private(set) var firing = false
    private(set) var blink = false
    private(set) var backLens: [CameraLens] = []
    private(set) var active: CameraLens?
    private(set) var muted = false
    private let lockedSession: LockedCameraCaptureSession
    private let capture: CameraCapture
    private var rotation: AVCaptureDevice.RotationCoordinator?
    var previewLayer: AVCaptureVideoPreviewLayer?

    var session: AVCaptureSession { capture.session }

    init(session: LockedCameraCaptureSession) {
        lockedSession = session
        capture = CameraCapture(directory: session.sessionContentURL)
    }

    func start() async {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { phase = .needsApp; return }
        let context = (try? await CrepusculeCaptureIntent.appContext) ?? LockedCaptureContext()
        capture.burstEnabled = context.stack
        capture.muteShutter = context.muteShutter
        capture.nightBursts = context.nightBursts
        capture.highlightRetentionStops = context.highlightRetentionStops
        muted = context.muteShutter
        do {
            try await capture.configure()
            capture.setShutterLimit(context.shutterLimit > 0 ? context.shutterLimit : nil)
            capture.start()
            backLens = CameraCapture.availableLenses().filter { $0.facing == .back && $0.cropFactor == 1 }
            active = backLens.first { $0.id == capture.activeDevice?.uniqueID }
            attachRotation()
            phase = .running
        } catch { phase = .failed }
    }

    func stop() { capture.stop() }

    func cycleLens() {
        guard !firing, backLens.count > 1, let active, let i = backLens.firstIndex(of: active) else { return }
        let next = backLens[(i + 1) % backLens.count]
        Task {
            guard (try? await capture.select(lens: next)) != nil else { return }
            self.active = next
            attachRotation()
        }
    }

    func shoot() {
        guard !firing, phase == .running else { return }
        firing = true
        let angle = rotation?.videoRotationAngleForHorizonLevelCapture
        Task {
            defer { firing = false }
            flashScreen()
            guard let results = try? await capture.runDrive(mode: .single, timer: .off, rotationAngle: angle, progress: { _ in }) else { return }
            for r in results where (try? write(r)) != nil { shots += 1 }
        }
    }

    func openApp() {
        Task { try? await lockedSession.openApplication(for: NSUserActivity(activityType: NSUserActivityTypeLockedCameraCapture)) }
    }

    private func write(_ r: CaptureResult) throws {
        let shot = LockedShot(base: r.baseURL.lastPathComponent,
                              frames: r.frames.map { .init(name: $0.url.lastPathComponent, scale: Float($0.spec?.exposureScale ?? 1)) },
                              blur: r.blurPixels, created: Date())
        let url = lockedSession.sessionContentURL.appendingPathComponent(UUID().uuidString + LockedShot.suffix)
        try JSONEncoder().encode(shot).write(to: url, options: .atomic)
    }

    func attachRotation() {
        rotation = capture.activeDevice.map { AVCaptureDevice.RotationCoordinator(device: $0, previewLayer: previewLayer) }
        if let rotation, let connection = previewLayer?.connection, connection.isVideoRotationAngleSupported(rotation.videoRotationAngleForHorizonLevelPreview) {
            connection.videoRotationAngle = rotation.videoRotationAngleForHorizonLevelPreview
        }
    }

    private func flashScreen() {
        blink = true
        Task {
            try? await Task.sleep(nanoseconds: 70_000_000)
            blink = false
        }
    }
}

struct LockedCameraView: View {
    @State var model: LockedCameraModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch model.phase {
            case .needsApp: message("Crepuscule needs camera access", button: "Open Crepuscule")
            case .failed: message("The camera didn't start", button: "Open Crepuscule")
            case .starting, .running: camera
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .task { await model.start() }
        .onDisappear { model.stop() }
        .onCameraCaptureEvent(isEnabled: model.phase == .running, defaultSoundDisabled: model.muted) { event in
            if event.phase == .ended { model.shoot() }
        }
    }

    private var camera: some View {
        VStack(spacing: 0) {
            LockedPreview(model: model)
                .aspectRatio(3.0 / 4, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 16))
                .overlay { if model.blink { Color.black } }
                .frame(maxHeight: .infinity)
            HStack {
                Button(action: model.openApp) {
                    Text(model.shots == 0 ? "Open" : "\(model.shots)")
                        .font(.system(size: 14, weight: .semibold)).monospacedDigit()
                        .frame(width: 56, height: 56)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel(model.shots == 0 ? "Open Crepuscule" : "\(model.shots) photos, open Crepuscule")
                Spacer()
                Button(action: model.shoot) {
                    Circle().fill(.white).frame(width: 66, height: 66).padding(5)
                        .overlay { Circle().stroke(.white, lineWidth: 3) }
                        .opacity(model.firing ? 0.5 : 1)
                }
                .buttonStyle(.plain)
                .disabled(model.phase != .running)
                .accessibilityLabel("Take Photo")
                Spacer()
                Button(action: model.cycleLens) {
                    Text(model.active.map { "\($0.focalLength)" } ?? "")
                        .font(.system(size: 14, weight: .semibold)).monospacedDigit()
                        .frame(width: 56, height: 56)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .opacity(model.backLens.count > 1 ? 1 : 0)
                .accessibilityLabel("Lens \(model.active?.focalLength ?? 0) millimetres")
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
        }
    }

    private func message(_ text: String, button: String) -> some View {
        VStack(spacing: 16) {
            Text(text).font(.headline)
            Button(button, action: model.openApp).buttonStyle(.glass)
        }
    }
}

private struct LockedPreview: UIViewRepresentable {
    let model: LockedCameraModel

    final class Surface: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> Surface {
        let view = Surface()
        view.preview.videoGravity = .resizeAspectFill
        view.preview.session = model.session
        model.previewLayer = view.preview
        model.attachRotation()
        return view
    }
    func updateUIView(_ view: Surface, context: Context) {}
}
