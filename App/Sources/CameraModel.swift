// Crepuscule - CameraModel.swift
// Constantin Clerc (c22dev) - 0.1
import AVFoundation
import Crepuscule
import CoreImage
import Observation
import os
import UIKit

enum Startup {
    static let log = Logger(subsystem: "ch.cclerc.crepuscule", category: "startup")
}

protocol CameraBackend: AnyObject {
    var onFrame: ((CVPixelBuffer) -> Void)? { get set }
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
    func shoot(mode: DriveMode, timer: SelfTimer, stack: Bool, retention: Double, metering: CameraCapture.BracketMetering, crop: Double, progress: @escaping @Sendable (DriveProgress) -> Void) async throws -> [CaptureResult]
    var captureSession: AVCaptureSession? { get }
    var sessionQueue: DispatchQueue? { get }
}

final class DeviceCameraBackend: CameraBackend {
    private let capture: CameraCapture
    private var rotation: AVCaptureDevice.RotationCoordinator?

    init() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Captures")
        capture = CameraCapture(directory: dir)
    }

    var onFrame: ((CVPixelBuffer) -> Void)? {
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
    func captureAngle() -> CGFloat? { rotation?.videoRotationAngleForHorizonLevelCapture }
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
    private var crop = 1.0
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
    func set(cropFactor: Double) { lock.withLock { crop = cropFactor } }
    func set(grade: Grade, look: Bool) { lock.withLock { self.grade = grade; self.look = look } }

    private static func centre(_ image: CIImage, _ factor: Double) -> CIImage {
        guard factor > 1 else { return image }
        let e = image.extent, f = CGFloat(factor)
        return image.cropped(to: e.insetBy(dx: e.width * (1 - 1 / f) / 2, dy: e.height * (1 - 1 / f) / 2))
    }

    func push(_ buffer: CVPixelBuffer) {
        let claimed = lock.withLock { () -> Bool in
            if busy { return false }
            busy = true
            return true
        }
        guard claimed else { return }
        queue.async { [self] in
            defer { lock.withLock { busy = false } }
            if let ambientDisplay, let image = ambient.update(buffer) { ambientDisplay.show(image) }
            let (g, gradeNow, lookNow, cropNow) = lock.withLock { (grader, grade, look, crop) }
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
    private(set) var flips = 0
    private(set) var reading = ExposureReading()
    private(set) var stats = FrameStats()
    private(set) var progress: DriveProgress?
    private(set) var firing = false
    private(set) var flash = false
    private(set) var formatLabel = "RAW"
    private(set) var landscapeHold = false
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
        didSet { UserDefaults.standard.set(nightBursts, forKey: "nightBursts"); backend.setNightBursts(nightBursts); publishLockedContext() }
    }
    var nightActive: Bool {
        nightBursts && !manual.exposureManual && library.burstMerge && formatLabel != "PRORAW" && NightBurst.applies(iso: reading.iso, duration: reading.duration)
    }
    var scanCodes = UserDefaults.standard.object(forKey: "scanCodesInViewfinder") as? Bool ?? true {
        didSet { UserDefaults.standard.set(scanCodes, forKey: "scanCodesInViewfinder"); syncScanning() }
    }
    // values reset to auto each launch
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
    private let library: Library
    private var shot: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var controls: CameraControls?

    var captureSession: AVCaptureSession? { backend.captureSession }
    var sessionQueue: DispatchQueue? { backend.sessionQueue }
    var previewAngle: CGFloat { backend.previewAngle }

    init(library: Library) {
        self.library = library
        #if targetEnvironment(simulator)
        backend = DemoCameraBackend()
        #else
        backend = DeviceCameraBackend()
        #endif
        aspect = library.settings.aspectRatioPreset
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
    private var lastSnap: Int?
    private(set) var zoomReadout: Int?
    private var readoutHide: Task<Void, Never>?

    func beginZoom() {
        cancelZoomSettle()
        guard active?.facing == .back else { zoomStart = nil; return }
        zoomStart = Double(active?.focalLength ?? 26)
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
        let stops = [base.focalLength, 35, 50, 75, 100, 135, 200, Int(CameraLens.maxZoomFocal)] + backLenses.filter { $0.focalLength >= base.focalLength }.map(\.focalLength)
        let snap = stops.first { abs(Double($0) - f) < 1.5 }
        if let snap { f = Double(snap) }
        if snap != lastSnap, snap != nil { Haptics.tick() }
        lastSnap = snap
        zoomReadout = Int(f.rounded())
        lastZoomFocal = f
        applyZoom(f, settle: false)
    }

    func setZoomFocal(_ focal: Double) {
        guard let base = zoomBase, !firing else { return }
        let wide = backLenses.filter { $0.cropFactor == 1 && $0.focalLength < base.focalLength }.max { $0.focalLength < $1.focalLength }
        if let wide, focal < Double(base.focalLength) * 0.85 {
            settleTask?.cancel()
            if active != wide { select(wide, quiet: true) }
            return
        }
        let f = min(max(focal, Double(base.focalLength)), CameraLens.maxZoomFocal)
        applyZoom(f, settle: false)
        // camera control has no end event, settle once it stops moving
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled, let self else { return }
            settleTask = nil
            if active?.facing == .back { applyZoom(f, settle: true) }
        }
    }

    func endZoom() {
        if zoomToWide, let base = zoomBase,
           let wide = backLenses.filter({ $0.cropFactor == 1 && $0.focalLength < base.focalLength }).max(by: { $0.focalLength < $1.focalLength }) {
            select(wide)
        } else if zoomStart != nil, let f = lastZoomFocal {
            zoomStart = nil
            applyZoom(f, settle: true)
        }
        zoomStart = nil; zoomToWide = false; lastSnap = nil; lastZoomFocal = nil
        readoutHide = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            if !Task.isCancelled { self?.zoomReadout = nil }
        }
    }

    private func cancelZoomSettle() { settleTask?.cancel(); settleTask = nil; pendingZoom = nil }

    private var lastZoomFocal: Double?
    private var pendingZoom: (focal: Double, settle: Bool)?
    private var settleTask: Task<Void, Never>?

    // main + teles, shortest first
    private var zoomSources: [CameraLens] {
        guard let base = zoomBase else { return [] }
        return backLenses.filter { $0.cropFactor == 1 && $0.focalLength >= base.focalLength }.sorted { $0.focalLength < $1.focalLength }
    }

    // longest camera whose native focal is still <= f, so it gets there by cropping (a longer tele can't zoom out)
    private func zoomSource(for f: Double) -> CameraLens? {
        zoomSources.last { Double($0.focalLength) <= f + 0.5 } ?? zoomBase
    }

    private func applyZoom(_ f: Double, settle: Bool) {
        guard !firing, let best = zoomSource(for: f) else { return }
        if switching { pendingZoom = (f, settle); return }
        var source = best
        // mid gesture keep cropping the current camera if it can reach f, switching devices stalls the preview
        if !settle, let a = active, a.facing == .back,
           let current = zoomSources.first(where: { $0.deviceID == a.deviceID }), Double(current.focalLength) <= f + 0.5 {
            source = current
        }
        let target = Int(f.rounded())
        let lens = backLenses.first { $0.deviceID == source.deviceID && $0.focalLength == target } ?? source.crop(focal: f)
        guard lens.focalLength != active?.focalLength || lens.deviceID != active?.deviceID else { return }
        select(lens, quiet: true)
    }

    var frontLens: CameraLens? { lenses.first { $0.facing == .front } }
    var isFront: Bool { active?.facing == .front }

    func start() async {
        guard phase != .running else { resume(); return }
        do {
            let began = ContinuousClock.now
            let pump = pump
            let firstFrame = OSAllocatedUnfairLock(initialState: false)
            backend.onFrame = { buffer in
                if !firstFrame.withLock({ seen in defer { seen = true }; return seen }) {
                    Startup.log.notice("first frame \(began.duration(to: .now), privacy: .public)")
                }
                pump.push(buffer)
            }
            pump.drawsPlain = backend.captureSession == nil
            backend.onStats = { [weak self] s in Task { @MainActor in self?.stats = s } }
            syncPump()
            await backend.setProRAWPreferred(!library.burstMerge)
            let wanted = UserDefaults.standard.integer(forKey: "defaultLens")
            let result = try await backend.prepare { wanted != 0 && $0.facing == .back && abs($0.focalLength - wanted) <= 2 }
            Startup.log.notice("configured \(began.duration(to: .now), privacy: .public)")
            lenses = result.lenses
            active = result.active
            pump.set(cropFactor: active?.cropFactor ?? 1)
            formatLabel = backend.formatLabel
            manualRange = backend.manualRange()
            backend.setShutterLimit(shutterLimit > 0 ? shutterLimit : nil)
            backend.setMuteShutter(muteShutter)
            backend.setNightBursts(nightBursts)
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
        guard phase == .running, !switching, !firing else { return }
        switching = true
        Task {
            // reinstalling resets exposure in the capture layer, keep the ui in step like a lens switch does
            if await backend.setProRAWPreferred(!library.burstMerge) { bias = 0; exposureLocked = false }
            formatLabel = backend.formatLabel
            switching = false
        }
    }
    func pause() {
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
                    SystemCodeAction.resolve(code) { [weak self] action in
                        if self?.scannedCode?.raw == code { self?.codeAction = action }
                    }
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
        let context = LockedCaptureContext(stack: library.burstMerge, muteShutter: muteShutter, shutterLimit: shutterLimit,
                                           nightBursts: nightBursts, highlightRetentionStops: library.settings.highlightRetentionStops)
        Task { try? await CrepusculeCaptureIntent.updateAppContext(context) }
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
        pump.set(grade: library.settings.perImageDefaults, look: showLook)
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
                try? await Task.sleep(nanoseconds: 180_000_000)
            }
        }
    }

    func isInstant(_ lens: CameraLens) -> Bool { active.map { $0.deviceID == lens.deviceID && $0.facing == lens.facing } ?? false }

    func select(_ lens: CameraLens, quiet: Bool = false) {
        // an explicit pick (not a zoom step) wins over a pending camera control settle
        if !quiet { cancelZoomSettle() }
        guard lens != active, !switching, !firing else { return }
        if isInstant(lens) {
            active = lens
            pump.set(cropFactor: lens.cropFactor)
            if !quiet { Haptics.tick() }
            syncControls()
            return
        }
        switching = true
        Haptics.bump()
        Task {
            do {
                try await backend.select(lens)
                active = lens
                pump.set(cropFactor: lens.cropFactor)
                formatLabel = backend.formatLabel
                manualRange = backend.manualRange()
                var kept = manual
                if manualRange?.variableAperture != true { kept.aperture = nil }
                if manualRange?.manualFocus != true { kept.lensPosition = nil }
                if kept != manual { setManual(kept) }
                bias = 0
                exposureLocked = false
            } catch { notice = "Couldn't switch to \(lens.focalLength) mm." }
            try? await Task.sleep(nanoseconds: 120_000_000)
            switching = false
            if let p = pendingZoom {
                pendingZoom = nil
                if active?.facing == .back { applyZoom(p.focal, settle: p.settle || (zoomStart == nil && settleTask == nil)) }
            }
        }
    }

    func flipCamera() {
        guard !switching, !firing else { return }
        cancelZoomSettle()
        flips += 1
        if isFront, let back = backLenses.first(where: { $0.focalLength > 20 }) ?? backLenses.first { select(back) }
        else if let frontLens { select(frontLens) }
    }

    func chooseLook(_ grade: Grade) {
        library.settings.perImageDefaults = grade
        showLook = true
        syncPump()
        Haptics.tick()
    }
    var defaultLook: Grade { library.settings.perImageDefaults }
    var looks: [(name: String, grade: Grade)] { library.allLooks }

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
        library.settings.aspectRatioPreset = a
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
        let stack = library.burstMerge, retention = library.settings.highlightRetentionStops, metering = library.bracketMetering, shotBias = bias
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
                    let item = try library.ingest(base: r.baseURL, frames: r.frames.map { ($0.url, Float($0.spec?.exposureScale ?? 1)) }, blur: r.blurPixels, bias: shotBias, aspect: aspect, tag: tag, cropFactor: crop, night: night)
                    if library.settings.autoExport { autoExport(item) }
                }
            } catch is CancellationError {
                Haptics.warn()
            } catch {
                notice = "\(error)"
                Haptics.warn()
            }
        }
    }

    func file(lockedShot shot: LockedShot, in folder: URL) throws {
        let item = try library.ingest(base: folder.appendingPathComponent(shot.base),
                                      frames: shot.frames.map { (folder.appendingPathComponent($0.name), $0.scale) },
                                      blur: shot.blur, bias: 0, aspect: library.settings.aspectRatioPreset, tag: nil)
        if library.settings.autoExport { autoExport(item) }
    }

    private func autoExport(_ item: PhotoItem) {
        Task { [library] in
            do { try await library.saveToPhotos(item) } catch { notice = error.localizedDescription }
        }
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
