// Crepuscule - CameraModel.swift
// Constantin Clerc (c22dev) - 0.1
import AVFoundation
import Crepuscule
import CoreImage
import Observation
import SwiftUI
import os
import UIKit

enum Startup {
    static let log = Logger(subsystem: "ch.cclerc.crepuscule", category: "startup")
}

protocol CameraBackend: AnyObject {
    var onFrame: ((CVPixelBuffer, String?) -> Void)? { get set }
    var onStats: ((FrameStats) -> Void)? { get set }
    var formatLabel: String { get }
    var previewAngle: CGFloat { get }
    var flashMode: AVCaptureDevice.FlashMode { get set }
    func prepare(preferred: (CameraLens) -> Bool) async throws -> (lenses: [CameraLens], active: CameraLens?)
    func select(_ lens: CameraLens) async throws
    func resume()
    func pause()
    func focus(atViewPoint point: CGPoint, front: Bool)
    func setBias(_ stops: Float)
    func lockExposure(atViewPoint point: CGPoint, front: Bool) async -> Bool
    func unlockExposure()
    func setShutterLimit(_ denominator: Int?)
    func setMuteShutter(_ on: Bool)
    func setNightBursts(_ on: Bool)
    func setCodeScanning(_ on: Bool, onCode: ((String) -> Void)?)
    @discardableResult func setProRAWPreferred(_ on: Bool) async -> Bool
    func setManual(_ m: ManualSettings)
    func manualRange() -> ManualRange?
    func reading() -> ExposureReading?
    func captureAngle() -> CGFloat?
    func heldOrientation() -> UIDeviceOrientation?
    func shoot(mode: DriveMode, timer: SelfTimer, stack: Bool, retention: Double, metering: CameraCapture.BracketMetering, crop: Double, progress: @escaping @Sendable (DriveProgress) -> Void) async throws -> [CaptureResult]
    var captureSession: AVCaptureSession? { get }
    var sessionQueue: DispatchQueue? { get }
}

final class DeviceCameraBackend: CameraBackend {
    private let capture: CameraCapture
    private var rotation: AVCaptureDevice.RotationCoordinator?

    init(directory: URL? = nil) {
        capture = CameraCapture(directory: directory ?? FileManager.default.temporaryDirectory.appendingPathComponent("Captures"))
    }

    var onFrame: ((CVPixelBuffer, String?) -> Void)? {
        get { capture.onFrame }
        set { capture.onFrame = newValue }
    }
    var onStats: ((FrameStats) -> Void)? {
        get { capture.onStats }
        set { capture.onStats = newValue }
    }
    var formatLabel: String { capture.mode == .proRAW ? "PRORAW" : "RAW" }
    var previewAngle: CGFloat { capture.previewAngle }
    var flashMode: AVCaptureDevice.FlashMode {
        get { capture.flashMode }
        set { capture.flashMode = newValue }
    }
    var captureSession: AVCaptureSession? { capture.session }
    var sessionQueue: DispatchQueue? { capture.sessionQueue }

    func prepare(preferred: (CameraLens) -> Bool) async throws -> (lenses: [CameraLens], active: CameraLens?) {
        let wanted = CameraCapture.availableLenses().first(where: preferred)
        try await capture.configure(deviceID: wanted?.deviceID)
        rotation = capture.activeDevice.map { AVCaptureDevice.RotationCoordinator(device: $0, previewLayer: nil) }
        let lenses = CameraCapture.availableLenses()
        let active = wanted.flatMap { w in lenses.first { $0.id == w.id } } ?? lenses.first { $0.id == capture.activeDevice?.uniqueID }
        return (lenses, active)
    }
    func select(_ lens: CameraLens) async throws {
        try await capture.select(lens: lens)
        rotation = capture.activeDevice.map { AVCaptureDevice.RotationCoordinator(device: $0, previewLayer: nil) }
    }
    func resume() { capture.start() }
    func pause() { capture.stop() }
    func focus(atViewPoint p: CGPoint, front: Bool) {
        capture.focus(at: devicePoint(p, front: front))
    }
    func setBias(_ stops: Float) { capture.setExposureBias(stops) }
    private func devicePoint(_ p: CGPoint, front: Bool) -> CGPoint {
        if capture.previewAngle == 0 { return front ? CGPoint(x: 1 - p.x, y: p.y) : p }
        return front ? CGPoint(x: p.y, y: p.x) : CGPoint(x: p.y, y: 1 - p.x)
    }
    func lockExposure(atViewPoint p: CGPoint, front: Bool) async -> Bool { await capture.lockExposure(at: devicePoint(p, front: front)) }
    func unlockExposure() { capture.unlockExposure() }
    func setShutterLimit(_ denominator: Int?) { capture.setShutterLimit(denominator) }
    func setMuteShutter(_ on: Bool) { capture.muteShutter = on }
    func setNightBursts(_ on: Bool) { capture.nightBursts = on }
    func setCodeScanning(_ on: Bool, onCode: ((String) -> Void)?) { capture.onCode = onCode; capture.setCodeScanning(on) }
    @discardableResult func setProRAWPreferred(_ on: Bool) async -> Bool { (try? await capture.setPrefersProRAW(on)) ?? false }
    func setManual(_ m: ManualSettings) { capture.setManual(m) }
    func manualRange() -> ManualRange? { capture.manualRange() }
    func reading() -> ExposureReading? { capture.reading() }
    func captureAngle() -> CGFloat? { capture.gravityCaptureAngle() ?? rotation?.videoRotationAngleForHorizonLevelCapture }
    func heldOrientation() -> UIDeviceOrientation? { capture.motionGate.orientation }
    func shoot(mode: DriveMode, timer: SelfTimer, stack: Bool, retention: Double, metering: CameraCapture.BracketMetering, crop: Double, progress: @escaping @Sendable (DriveProgress) -> Void) async throws -> [CaptureResult] {
        capture.burstEnabled = stack
        capture.bracketMetering = metering
        capture.highlightRetentionStops = retention
        capture.zoomCropFactor = crop
        return try await capture.runDrive(mode: mode, timer: timer, rotationAngle: captureAngle(), progress: progress)
    }
}

struct AmbientGrid {
    static let width = 45, height = 60
    private var values = [Float](repeating: -1, count: 45 * 60 * 3)
    private var pixels = [UInt8](repeating: 255, count: 45 * 60 * 4)
    private var odd = false

    mutating func update(_ buffer: CVPixelBuffer) -> CIImage? {
        odd.toggle()
        guard odd, CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer), row = CVPixelBufferGetBytesPerRow(buffer)
        let cols = Self.width, rows = Self.height
        for cy in 0..<rows { for cx in 0..<cols {
            var sum: (Float, Float, Float) = (0, 0, 0)
            for sy in 0..<4 { for sx in 0..<4 {
                let p = base + ((cy * 8 + 2 * sy + 1) * h / (8 * rows)) * row + ((cx * 8 + 2 * sx + 1) * w / (8 * cols)) * 4
                sum.0 += Float(p[0]); sum.1 += Float(p[1]); sum.2 += Float(p[2])
            } }
            let i = (cy * cols + cx) * 3
            let target = [sum.0 / 16, sum.1 / 16, sum.2 / 16]
            for k in 0..<3 {
                values[i + k] = values[i + k] < 0 ? target[k] : values[i + k] + (target[k] - values[i + k]) * 0.45
                pixels[(cy * cols + cx) * 4 + k] = UInt8(max(min(values[i + k], 255), 0))
            }
        } }
        let image = CIImage(bitmapData: Data(pixels), bytesPerRow: cols * 4, size: CGSize(width: cols, height: rows), format: .BGRA8, colorSpace: nil)
        return image.clampedToExtent().applyingGaussianBlur(sigma: 1.1).cropped(to: image.extent)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.85])
    }
}

final class FramePump: @unchecked Sendable {
    private let queue = DispatchQueue(label: "crepuscule.viewfinder", qos: .userInteractive)
    private let lock = NSLock()
    private var busy = false
    private var grader: LiveGrader?
    private var grade = Grade()
    private var look = true
    // crop from each frame's own camera or a switch shows the new cam with the old crop
    private var targetFocal = 0.0
    private var targetDevice: String?
    private var natives: [String: Double] = [:]
    private var last: (buffer: CVPixelBuffer, device: String?, time: Double)?
    var drawsPlain: Bool {
        get { lock.withLock { plainFeed } }
        set { lock.withLock { plainFeed = newValue } }
    }
    private var plainFeed = true
    private let plain = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    weak var display: ViewfinderDisplay?
    weak var ambientDisplay: ViewfinderDisplay?
    private var ambient = AmbientGrid()

    func configure(grader: LiveGrader?) { lock.withLock { self.grader = grader } }
    func set(natives: [String: Double]) { lock.withLock { self.natives = natives } }

    func set(focal: Double, device: String) {
        let stalled = lock.withLock { () -> (CVPixelBuffer, String?)? in
            targetFocal = focal; targetDevice = device
            guard let last, ProcessInfo.processInfo.systemUptime - last.time > 0.08 else { return nil }
            return (last.buffer, last.device)
        }
        if let stalled { draw(stalled.0, from: stalled.1, remember: false) }
    }

    private func crop(for device: String?) -> Double {
        guard targetFocal > 0, let native = natives[device ?? targetDevice ?? ""] ?? targetDevice.flatMap({ natives[$0] }), native > 0 else { return 1 }
        return max(targetFocal / native, 1)
    }
    func set(grade: Grade, look: Bool) { lock.withLock { self.grade = grade; self.look = look } }

    private static func centre(_ image: CIImage, _ factor: Double) -> CIImage {
        guard factor > 1 else { return image }
        let e = image.extent, f = CGFloat(factor)
        return image.cropped(to: e.insetBy(dx: e.width * (1 - 1 / f) / 2, dy: e.height * (1 - 1 / f) / 2))
    }

    func push(_ buffer: CVPixelBuffer, from device: String?) { draw(buffer, from: device, remember: true) }

    private func draw(_ buffer: CVPixelBuffer, from device: String?, remember: Bool) {
        let claimed = lock.withLock { () -> Bool in
            if busy { return false }
            busy = true
            return true
        }
        guard claimed else { return }
        queue.async { [self] in
            defer { lock.withLock { busy = false } }
            if remember, let ambientDisplay, let image = ambient.update(buffer) { ambientDisplay.show(image) }
            let (g, gradeNow, lookNow, cropNow) = lock.withLock { () -> (LiveGrader?, Grade, Bool, Double) in
                if remember { last = (buffer, device, ProcessInfo.processInfo.systemUptime) }
                return (grader, grade, look, crop(for: device))
            }
            if lookNow, let g, let t = try? g.render(buffer, grade: gradeNow),
               let image = CIImage(mtlTexture: t, options: [.colorSpace: NSNull()]) {
                display?.show(Self.centre(image, cropNow))
            } else if lock.withLock({ plainFeed }) {
                display?.show(Self.centre(CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()]), cropNow))
            }
        }
    }
}

@MainActor @Observable
final class CameraModel {
    enum Phase: Equatable { case starting, running, denied, failed(String) }

    private(set) var phase = Phase.starting
    private(set) var lenses: [CameraLens] = []
    private(set) var active: CameraLens?
    private(set) var switching = false
    private var swapping = false
    private(set) var flips = 0
    private(set) var reading = ExposureReading()
    private(set) var stats = FrameStats()
    private(set) var progress: DriveProgress?
    private(set) var firing = false
    private(set) var flash = false
    private(set) var formatLabel = "RAW"
    private(set) var landscapeHold = false
    // turns glyphs upright, the layout stays portrait like the system camera
    private(set) var glyphTurn: Double = 0
    private(set) var live = false
    private(set) var controlsFullscreen = false
    var drive = DriveMode.single
    var flashMode = AVCaptureDevice.FlashMode.off {
        didSet { backend.flashMode = flashMode }
    }
    var timer = SelfTimer.off
    var aspect: AspectRatioPreset = .native
    var showGrid = UserDefaults.standard.bool(forKey: "showGrid") {
        didSet { UserDefaults.standard.set(showGrid, forKey: "showGrid") }
    }
    var showLook = UserDefaults.standard.object(forKey: "showLookInViewfinder") as? Bool ?? false {
        didSet { UserDefaults.standard.set(showLook, forKey: "showLookInViewfinder"); syncPump() }
    }
    var bias: Float = 0
    var notice: String?
    var exposureLocked = false
    var shutterLimit = UserDefaults.standard.integer(forKey: "shutterLimitDenominator") {
        didSet { UserDefaults.standard.set(shutterLimit, forKey: "shutterLimitDenominator"); backend.setShutterLimit(shutterLimit > 0 ? shutterLimit : nil) }
    }
    var muteShutter = UserDefaults.standard.bool(forKey: "muteShutterSound") {
        didSet { UserDefaults.standard.set(muteShutter, forKey: "muteShutterSound"); backend.setMuteShutter(muteShutter) }
    }
    var nightBursts = UserDefaults.standard.object(forKey: "nightBursts") as? Bool ?? true {
        didSet { UserDefaults.standard.set(nightBursts, forKey: "nightBursts"); syncNight(); publishLockedContext() }
    }
    var nightAvailable: Bool {
        nightBursts && !manual.exposureManual && store.burstMerge && formatLabel != "PRORAW" && NightBurst.applies(iso: reading.iso, duration: reading.duration)
    }
    var nightDeclined = false {
        didSet { if nightDeclined != oldValue { syncNight() } }
    }
    var nightActive: Bool { nightAvailable && !nightDeclined }
    func toggleNight() { nightDeclined.toggle(); Haptics.tick() }
    private func syncNight() { backend.setNightBursts(nightBursts && !nightDeclined) }
    var scanCodes = UserDefaults.standard.object(forKey: "scanCodesInViewfinder") as? Bool ?? true {
        didSet { UserDefaults.standard.set(scanCodes, forKey: "scanCodesInViewfinder"); syncScanning() }
    }
    var manualOpen = false
    var manualDial = ManualDial.shutter
    private(set) var manual = ManualSettings()
    private(set) var manualRange: ManualRange?
    var isAuto: Bool { manual.isAuto }
    var scannedCode: ScannedCode?
    var codeAction: SystemCodeAction?
    private var codeExpiry: Task<Void, Never>?

    let pump = FramePump()
    private let backend: CameraBackend
    private let store: any CameraStore
    private var shot: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var controls: CameraControls?

    var captureSession: AVCaptureSession? { backend.captureSession }
    var sessionQueue: DispatchQueue? { backend.sessionQueue }
    var previewAngle: CGFloat { backend.previewAngle }

    // the lock screen must write raws to its session folder
    init(store: any CameraStore, captureDirectory: URL? = nil) {
        self.store = store
        #if targetEnvironment(simulator)
        backend = DemoCameraBackend()
        #else
        backend = DeviceCameraBackend(directory: captureDirectory)
        #endif
        aspect = store.aspectRatioPreset
    }

    var backLenses: [CameraLens] { lenses.filter { $0.facing == .back } }

    func stop(for lens: CameraLens) -> CameraLens? {
        if lenses.contains(lens) { return lens }
        return lenses.filter { $0.deviceID == lens.deviceID }.min {
            abs(log(Double($0.focalLength) / Double(lens.focalLength))) < abs(log(Double($1.focalLength) / Double(lens.focalLength)))
        }
    }
    private var zoomBase: CameraLens? {
        let crop = backLenses.first { $0.cropFactor > 1 }
        return backLenses.first { $0.cropFactor == 1 && $0.deviceID == crop?.deviceID }
            ?? backLenses.filter { $0.cropFactor == 1 }.min { abs($0.focalLength - 26) < abs($1.focalLength - 26) }
    }
    private var zoomStart: Double?
    private var zoomToWide = false
    private(set) var zoomReadout: Int?
    private var readoutHide: Task<Void, Never>?

    private var zoomStops: [Double] {
        guard let base = zoomBase else { return [] }
        return ([base.focalLength, 35, 50, 75, 100, 135, 200, Int(CameraLens.maxZoomFocal)] + backLenses.filter { $0.focalLength >= base.focalLength }.map(\.focalLength)).map(Double.init)
    }

    func beginZoom() {
        cancelZoomSettle()
        guard let active, active.facing == .back else { zoomStart = nil; return }
        zoomStart = focal(of: active)
        lastZoomFocal = zoomStart
        zoomToWide = false
        readoutHide?.cancel()
    }

    func updateZoom(scale: Double) {
        guard let start = zoomStart, let base = zoomBase, !firing else { return }
        var f = start * scale
        let wide = backLenses.filter { $0.cropFactor == 1 && $0.focalLength < base.focalLength }.max { $0.focalLength < $1.focalLength }
        if let wide, f < Double(base.focalLength) * 0.85 {
            zoomToWide = true
            zoomReadout = wide.focalLength
            return
        }
        zoomToWide = false
        f = min(max(f, Double(base.focalLength)), CameraLens.maxZoomFocal)
        if let prev = lastZoomFocal, prev != f, zoomStops.contains(where: { min(prev, f) < $0 && $0 <= max(prev, f) }) { Haptics.tick() }
        lastZoomFocal = f
        zoomReadout = Int(applyZoom(f).rounded())
    }

    func setZoomFocal(_ focal: Double) {
        guard let base = zoomBase, !firing else { return }
        let wide = backLenses.filter { $0.cropFactor == 1 && $0.focalLength < base.focalLength }.max { $0.focalLength < $1.focalLength }
        if let wide, focal < Double(base.focalLength) * 0.85 {
            pendingZoom = nil
            if active != wide { select(wide, quiet: true) }
            return
        }
        applyZoom(min(max(focal, Double(base.focalLength)), CameraLens.maxZoomFocal))
    }

    func endZoom() {
        if zoomToWide, let base = zoomBase,
           let wide = backLenses.filter({ $0.cropFactor == 1 && $0.focalLength < base.focalLength }).max(by: { $0.focalLength < $1.focalLength }) {
            select(wide)
        } else if zoomStart != nil, let f = lastZoomFocal {
            zoomStart = nil
            let snap = zoomStops.filter { abs($0 - f) < 1.5 }.min { abs($0 - f) < abs($1 - f) }
            if active?.facing == .back { zoomReadout = Int(applyZoom(snap ?? f, animated: snap != nil).rounded()) }
        }
        zoomStart = nil; zoomToWide = false; lastZoomFocal = nil
        syncControls()
        readoutHide = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            if !Task.isCancelled { self?.zoomReadout = nil }
        }
    }

    private func cancelZoomSettle() { pendingZoom = nil }

    private var lastZoomFocal: Double?
    private var pendingZoom: Double?

    private var zoomSources: [CameraLens] {
        guard let base = zoomBase else { return [] }
        return backLenses.filter { $0.cropFactor == 1 && $0.focalLength >= base.focalLength }.sorted { $0.focalLength < $1.focalLength }
    }

    private func zoomSource(for f: Double) -> CameraLens? {
        zoomSources.last { Double($0.focalLength) <= f + 0.5 } ?? zoomBase
    }

    private func focal(of lens: CameraLens) -> Double {
        guard let native = lenses.first(where: { $0.deviceID == lens.deviceID && $0.cropFactor == 1 }) else { return Double(lens.focalLength) }
        return Double(native.focalLength) * lens.cropFactor
    }

    private func zoomLens(on source: CameraLens, focal f: Double) -> CameraLens {
        let f = max(f, Double(source.focalLength))
        return backLenses.first { $0.deviceID == source.deviceID && abs(focal(of: $0) - f) < 0.01 } ?? source.crop(focal: f)
    }

    private func show(_ lens: CameraLens, animated: Bool) {
        if animated { active = lens; return }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { active = lens }
    }

    // tele holds at its native focal in between so hovering doesnt flip cameras
    private static let zoomDownHysteresis = 0.95

    @discardableResult
    private func applyZoom(_ f: Double, animated: Bool = false) -> Double {
        guard !firing, var source = zoomSource(for: f) else { return f }
        var f = f
        if let a = active, a.facing == .back,
           let current = zoomSources.first(where: { $0.deviceID == a.deviceID }),
           current.focalLength > source.focalLength, f >= Double(current.focalLength) * Self.zoomDownHysteresis {
            source = current
            f = Double(current.focalLength)
        }
        if swapping {
            pendingZoom = f
            pump.set(focal: f, device: source.deviceID)
            if let a = active, a.facing == .back, let old = zoomSources.first(where: { $0.deviceID == a.deviceID }) {
                let lens = zoomLens(on: old, focal: f)
                if abs(lens.cropFactor - a.cropFactor) > 0.0005 { show(lens, animated: false) }
            }
            return max(f, Double(active.flatMap { a in zoomSources.first { $0.deviceID == a.deviceID } }?.focalLength ?? 0))
        }
        let lens = zoomLens(on: source, focal: f)
        if let a = active, a.deviceID == lens.deviceID, abs(lens.cropFactor - a.cropFactor) < 0.0005 { return f }
        select(lens, quiet: true, animated: animated)
        return f
    }

    var frontLens: CameraLens? { lenses.first { $0.facing == .front } }
    var isFront: Bool { active?.facing == .front }

    func start() async {
        guard phase != .running else { resume(); return }
        do {
            let began = ContinuousClock.now
            let pump = pump
            let firstFrame = OSAllocatedUnfairLock(initialState: false)
            let frameDevice = frameDevice
            backend.onFrame = { buffer, device in
                frameDevice.withLock { $0 = device }
                if !firstFrame.withLock({ seen in defer { seen = true }; return seen }) {
                    Startup.log.notice("first frame \(began.duration(to: .now), privacy: .public)")
                }
                pump.push(buffer, from: device)
            }
            pump.drawsPlain = backend.captureSession == nil
            backend.onStats = { [weak self] s in Task { @MainActor in self?.stats = s } }
            syncPump()
            await backend.setProRAWPreferred(!store.burstMerge)
            let wanted = UserDefaults.standard.integer(forKey: "defaultLens")
            let result = try await backend.prepare { wanted != 0 && $0.facing == .back && abs($0.focalLength - wanted) <= 2 }
            Startup.log.notice("configured \(began.duration(to: .now), privacy: .public)")
            lenses = result.lenses
            active = result.active
            pump.set(natives: Dictionary(lenses.filter { $0.cropFactor == 1 }.map { ($0.deviceID, Double($0.focalLength)) }, uniquingKeysWith: { a, _ in a }))
            if let active { pump.set(focal: focal(of: active), device: active.deviceID) }
            formatLabel = backend.formatLabel
            manualRange = backend.manualRange()
            backend.setShutterLimit(shutterLimit > 0 ? shutterLimit : nil)
            backend.setMuteShutter(muteShutter)
            syncNight()
            syncScanning()
            attachControls()
            Startup.log.notice("controls attached \(began.duration(to: .now), privacy: .public)")
            backend.resume()
            phase = .running
            live = true
            startTicker()
            publishLockedContext()
            pump.configure(grader: try? await RenderEngine.shared.makeLiveGrader())
        } catch CaptureError.notAuthorized {
            phase = .denied
        } catch {
            phase = .failed("\(error)")
        }
    }

    func resume() { syncPump(); backend.resume(); startTicker(); live = true }
    func refreshSettings() {
        syncPump(); publishLockedContext()
        guard phase == .running, !swapping, !firing else { return }
        switching = true; swapping = true
        Task {
            // reinstalling resets exposure, keep the ui in step
            if await backend.setProRAWPreferred(!store.burstMerge) { bias = 0; exposureLocked = false }
            formatLabel = backend.formatLabel
            switching = false; swapping = false
        }
    }
    func pause() {
        publishLockedContext()
        live = false
        cancelShot()
        backend.pause()
        ticker?.cancel()
    }

    private func syncScanning() {
        backend.setCodeScanning(scanCodes) { [weak self] code in
            Task { @MainActor in
                guard let self else { return }
                if self.scannedCode?.raw != code {
                    self.scannedCode = ScannedCode(code)
                    self.codeAction = nil
                    #if CREPUSCULE_APP
                    SystemCodeAction.resolve(code) { [weak self] action in
                        if self?.scannedCode?.raw == code { self?.codeAction = action }
                    }
                    #endif
                }
                self.codeExpiry?.cancel()
                self.codeExpiry = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if !Task.isCancelled { self?.scannedCode = nil; self?.codeAction = nil }
                }
            }
        }
        if !scanCodes { scannedCode = nil; codeAction = nil }
    }

    func lockExposure(at p: CGPoint) {
        guard !manual.exposureManual else { notice = "Exposure is manual. Set ISO and shutter to Auto to lock it."; return }
        UserDefaults.standard.set(true, forKey: "lockHintShown")
        Task {
            exposureLocked = await backend.lockExposure(atViewPoint: sensorPoint(p), front: isFront)
            if exposureLocked { Haptics.bump() }
        }
    }
    private func sensorPoint(_ p: CGPoint) -> CGPoint {
        let f = 1 / CGFloat(active?.cropFactor ?? 1)
        return CGPoint(x: 0.5 + (p.x - 0.5) * f, y: 0.5 + (p.y - 0.5) * f)
    }

    func unlockExposure() {
        guard exposureLocked else { return }
        backend.unlockExposure()
        exposureLocked = false
    }

    private func publishLockedContext() {
        #if CREPUSCULE_APP
        let d = UserDefaults.standard, json = JSONEncoder()
        var context = LockedCaptureContext()
        context.stack = store.burstMerge; context.muteShutter = muteShutter; context.shutterLimit = shutterLimit
        context.nightBursts = nightBursts; context.highlightRetentionStops = store.highlightRetentionStops
        context.bracketMetering = store.bracketMetering.rawValue; context.aspect = store.aspectRatioPreset.rawValue
        context.look = try? json.encode(store.perImageDefaults)
        context.looks = store.allLooks.compactMap { l in (try? json.encode(l.grade)).map { .init(name: l.name, grade: $0) } }
        context.showGrid = showGrid; context.showLook = showLook
        context.defaultLens = d.integer(forKey: "defaultLens"); context.lensReadout = d.string(forKey: "lensReadout")
        context.vignette = d.object(forKey: "appleVignetteAmount") as? Double ?? 1
        Task { try? await CrepusculeCaptureIntent.updateAppContext(context) }
        #endif
    }

    private var controlLenses: [CameraLens] {
        backLenses.sorted { $0.focalLength < $1.focalLength } + (frontLens.map { [$0] } ?? [])
    }

    var controlState: CameraControls.State {
        let base = Float(zoomBase?.focalLength ?? 26)
        func factor(_ mm: Int) -> Float { (Float(mm) / base * 10).rounded() / 10 }
        let range: ClosedRange<Float>? = zoomBase.map { _ in
            factor(backLenses.map(\.focalLength).min() ?? Int(base))...factor(Int(CameraLens.maxZoomFocal))
        }
        let current = active?.facing == .back ? (active?.focalLength ?? Int(base)) : Int(base)
        return CameraControls.State(
            bias: bias,
            zoom: Float(current) / base,
            zoomRange: range,
            zoomStops: [0.5, 1, 2, 5, 10],
            lensTitles: controlLenses.map { $0.facing == .front ? "Front" : "\($0.focalLength) mm" },
            lens: active.flatMap(stop(for:)).flatMap(controlLenses.firstIndex(of:)) ?? 0,
            lookTitles: looks.map(\.name),
            look: looks.firstIndex { $0.grade == defaultLook } ?? 0,
            aspectTitles: AspectRatioPreset.pickable.map(\.label),
            aspect: AspectRatioPreset.pickable.firstIndex(of: aspect) ?? 0,
            driveTitles: DriveMode.allCases.map(\.title),
            drive: DriveMode.allCases.firstIndex(of: drive) ?? 0,
            shutterTitles: ["Auto"] + shutterStops.map { ExposureText.shutter($0) },
            shutter: manual.duration.map { ManualStops.nearest($0, in: shutterStops) + 1 } ?? 0,
            isoTitles: ["Auto"] + isoStops.map { "ISO \(Int($0))" },
            iso: manual.iso.map { ManualStops.nearest($0, in: isoStops) + 1 } ?? 0,
            apertureTitles: apertureStops.isEmpty ? [] : ["Auto"] + apertureStops.map { ExposureText.aperture($0) },
            aperture: manual.aperture.map { ManualStops.nearest($0, in: apertureStops) + 1 } ?? 0)
    }

    var isoStops: [Float] { manualRange.map(ManualStops.iso(in:)) ?? [] }
    var shutterStops: [Double] { manualRange.map(ManualStops.shutter(in:)) ?? [] }
    var apertureStops: [Float] { manualRange.map(ManualStops.aperture(in:)) ?? [] }

    private func attachControls() {
        guard let captureSession, let sessionQueue = backend.sessionQueue else { return }
        controls = CameraControls(actions: .init(
            bias: { [weak self] in self?.setBias($0) },
            zoom: { [weak self] x in
                guard let self, let base = zoomBase else { return }
                setZoomFocal(Double(x) * Double(base.focalLength))
            },
            lens: { [weak self] i in
                guard let self, controlLenses.indices.contains(i) else { return }
                cancelZoomSettle()
                select(controlLenses[i])
                syncControls()
            },
            look: { [weak self] i in
                guard let self, looks.indices.contains(i) else { return }
                chooseLook(looks[i].grade)
            },
            aspect: { [weak self] in self?.setAspect(AspectRatioPreset.pickable[$0]) },
            drive: { [weak self] in self?.drive = DriveMode.allCases[$0]; Haptics.tick() },
            shutter: { [weak self] i in
                guard let self else { return }
                var m = manual; m.duration = i > 0 && i <= shutterStops.count ? shutterStops[i - 1] : nil; setManual(m)
            },
            iso: { [weak self] i in
                guard let self else { return }
                var m = manual; m.iso = i > 0 && i <= isoStops.count ? isoStops[i - 1] : nil; setManual(m)
            },
            aperture: { [weak self] i in
                guard let self else { return }
                var m = manual; m.aperture = i > 0 && i <= apertureStops.count ? apertureStops[i - 1] : nil; setManual(m)
            },
            fullscreen: { [weak self] in self?.controlsFullscreen = $0 }), sessionQueue: sessionQueue)
        controls?.attach(session: captureSession, state: controlState)
    }

    func syncControls() {
        if let captureSession { controls?.update(session: captureSession, state: controlState) }
    }

    private func syncPump() {
        pump.set(grade: store.perImageDefaults, look: showLook)
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let r = backend.reading() { reading = r }
                if let a = backend.captureAngle() {
                    let hold = abs(a - 90) > 45 && abs(a - 270) > 45
                    if hold != landscapeHold { landscapeHold = hold }
                }
                if let o = backend.heldOrientation() {
                    let turn: Double = o == .landscapeLeft ? 90 : o == .landscapeRight ? -90 : 0
                    if turn != glyphTurn { glyphTurn = turn }
                }
                try? await Task.sleep(nanoseconds: 180_000_000)
            }
        }
    }

    func isInstant(_ lens: CameraLens) -> Bool { active.map { $0.deviceID == lens.deviceID && $0.facing == lens.facing } ?? false }

    func select(_ lens: CameraLens, quiet: Bool = false, animated: Bool? = nil) {
        if !quiet { cancelZoomSettle() }
        guard lens != active, !swapping, !firing else { return }
        if isInstant(lens) {
            show(lens, animated: animated ?? !quiet)
            pump.set(focal: focal(of: lens), device: lens.deviceID)
            if !quiet { Haptics.tick() }
            if zoomStart == nil { syncControls() }
            return
        }
        swapping = true
        if !quiet { switching = true; Haptics.bump() }
        pump.set(focal: focal(of: lens), device: lens.deviceID)
        Task {
            var landed = false
            do {
                try await backend.select(lens)
                landed = true
                formatLabel = backend.formatLabel
                manualRange = backend.manualRange()
                var kept = manual
                if manualRange?.variableAperture != true { kept.aperture = nil }
                if manualRange?.manualFocus != true { kept.lensPosition = nil }
                if kept != manual { setManual(kept) }
                bias = 0
                exposureLocked = false
            } catch {
                notice = "Couldn't switch to \(lens.focalLength) mm."
                if let active { pump.set(focal: focal(of: active), device: active.deviceID) }
            }
            if landed {
                await firstFrame(from: lens.deviceID)
                var shown = lens
                if lens.facing == .back, let p = pendingZoom, let native = zoomSources.first(where: { $0.deviceID == lens.deviceID }) {
                    shown = zoomLens(on: native, focal: p)
                }
                show(shown, animated: false)
                pump.set(focal: pendingZoom ?? focal(of: shown), device: shown.deviceID)
            }
            if !quiet { try? await Task.sleep(nanoseconds: 120_000_000) }
            swapping = false
            switching = false
            if zoomStart == nil { syncControls() }
            if let p = pendingZoom {
                pendingZoom = nil
                if active?.facing == .back { applyZoom(p) }
            }
        }
    }

    private let frameDevice = OSAllocatedUnfairLock<String?>(initialState: nil)

    private func firstFrame(from device: String) async {
        for _ in 0..<60 {
            guard let seen = frameDevice.withLock({ $0 }), seen != device else { return }
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
    }

    func flipCamera() {
        guard !swapping, !firing else { return }
        cancelZoomSettle()
        flips += 1
        if isFront, let back = backLenses.first(where: { $0.focalLength > 20 }) ?? backLenses.first { select(back) }
        else if let frontLens { select(frontLens) }
    }

    func chooseLook(_ grade: Grade) {
        store.perImageDefaults = grade
        showLook = true
        syncPump()
        Haptics.tick()
    }
    var defaultLook: Grade { store.perImageDefaults }
    var looks: [(name: String, grade: Grade)] { store.allLooks }

    func focus(at p: CGPoint) {
        exposureLocked = false
        if !UserDefaults.standard.bool(forKey: "lockHintShown") {
            UserDefaults.standard.set(true, forKey: "lockHintShown")
            notice = "Tip: hold on the viewfinder to lock exposure."
        }
        backend.focus(atViewPoint: sensorPoint(p), front: isFront)
    }

    func setBias(_ v: Float) {
        bias = min(max(v, -3), 3)
        backend.setBias(bias)
    }

    func setManual(_ m: ManualSettings) {
        manual = m
        if m.exposureManual { exposureLocked = false }
        backend.setManual(m)
    }

    func toggleManualPanel() {
        manualOpen.toggle()
        if manualOpen, manualDial == .aperture, manualRange?.variableAperture != true { manualDial = .shutter }
        Haptics.tick()
    }

    func setAspect(_ a: AspectRatioPreset) {
        aspect = a
        store.aspectRatioPreset = a
        Haptics.tick()
    }

    func shootWhenReady(drive: DriveMode? = nil, timer: SelfTimer? = nil) {
        guard phase == .running, !firing else { return }
        Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard live, !firing else { return }
            pressShutter(drive: drive, timer: timer)
        }
    }

    func pressShutter(drive driveOverride: DriveMode? = nil, timer timerOverride: SelfTimer? = nil) {
        if firing { cancelShot(); return }
        firing = true
        Haptics.shutter()
        let stack = store.burstMerge, retention = store.highlightRetentionStops, metering = store.bracketMetering, shotBias = bias
        let night = nightActive
        let drive = driveOverride ?? drive, timer = timerOverride ?? timer, aspect = aspect, crop = active?.cropFactor ?? 1
        shot = Task { [weak self] in
            guard let self else { return }
            defer {
                firing = false
                progress = nil
            }
            do {
                let results = try await backend.shoot(mode: drive, timer: timer, stack: stack, retention: retention, metering: metering, crop: crop) { [weak self] p in
                    Task { @MainActor in
                        guard let self else { return }
                        self.progress = p
                        if case .shot = p { self.blink() }
                        if case .countdown = p { Haptics.tick() }
                    }
                }
                for (i, r) in results.enumerated() {
                    let tag: String?
                    switch drive {
                    case .single: tag = nil
                    case .burst3, .burst5: tag = "\(i + 1)/\(drive.shots)"
                    case .bracket3, .bracket5: tag = String(format: "%+.0f EV", drive.evOffsets[i])
                    }
                    if let job = try store.file(r, bias: shotBias, aspect: aspect, tag: tag, cropFactor: crop, night: night) { runAfterCapture(job) }
                }
            } catch is CancellationError {
                Haptics.warn()
            } catch {
                notice = "\(error)"
                Haptics.warn()
            }
        }
    }

    func runAfterCapture(_ job: @escaping () async throws -> Void) {
        Task { do { try await job() } catch { notice = error.localizedDescription } }
    }

    private func cancelShot() { shot?.cancel(); shot = nil }

    private func blink() {
        flash = true
        Task {
            try? await Task.sleep(nanoseconds: 70_000_000)
            flash = false
        }
    }
}
