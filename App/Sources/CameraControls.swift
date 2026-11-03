// Crepuscule - CameraControls.swift
// Constantin Clerc (c22dev) - 0.1
import AVFoundation
import Crepuscule

final class CameraControls: NSObject, AVCaptureSessionControlsDelegate, @unchecked Sendable {
    struct State: Equatable {
        var bias: Float
        var zoom: Float
        var zoomRange: ClosedRange<Float>?
        var zoomStops: [Float]
        var lensTitles: [String]
        var lens: Int
        var lookTitles: [String]
        var look: Int
        var aspectTitles: [String]
        var aspect: Int
        var driveTitles: [String]
        var drive: Int
        var shutterTitles: [String]
        var shutter: Int
        var isoTitles: [String]
        var iso: Int
        var apertureTitles: [String]
        var aperture: Int
    }
    struct Actions {
        var bias: @MainActor (Float) -> Void
        var zoom: @MainActor (Float) -> Void
        var lens: @MainActor (Int) -> Void
        var look: @MainActor (Int) -> Void
        var aspect: @MainActor (Int) -> Void
        var drive: @MainActor (Int) -> Void
        var shutter: @MainActor (Int) -> Void
        var iso: @MainActor (Int) -> Void
        var aperture: @MainActor (Int) -> Void
        var fullscreen: @MainActor (Bool) -> Void
    }

    private let queue = DispatchQueue(label: "crepuscule.controls")
    // controls reconfigure the session so they go on its queue (deadlocked startup before)
    private let sessionQueue: DispatchQueue
    private let actions: Actions
    private var slider: AVCaptureSlider?
    private var zoomSlider: AVCaptureSlider?
    private var slidZoom: Float?
    private var lens: AVCaptureIndexPicker?
    private var look: AVCaptureIndexPicker?
    private var aspect: AVCaptureIndexPicker?
    private var drive: AVCaptureIndexPicker?
    private var shutter: AVCaptureIndexPicker?
    private var iso: AVCaptureIndexPicker?
    private var aperture: AVCaptureIndexPicker?
    private var titles: [[String]] = []
    private var attached = false
    private var slidBias: Float?

    init(actions: Actions, sessionQueue: DispatchQueue) {
        self.actions = actions
        self.sessionQueue = sessionQueue
    }

    func attach(session: AVCaptureSession, state: State) { update(session: session, state: state) }

    func update(session: AVCaptureSession, state: State) {
        sessionQueue.async { [self] in
            guard session.supportsControls else { return }
            if !attached {
                session.setControlsDelegate(self, queue: queue)
                attached = true
            }
            let wanted = [state.lensTitles, state.lookTitles, state.aspectTitles, state.driveTitles,
                          state.shutterTitles, state.isoTitles, state.apertureTitles,
                          [state.zoomRange.map { "\($0)" } ?? "", state.zoomStops.map { "\($0)" }.joined(separator: ",")]]
            if wanted != titles {
                titles = wanted
                rebuild(session, state)
            }
            queue.async { [self] in setValues(state) }
        }
    }

    private func setValues(_ state: State) {
        if slidBias.map({ abs($0 - state.bias) > 0.001 }) ?? true, let slider, slider.value != state.bias { slider.value = state.bias }
        slidBias = nil
        if slidZoom.map({ abs($0 - state.zoom) > 0.06 }) ?? true, let zoomSlider, let r = state.zoomRange, r.contains(state.zoom), zoomSlider.value != state.zoom {
            zoomSlider.value = state.zoom
        }
        slidZoom = nil
        set(lens, state.lens)
        set(look, state.look)
        set(aspect, state.aspect)
        set(drive, state.drive)
        set(shutter, state.shutter)
        set(iso, state.iso)
        set(aperture, state.aperture)
    }

    private func set(_ picker: AVCaptureIndexPicker?, _ index: Int) {
        if let picker, picker.selectedIndex != index, index >= 0, index < picker.numberOfIndexes { picker.selectedIndex = index }
    }

    private func picker(_ title: String, _ symbol: String, _ items: [String], _ action: @escaping @MainActor (Int) -> Void) -> AVCaptureIndexPicker? {
        guard items.count > 1 else { return nil }
        let p = AVCaptureIndexPicker(title, symbolName: symbol, localizedIndexTitles: items)
        p.setActionQueue(queue) { i in Task { @MainActor in action(i) } }
        return p
    }

    private func rebuild(_ session: AVCaptureSession, _ state: State) {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        for c in session.controls { session.removeControl(c) }
        let s = AVCaptureSlider("Exposure", symbolName: "plusminus.circle", in: -3...3, step: 1.0 / 3)
        s.setActionQueue(queue) { [weak self, actions] v in
            self?.slidBias = v
            Task { @MainActor in actions.bias(v) }
        }
        slider = s
        zoomSlider = state.zoomRange.map { range in
            // own slider bc the system one sets videoZoomFactor (crashes bayer raw)
            let z = AVCaptureSlider("Zoom", symbolName: "plus.magnifyingglass", in: range)
            z.localizedValueFormat = "%.1f×"
            z.prominentValues = state.zoomStops.filter(range.contains)
            z.setActionQueue(queue) { [weak self, actions] v in
                self?.slidZoom = v
                Task { @MainActor in actions.zoom(v) }
            }
            return z
        }
        lens = picker("Lens", "camera.aperture", state.lensTitles, actions.lens)
        look = picker("Look", "camera.filters", state.lookTitles, actions.look)
        aspect = picker("Aspect Ratio", "aspectratio", state.aspectTitles, actions.aspect)
        drive = picker("Drive", "square.stack.3d.down.right", state.driveTitles, actions.drive)
        shutter = picker("Shutter", "timer", state.shutterTitles, actions.shutter)
        iso = picker("ISO", "camera.metering.center.weighted", state.isoTitles, actions.iso)
        aperture = picker("Aperture", "camera.aperture", state.apertureTitles, actions.aperture)
        var room = session.maxControlsCount
        for control in [zoomSlider, s, shutter, iso, aperture, look, aspect, drive, lens].compactMap({ $0 as AVCaptureControl? }) where room > 0 && session.canAddControl(control) {
            session.addControl(control)
            room -= 1
        }
    }

    func sessionControlsDidBecomeActive(_ session: AVCaptureSession) {}
    func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) { Task { @MainActor in actions.fullscreen(true) } }
    func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) { Task { @MainActor in actions.fullscreen(false) } }
    func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) { Task { @MainActor in actions.fullscreen(false) } }
}
