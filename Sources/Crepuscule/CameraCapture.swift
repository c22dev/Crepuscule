// Crepuscule - CameraCapture.swift
// Constantin Clerc (c22dev) - 0.1
#if os(iOS)
@preconcurrency import AVFoundation
import os
import CoreMedia
import UIKit

public enum CaptureError: Error, CustomStringConvertible {
    case notAuthorized, noDevice, sessionSetup(String), noRawFormat, noData, cancelled, underlying(Error)
    public var description: String {
        switch self {
        case .notAuthorized: return "camera access not authorised"
        case .noDevice: return "no camera"
        case .sessionSetup(let s): return "session setup: \(s)"
        case .noRawFormat: return "no RAW pixel format"
        case .noData: return "Capture produced no DNG representation."
        case .cancelled: return "cancelled"
        case .underlying(let e): return "\(e)"
        }
    }
}

public enum CaptureMode: Sendable { case proRAW, bayerRAW }

public struct CaptureResult: Sendable {
    public let baseURL: URL
    public let frames: [(url: URL, spec: BurstFrameSpec?)]
    public let cropInsets: CropInsets
    public var blurPixels: [String: Float] = [:]
    public init(baseURL: URL, frames: [(url: URL, spec: BurstFrameSpec?)], cropInsets: CropInsets) {
        self.baseURL = baseURL; self.frames = frames; self.cropInsets = cropInsets
    }
}

private let meterLog = Logger(subsystem: "ch.cclerc.crepuscule", category: "meter")

public final class CameraCapture: NSObject, @unchecked Sendable {
    public let session = AVCaptureSession()
    public private(set) var mode: CaptureMode = .bayerRAW
    private let output = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let videoQueue = DispatchQueue(label: "crepuscule.capture.video")
    private let statsLock = NSLock()
    private var latestStats: FrameStats?
    private var frameIndex = 0
    private var input: AVCaptureDeviceInput?
    public var onFrame: ((CVPixelBuffer) -> Void)?
    public var onStats: ((FrameStats) -> Void)?
    public var burstEnabled = true
    public var nightBursts = true
    public enum BracketMetering: String, Sendable, CaseIterable {
        case locked
        case closedLoop
        case native
    }
    public var bracketMetering: BracketMetering = .locked
    public var muteShutter = false
    public var onCode: ((String) -> Void)?
    private let metadataOutput = AVCaptureMetadataOutput()
    public private(set) var shutterLimit: Int?
    public static let shutterLimitChoices = [15, 30, 60, 125, 250, 500, 1000]
    private var defaultMaxExposure: [String: CMTime] = [:]
    public private(set) var exposureLocked = false
    private var neutral: (iso: Float, duration: Double)?
    private var currentBias: Float = 0
    public var flashMode: AVCaptureDevice.FlashMode = .off
    public let motionGate = MotionGate()
    private var lastShotTime: Double?
    private let queue = DispatchQueue(label: "crepuscule.capture.session")
    private var device: AVCaptureDevice?
    private var pending: [Int64: BurstDelegate] = [:]
    public var highlightRetentionStops = 2.0
    public var zoomCropFactor = 1.0
    public var aspectRatio: AspectRatioPreset = .native
    public var customAspect = (width: 16.0, height: 9.0)
    public let directory: URL

    public private(set) var prefersProRAW = false
    // queue only
    private var manual = ManualSettings()

    public init(directory: URL) { self.directory = directory }

    @discardableResult
    public func setPrefersProRAW(_ on: Bool) async throws -> Bool {
        let d: AVCaptureDevice? = await withCheckedContinuation { c in
            queue.async { [self] in
                // only reinstall when the mode really flips (never on phones without proraw)
                let changed = prefersProRAW != on && output.isAppleProRAWSupported && mode != (on ? .proRAW : .bayerRAW)
                prefersProRAW = on
                c.resume(returning: changed ? device : nil)
            }
        }
        guard let d else { return false }
        let before = mode
        try await install(d)
        return mode != before
    }

    public static func availableLenses() -> [CameraLens] {
        discovery().flatMap { d -> [CameraLens] in
            let facing: CameraLens.Facing = d.position == .front ? .front : .back
            let focal = CameraLens.equivalentFocalLength(horizontalFOVDegrees: Double(d.activeFormat.videoFieldOfView))
            let lens = CameraLens(id: d.uniqueID, facing: facing, focalLength: focal, name: d.localizedName)
            guard d.position == .back, d.deviceType == .builtInWideAngleCamera, focal > 0 else { return [lens] }
            // crop lenses just crop the raw (bayer raw throws if zoom isnt 1)
            var crops = [lens]
            let native2x = d.formats.contains { f in
                f.supportedMaxPhotoDimensions.contains { $0.width >= 8000 } && f.secondaryNativeResolutionZoomFactors.contains(2)
            }
            if native2x { crops.append(CameraLens(id: d.uniqueID + "#2x", facing: facing, focalLength: focal * 2, name: "2x", cropFactor: 2, deviceID: d.uniqueID)) }
            return crops
        }.sorted { $0.focalLength < $1.focalLength }
    }

    private static func discovery() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera],
                                         mediaType: .video, position: .unspecified).devices
    }

    public func configure(deviceID: String? = nil, position: AVCaptureDevice.Position = .back, deviceType: AVCaptureDevice.DeviceType = .builtInWideAngleCamera) async throws {
        guard await AVCaptureDevice.requestAccess(for: .video) else { throw CaptureError.notAuthorized }
        let chosen = deviceID.flatMap { id in Self.discovery().first { $0.uniqueID == id } }
        guard let d = chosen ?? AVCaptureDevice.default(deviceType, for: .video, position: position) else { throw CaptureError.noDevice }
        try await install(d)
    }

    public func select(lens: CameraLens) async throws {
        guard let d = Self.discovery().first(where: { $0.uniqueID == lens.deviceID }) else { throw CaptureError.noDevice }
        try await install(d)
    }

    private func install(_ d: AVCaptureDevice) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    session.beginConfiguration()
                    defer { session.commitConfiguration() }
                    session.sessionPreset = .photo
                    let new = try AVCaptureDeviceInput(device: d)
                    let old = input
                    if let old { session.removeInput(old); self.input = nil }
                    guard session.canAddInput(new) else {
                        if let old, session.canAddInput(old) { session.addInput(old); input = old }
                        throw CaptureError.sessionSetup("cannot add input")
                    }
                    session.addInput(new)
                    input = new
                    if !session.outputs.contains(output) {
                        guard session.canAddOutput(output) else { throw CaptureError.sessionSetup("cannot add output") }
                        session.addOutput(output)
                    }
                    if !session.outputs.contains(videoOutput), session.canAddOutput(videoOutput) {
                        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                        videoOutput.alwaysDiscardsLateVideoFrames = true
                        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
                        session.addOutput(videoOutput)
                    }
                    if let v = videoOutput.connection(with: .video) {
                        let angle = Self.portraitAngle(of: d)
                        previewAngle = angle
                        if v.isVideoRotationAngleSupported(angle) { v.videoRotationAngle = angle }
                        if v.isVideoMirroringSupported {
                            v.automaticallyAdjustsVideoMirroring = false
                            v.isVideoMirrored = d.position == .front
                        }
                    }
                    output.maxPhotoQualityPrioritization = .speed
                    // bayer by default so bursts + super res work on pro phones too, proraw only for single frame
                    let pro = prefersProRAW && output.isAppleProRAWSupported
                    if output.isAppleProRAWSupported { output.isAppleProRAWEnabled = pro }
                    mode = pro ? .proRAW : .bayerRAW
                    device = d
                    exposureLocked = false; neutral = nil; currentBias = 0
                    if (try? d.lockForConfiguration()) != nil {
                        d.setExposureTargetBias(0)
                        if d.exposureMode == .custom || d.exposureMode == .locked, d.isExposureModeSupported(.continuousAutoExposure) {
                            d.exposureMode = .continuousAutoExposure
                        }
                        // new device starts on auto, manual values carry over clamped to its range
                        applyManual(d, was: ManualSettings())
                        d.unlockForConfiguration()
                    }
                    selectLargestRawDimensions(d)
                    if mode == .bayerRAW, (try? rawFormat()) == nil, output.isAppleProRAWSupported {
                        output.isAppleProRAWEnabled = true
                        mode = .proRAW
                        selectLargestRawDimensions(d)
                    }
                    queue.async { [self] in applyShutterLimit() }
                    c.resume()
                } catch { c.resume(throwing: error) }
            }
        }
    }

    private static func portraitAngle(of d: AVCaptureDevice) -> CGFloat {
        if #available(iOS 27.0, *) {
            return AVCaptureDevice.RotationCoordinator(device: d, previewLayer: nil).videoRotationAngleRelative(toDeviceOrientation: .portrait)
        }
        return 90
    }

    public func start() { queue.async { [self] in if !session.isRunning { session.startRunning() } }; motionGate.start() }
    public func stop() { queue.async { [self] in if session.isRunning { session.stopRunning() } }; motionGate.stop() }

    public var activeDevice: AVCaptureDevice? { device }
    // all session config goes thru here or it deadlocks
    public var sessionQueue: DispatchQueue { queue }
    public private(set) var previewAngle: CGFloat = 90

    public func focus(at point: CGPoint) {
        queue.async { [self] in
            exposureLocked = false; neutral = nil
            guard let device, (try? device.lockForConfiguration()) != nil else { return }
            defer { device.unlockForConfiguration() }
            if manual.lensPosition == nil {
                if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = point }
                if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
            }
            // in manual the point still steers the meter that priority modes follow
            if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = point }
            if !manual.exposureManual, device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        }
    }

    public func setManual(_ m: ManualSettings) {
        queue.async { [self] in
            let was = manual
            manual = m
            guard let device, (try? device.lockForConfiguration()) != nil else { return }
            defer { device.unlockForConfiguration() }
            if m.exposureManual { exposureLocked = false; neutral = nil }
            applyManual(device, was: was)
        }
    }

    public func manualRange() -> ManualRange? {
        guard let device else { return nil }
        let f = device.activeFormat
        var lo = device.lensAperture, hi = device.lensAperture, stops: [Float] = []
        if #available(iOS 27.0, *), f.maxLensAperture > 0 {
            lo = f.minLensAperture; hi = f.maxLensAperture; stops = f.recommendedLensApertureStops
        }
        return ManualRange(minISO: f.minISO, maxISO: f.maxISO,
                           minDuration: CMTimeGetSeconds(f.minExposureDuration), maxDuration: CMTimeGetSeconds(f.maxExposureDuration),
                           minAperture: lo, maxAperture: hi, apertureStops: stops,
                           manualFocus: device.isLockingFocusWithCustomLensPositionSupported)
    }

    // config must be locked
    private func applyManual(_ device: AVCaptureDevice, was: ManualSettings) {
        if let p = manual.lensPosition, device.isLockingFocusWithCustomLensPositionSupported {
            device.setFocusModeLocked(lensPosition: min(max(p, 0), 1), completionHandler: nil)
        } else if was.lensPosition != nil, device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        if manual.exposureManual { applyManualExposure(device) }
        else if was.exposureManual, device.exposureMode == .custom, device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
    }

    // unset values go to the system's own priority auto, which also follows the bias
    private func applyManualExposure(_ device: AVCaptureDevice) {
        guard device.isExposureModeSupported(.custom) else { return }
        let f = device.activeFormat
        let iso = manual.iso.map { min(max($0, f.minISO), f.maxISO) }
        let duration = manual.duration.map {
            CMTime(seconds: min(max($0, CMTimeGetSeconds(f.minExposureDuration)), CMTimeGetSeconds(f.maxExposureDuration)), preferredTimescale: 1_000_000)
        }
        if #available(iOS 27.0, *) {
            let variable = f.maxLensAperture > f.minLensAperture + 0.05
            let aperture = manual.aperture.flatMap { variable ? min(max($0, f.minLensAperture), f.maxLensAperture) : nil }
            let wanted = (aperture ?? (variable ? AVCaptureDevice.autoLensAperture : AVCaptureDevice.currentLensAperture),
                          duration ?? AVCaptureDevice.autoExposureDuration, iso ?? AVCaptureDevice.autoISO)
            if f.supportsExposureModeCustom(lensAperture: wanted.0, duration: wanted.1, iso: wanted.2) {
                device.setExposureModeCustom(lensAperture: wanted.0, duration: wanted.1, iso: wanted.2, completionHandler: nil)
                return
            }
        }
        // no priority mode for this combo, hold the free side where auto left it
        device.setExposureModeCustom(duration: duration ?? AVCaptureDevice.currentExposureDuration, iso: iso ?? AVCaptureDevice.currentISO, completionHandler: nil)
    }

    public func setExposureBias(_ stops: Float) {
        queue.async { [self] in
            currentBias = stops
            guard let device, (try? device.lockForConfiguration()) != nil else { return }
            defer { device.unlockForConfiguration() }
            device.setExposureTargetBias(min(max(stops, device.minExposureTargetBias), device.maxExposureTargetBias))
            if exposureLocked { shiftLocked(device, bias: stops) }
        }
    }

    public func setShutterLimit(_ denominator: Int?) {
        queue.async { [self] in shutterLimit = denominator; applyShutterLimit() }
    }

    private func exposureCeiling(_ device: AVCaptureDevice) -> Double {
        let key = device.uniqueID + "|" + device.activeFormat.description
        let def = defaultMaxExposure[key].map(CMTimeGetSeconds) ?? CMTimeGetSeconds(device.activeMaxExposureDuration)
        guard let n = shutterLimit else { return def }
        return min(def, max(CMTimeGetSeconds(device.activeFormat.minExposureDuration), 1 / Double(n)))
    }

    private func applyShutterLimit() {
        guard let device, (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        let key = device.uniqueID + "|" + device.activeFormat.description
        let before = device.activeMaxExposureDuration
        if defaultMaxExposure[key] == nil {
            device.activeMaxExposureDuration = .invalid
            defaultMaxExposure[key] = device.activeMaxExposureDuration
        }
        let target = shutterLimit == nil ? CMTime.invalid : CMTime(seconds: exposureCeiling(device), preferredTimescale: 1_000_000)
        device.activeMaxExposureDuration = target
        let now = CMTimeGetSeconds(device.activeMaxExposureDuration), was = CMTimeGetSeconds(before)
        if now > was * 1.01, device.exposureMode == .continuousAutoExposure,
           abs(CMTimeGetSeconds(device.exposureDuration) - was) < was * 0.05 {
            rearm(device)
            queue.asyncAfter(deadline: .now() + 0.8) { [self] in if let d = self.device, !exposureLocked, (try? d.lockForConfiguration()) != nil { rearm(d); d.unlockForConfiguration() } }
        }
    }

    private func rearm(_ device: AVCaptureDevice) {
        guard device.isExposureModeSupported(.continuousAutoExposure) else { return }
        if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = device.exposurePointOfInterest }
        device.exposureMode = .continuousAutoExposure
    }

    @discardableResult
    public func lockExposure(at point: CGPoint) async -> Bool {
        focus(at: point)
        try? await Task.sleep(nanoseconds: 150_000_000)
        let deadline = Date().addingTimeInterval(1)
        while let device, device.isAdjustingExposure, Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            queue.async { [self] in
                defer { c.resume(returning: exposureLocked) }
                guard let device, (try? device.lockForConfiguration()) != nil else { return }
                defer { device.unlockForConfiguration() }
                let iso = device.iso, d = CMTimeGetSeconds(device.exposureDuration)
                guard iso.isFinite, d.isFinite, d > 0 else { neutral = nil; return }
                neutral = (iso * Float(pow(2, -Double(device.exposureTargetBias))), d)
                exposureLocked = true
                shiftLocked(device, bias: currentBias)
            }
        }
    }

    public func unlockExposure() {
        queue.async { [self] in
            exposureLocked = false; neutral = nil
            guard let device, (try? device.lockForConfiguration()) != nil else { return }
            rearm(device)
            device.unlockForConfiguration()
        }
    }

    private func shiftLocked(_ device: AVCaptureDevice, bias: Float) {
        guard let neutral, device.isExposureModeSupported(.custom) else {
            rearm(device); exposureLocked = false; return
        }
        let f = device.activeFormat
        let target = Double(neutral.iso) * neutral.duration * pow(2, Double(bias))
        let minD = CMTimeGetSeconds(f.minExposureDuration), ceiling = max(minD, min(CMTimeGetSeconds(f.maxExposureDuration), exposureCeiling(device)))
        var d = min(max(neutral.duration, minD), ceiling)
        var iso = target / d
        if iso > Double(f.maxISO) { d = min(target / Double(f.maxISO), ceiling); iso = target / d }
        if iso < Double(f.minISO) { d = max(target / Double(f.minISO), minD); iso = target / d }
        iso = min(max(iso, Double(f.minISO)), Double(f.maxISO))
        device.setExposureModeCustom(duration: CMTime(seconds: d, preferredTimescale: 1_000_000), iso: Float(iso), completionHandler: nil)
    }

    public func setCodeScanning(_ on: Bool) {
        queue.async { [self] in
            let attached = session.outputs.contains(metadataOutput)
            guard on != attached else { return }
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            if on {
                guard session.canAddOutput(metadataOutput) else { return }
                session.addOutput(metadataOutput)
                metadataOutput.setMetadataObjectsDelegate(self, queue: videoQueue)
                let wanted: [AVMetadataObject.ObjectType] = [.qr, .microQR, .aztec, .dataMatrix, .pdf417, .ean8, .ean13, .upce, .code39, .code93, .code128, .itf14, .interleaved2of5]
                metadataOutput.metadataObjectTypes = wanted.filter(metadataOutput.availableMetadataObjectTypes.contains)
            } else {
                session.removeOutput(metadataOutput)
            }
        }
    }

    public func reading() -> ExposureReading? {
        guard let device else { return nil }
        return ExposureReading(iso: device.iso, duration: CMTimeGetSeconds(device.exposureDuration), aperture: device.lensAperture,
                               meterOffset: device.exposureTargetOffset, bias: device.exposureTargetBias, lensPosition: device.lensPosition)
    }

    public func runDrive(mode drive: DriveMode, timer: SelfTimer, rotationAngle: CGFloat?, progress: @escaping @Sendable (DriveProgress) -> Void) async throws -> [CaptureResult] {
        let base = reading()
        let width = output.maxPhotoDimensions.width
        let fov = device.map { Double($0.activeFormat.videoFieldOfView) } ?? 70
        let manualExposure = queue.sync { manual.exposureManual }
        let useNative = drive.isBracket && bracketMetering == .native && !exposureLocked && !manualExposure && mode == .bayerRAW
            && output.maxBracketedCapturePhotoCount >= drive.shots
        let native = NativeBracket()
        let runner = DriveRunner<CaptureResult>(mode: drive, timer: timer, shoot: { [self] ev in
            if drive.isBracket, let base {
                if useNative, let i = drive.evOffsets.firstIndex(of: ev) {
                    return try await native.frame(i) { try await self.captureNativeBracket(evs: drive.evOffsets, base: base, rotationAngle: rotationAngle) }
                }
                if bracketMetering == .closedLoop, !exposureLocked, !manualExposure { return try await captureClosedLoopBracketFrame(ev: ev, base: base, rotationAngle: rotationAngle) }
                return try await captureBracketFrame(ev: ev, base: base, rotationAngle: rotationAngle)
            }
            return try await capture(hints: currentHints(), rotationAngle: rotationAngle)
        }, waitForStill: { [self] in
            await motionGate.waitUntilStill(duration: base?.duration ?? 1.0 / 60, horizontalFOVDegrees: fov, imageWidth: Int(width))
        }, progress: progress)
        return try await withTaskCancellationHandler {
            motionGate.start()
            let shots = try await runner.run()
            if useNative, let all = await native.finished, all.count > shots.count { return all }
            return shots
        } onCancel: { [self] in
            queue.async { self.restoreAutoExposure() }
        }
    }

    public func currentHints() -> BurstHints {
        statsLock.lock(); defer { statsLock.unlock() }
        return latestStats?.hints(now: ProcessInfo.processInfo.systemUptime) ?? BurstHints()
    }

    private func captureBracketFrame(ev: Double, base: ExposureReading, rotationAngle: CGFloat?) async throws -> CaptureResult {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<CaptureResult, Error>) in
            queue.async { [self] in
                do {
                    guard let device else { throw CaptureError.noDevice }
                    let format = try rawFormat()
                    applyRotation(rotationAngle)
                    let f = device.activeFormat
                    let limits = BurstPlanner.Limits(minISO: f.minISO, maxISO: f.maxISO, minDuration: CMTimeGetSeconds(f.minExposureDuration), maxDuration: CMTimeGetSeconds(f.maxExposureDuration))
                    let solved = BracketExposure.solve(iso: base.iso, duration: base.duration, ev: ev, limits: limits)
                    let spec = BurstFrameSpec(sequence: 0, role: .base, iso: solved.iso, durationSeconds: solved.duration, exposureScale: pow(2, ev))
                    setExposure(spec) { [self] in
                        shoot(makeSettings(format: format, gps: nil)) { [self] result in
                            restoreAutoExposure()
                            do {
                                let url = try write(result.get(), suffix: nil)
                                c.resume(returning: CaptureResult(baseURL: url, frames: [(url, spec)], cropInsets: currentCropInsets()))
                            } catch { c.resume(throwing: error) }
                        }
                    }
                } catch { c.resume(throwing: error) }
            }
        }
    }

    private func captureNativeBracket(evs: [Double], base: ExposureReading, rotationAngle: CGFloat?) async throws -> [CaptureResult] {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<[CaptureResult], Error>) in
            queue.async { [self] in
                do {
                    guard let device else { throw CaptureError.noDevice }
                    let format = try rawFormat()
                    applyRotation(rotationAngle)
                    if device.exposureMode == .custom, (try? device.lockForConfiguration()) != nil {
                        device.exposureMode = .continuousAutoExposure
                        device.unlockForConfiguration()
                    }
                    let biases = evs.map { min(max(base.bias + Float($0), device.minExposureTargetBias), device.maxExposureTargetBias) }
                    let brackets = biases.map { AVCaptureAutoExposureBracketedStillImageSettings.autoExposureSettings(exposureTargetBias: $0) }
                    let settings = AVCapturePhotoBracketSettings(rawPixelFormatType: format, rawFileType: .dng, processedFormat: nil, processedFileType: nil, bracketedSettings: brackets)
                    settings.flashMode = .off
                    prepare(settings)
                    if output.isLensStabilizationDuringBracketedCaptureSupported { settings.isLensStabilizationEnabled = true }
                    let delegate = BurstDelegate(queue: queue) { [self] result in
                        pending[settings.uniqueID] = nil
                        do {
                            let datas = try result.get()
                            let crop = currentCropInsets()
                            c.resume(returning: try datas.enumerated().map { i, data in
                                let ev = evs[min(i, evs.count - 1)]
                                let spec = BurstFrameSpec(sequence: 0, role: .base, iso: base.iso, durationSeconds: base.duration * pow(2, ev), exposureScale: pow(2, ev))
                                let url = try write(data, suffix: nil)
                                return CaptureResult(baseURL: url, frames: [(url, spec)], cropInsets: crop)
                            })
                        } catch { c.resume(throwing: error) }
                    }
                    pending[settings.uniqueID] = delegate
                    output.capturePhoto(with: settings, delegate: delegate)
                } catch { c.resume(throwing: error) }
            }
        }
    }

    public static let settleTolerance: Float = 0.1, settleBiasTolerance: Float = 0.01, settleTimeout = 1.2, settlePoll = 0.1

    private func captureClosedLoopBracketFrame(ev: Double, base: ExposureReading, rotationAngle: CGFloat?) async throws -> CaptureResult {
        let target = base.bias + Float(ev)
        let applied: Float = await withCheckedContinuation { c in
            queue.async { [self] in
                guard let device, (try? device.lockForConfiguration()) != nil else { c.resume(returning: target); return }
                if device.exposureMode == .custom || device.exposureMode == .locked { device.exposureMode = .continuousAutoExposure }
                let clamped = min(max(target, device.minExposureTargetBias), device.maxExposureTargetBias)
                device.setExposureTargetBias(clamped)
                device.unlockForConfiguration()
                c.resume(returning: clamped)
            }
        }
        // keep before the await so cancelling doesnt leave the bias shifted
        defer { setExposureBias(base.bias) }
        let deadline = Date().addingTimeInterval(Self.settleTimeout)
        repeat {
            try await Task.sleep(nanoseconds: UInt64(Self.settlePoll * 1e9))
            guard let device else { break }
            let auto = device.exposureMode == .continuousAutoExposure || device.exposureMode == .autoExpose
            if !auto || (abs(device.exposureTargetOffset) <= Self.settleTolerance && abs(device.exposureTargetBias - applied) < Self.settleBiasTolerance) { break }
        } while Date() < deadline
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<CaptureResult, Error>) in
            queue.async { [self] in
                do {
                    let format = try rawFormat()
                    applyRotation(rotationAngle)
                    let now = reading()
                    let spec = BurstFrameSpec(sequence: 0, role: .base, iso: now?.iso ?? base.iso, durationSeconds: now?.duration ?? base.duration, exposureScale: pow(2, ev))
                    shoot(makeSettings(format: format, gps: nil)) { [self] result in
                        do {
                            let url = try write(result.get(), suffix: nil)
                            c.resume(returning: CaptureResult(baseURL: url, frames: [(url, spec)], cropInsets: currentCropInsets()))
                        } catch { c.resume(throwing: error) }
                    }
                } catch { c.resume(throwing: error) }
            }
        }
    }

    private func applyRotation(_ angle: CGFloat?) {
        if let angle, let connection = output.connection(with: .video),
           connection.isVideoRotationAngleSupported(angle),
           abs(connection.videoRotationAngle - angle) > 0.5 {
            connection.videoRotationAngle = angle
        }
    }

    private func selectLargestRawDimensions(_ d: AVCaptureDevice) {
        let sizes = d.activeFormat.supportedMaxPhotoDimensions.sorted { Int($0.width) * Int($0.height) > Int($1.width) * Int($1.height) }
        for size in sizes {
            output.maxPhotoDimensions = size
            if (try? rawFormat()) != nil { break }
        }
    }

    private func currentCropInsets() -> CropInsets {
        guard let device else { return CropInsets() }
        let size = device.activeFormat.formatDescription.dimensions
        return aspectRatio.centeredCropInsets(imageWidth: Double(size.width), imageHeight: Double(size.height), custom: customAspect)
    }

    private func rawFormat() throws -> OSType {
        let formats = output.availableRawPhotoPixelFormatTypes
        let match = formats.first {
            mode == .proRAW ? AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) : AVCapturePhotoOutput.isBayerRAWPixelFormat($0)
        }
        guard let match else { throw CaptureError.noRawFormat }
        return match
    }

    public func capture(hints: BurstHints = BurstHints(), rotationAngle: CGFloat? = nil, gpsMetadata: [String: Any]? = nil) async throws -> CaptureResult {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<CaptureResult, Error>) in
            queue.async { [self] in
                do {
                    guard let device else { throw CaptureError.noDevice }
                    let format = try rawFormat()
                    applyRotation(rotationAngle)
                    guard output.connection(with: .video)?.isActive == true else { throw CaptureError.sessionSetup("no active video connection") }
                    if mode == .proRAW || !burstEnabled {
                        let settings = makeSettings(format: format, gps: gpsMetadata, flash: true)
                        shoot(settings) { result in
                            switch result {
                            case .success(let data):
                                do {
                                    let url = try self.write(data, suffix: nil)
                                    c.resume(returning: CaptureResult(baseURL: url, frames: [(url, nil)], cropInsets: self.currentCropInsets()))
                                } catch { c.resume(throwing: error) }
                            case .failure(let e): c.resume(throwing: e)
                            }
                        }
                    } else {
                        let f = device.activeFormat
                        let limits = BurstPlanner.Limits(minISO: f.minISO, maxISO: f.maxISO,
                                                         minDuration: CMTimeGetSeconds(f.minExposureDuration), maxDuration: CMTimeGetSeconds(f.maxExposureDuration))
                        let fov = Double(f.videoFieldOfView) * .pi / 180
                        // blur is judged in output pixels, super res upscales the crop up to 2x
                        let srScale = zoomCropFactor >= BurstZoom.superResCrop ? min(zoomCropFactor, 2) : 1
                        let night = nightBursts && fov > 0 && !manual.exposureManual
                            ? NightBurst(rotationRate: motionGate.rotationRate, pixelsPerRadian: Double(output.maxPhotoDimensions.width) / fov * srScale) : nil
                        let zoom = BurstZoom(cropFactor: zoomCropFactor,
                                             focalLength: Double(CameraLens.equivalentFocalLength(horizontalFOVDegrees: Double(f.videoFieldOfView))) * zoomCropFactor,
                                             rotationRate: motionGate.rotationRate,
                                             pixelsPerRadian: fov > 0 ? Double(output.maxPhotoDimensions.width) / fov * srScale : 0)
                        meterLog.notice("[Burst] meter locked ISO \(Int(device.iso), privacy: .public) @ 1/\(Int((1 / max(CMTimeGetSeconds(device.exposureDuration), 1e-6)).rounded()), privacy: .public), bias \(String(format: "%+.2f", device.exposureTargetBias), privacy: .public) (offset \(String(format: "%+.2f", device.exposureTargetOffset), privacy: .public), adjusting \(device.isAdjustingExposure ? 1 : 0, privacy: .public), mode \(device.exposureMode.rawValue, privacy: .public))")
                        let plan = BurstPlanner.plan(iso: device.iso, duration: CMTimeGetSeconds(device.exposureDuration), limits: limits,
                                                     hints: hints, highlightRetentionStops: highlightRetentionStops, night: night,
                                                     zoom: manual.exposureManual ? nil : zoom)
                        runBurst(plan, format: format, gps: gpsMetadata, continuation: c)
                    }
                } catch { c.resume(throwing: error) }
            }
        }
    }

    private func makeSettings(format: OSType, gps: [String: Any]?, flash: Bool = false) -> AVCapturePhotoSettings {
        let s = AVCapturePhotoSettings(rawPixelFormatType: format, rawFileType: .dng, processedFormat: nil, processedFileType: nil)
        s.flashMode = flash && output.supportedFlashModes.contains(flashMode) ? flashMode : .off
        prepare(s)
        apply(gps, to: s)
        return s
    }
    private func prepare(_ s: AVCapturePhotoSettings) {
        s.maxPhotoDimensions = output.maxPhotoDimensions
        if #available(iOS 18.0, *), muteShutter, output.isShutterSoundSuppressionSupported { s.isShutterSoundSuppressionEnabled = true }
        if s.availableRawEmbeddedThumbnailPhotoCodecTypes.contains(.jpeg) {
            s.rawEmbeddedThumbnailPhotoFormat = [AVVideoCodecKey: AVVideoCodecType.jpeg, AVVideoWidthKey: 1536, AVVideoHeightKey: 1536]
        }
    }
    private func apply(_ gps: [String: Any]?, to s: AVCapturePhotoSettings) {
        guard let gps else { return }
        var m = s.metadata
        m[kCGImagePropertyGPSDictionary as String] = gps
        s.metadata = m
    }

    private func runBurst(_ plan: [BurstFrameSpec], format: OSType, gps: [String: Any]?, continuation c: CheckedContinuation<CaptureResult, Error>) {
        let maxChunk = max(output.maxBracketedCapturePhotoCount, 1)
        let chunks = stride(from: 0, to: plan.count, by: maxChunk).map { Array(plan[$0..<min($0 + maxChunk, plan.count)]) }
        let run = BurstRun()
        let fov = device.map { Double($0.activeFormat.videoFieldOfView) } ?? 0
        let width = Int(output.maxPhotoDimensions.width)
        @Sendable func record(_ url: URL, _ spec: BurstFrameSpec, at time: Double?) {
            guard let time, time.isFinite,
                  let px = motionGate.blurPixels(from: time, to: time + spec.durationSeconds, horizontalFOVDegrees: fov, imageWidth: width) else { return }
            run.blur[url.lastPathComponent] = px
        }
        @Sendable func fail(_ error: Error) {
            restoreAutoExposure()
            if let base = run.frames.first(where: { $0.spec?.role == .base }) ?? run.frames.first {
                var result = CaptureResult(baseURL: base.url, frames: run.frames, cropInsets: currentCropInsets())
                result.blurPixels = run.blur
                c.resume(returning: result)
            } else {
                c.resume(throwing: error)
            }
        }
        @Sendable func next(_ index: Int) {
            guard index < chunks.count else {
                let base = run.frames.first { $0.spec?.role == .base } ?? run.frames.first
                if let base {
                    restoreAutoExposure()
                    var result = CaptureResult(baseURL: base.url, frames: run.frames, cropInsets: currentCropInsets())
                    result.blurPixels = run.blur
                    c.resume(returning: result)
                } else { c.resume(throwing: CaptureError.noData) }
                return
            }
            let chunk = chunks[index]
            if maxChunk < 2 {
                setExposure(chunk[0]) { [self] in
                    let single = makeSettings(format: format, gps: gps)
                    shoot(single) { [self] result in
                        do {
                            let data = try result.get()
                            let url = try write(data, suffix: "f\(chunk[0].sequence)")
                            run.frames.append((url, chunk[0]))
                            record(url, chunk[0], at: lastShotTime)
                            queue.async { next(index + 1) }
                        } catch { fail(error) }
                    }
                }
                return
            }
            let brackets = chunk.map {
                AVCaptureManualExposureBracketedStillImageSettings.manualExposureSettings(
                    exposureDuration: CMTime(seconds: $0.durationSeconds, preferredTimescale: 1_000_000), iso: $0.iso)
            }
            let settings = AVCapturePhotoBracketSettings(rawPixelFormatType: format, rawFileType: .dng, processedFormat: nil, processedFileType: nil, bracketedSettings: brackets)
            settings.flashMode = .off
            prepare(settings)
            apply(gps, to: settings)
            if output.isLensStabilizationDuringBracketedCaptureSupported { settings.isLensStabilizationEnabled = true }
            let delegate = BurstDelegate(queue: queue) { [self] result in
                let times = pending[settings.uniqueID]?.times ?? []
                pending[settings.uniqueID] = nil
                switch result {
                case .failure(let e): fail(e)
                case .success(let datas):
                    do {
                        for (i, data) in datas.enumerated() {
                            let spec = chunk[min(i, chunk.count - 1)]
                            let url = try write(data, suffix: "f\(spec.sequence)")
                            run.frames.append((url, spec))
                            record(url, spec, at: i < times.count ? times[i] : nil)
                        }
                        queue.async { next(index + 1) }
                    } catch { fail(error) }
                }
            }
            pending[settings.uniqueID] = delegate
            output.capturePhoto(with: settings, delegate: delegate)
        }
        next(0)
    }

    private func setExposure(_ spec: BurstFrameSpec, then body: @escaping () -> Void) {
        guard let device, (try? device.lockForConfiguration()) != nil else { queue.async(execute: body); return }
        device.setExposureModeCustom(duration: CMTime(seconds: spec.durationSeconds, preferredTimescale: 1_000_000), iso: spec.iso) { [queue] _ in
            queue.async(execute: body)
        }
        device.unlockForConfiguration()
    }

    private func restoreAutoExposure() {
        guard let device, device.exposureMode == .custom, (try? device.lockForConfiguration()) != nil else { return }
        if manual.exposureManual { applyManualExposure(device) }
        else if exposureLocked { shiftLocked(device, bias: currentBias) } else { device.exposureMode = .continuousAutoExposure }
        device.unlockForConfiguration()
    }

    private func shoot(_ settings: AVCapturePhotoSettings, completion: @escaping (Result<Data, Error>) -> Void) {
        let delegate = BurstDelegate(queue: queue) { [self] result in
            lastShotTime = pending[settings.uniqueID]?.times.first
            pending[settings.uniqueID] = nil
            completion(result.flatMap { $0.first.map { .success($0) } ?? .failure(CaptureError.noData) })
        }
        pending[settings.uniqueID] = delegate
        output.capturePhoto(with: settings, delegate: delegate)
    }

    private func write(_ data: Data, suffix: String?) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = UUID().uuidString + (suffix.map { "_\($0)" } ?? "") + ".dng"
        let url = directory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }
}

extension CameraCapture: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frameIndex += 1
        if frameIndex % 6 == 0, let stats = FrameStats.measure(buffer, time: ProcessInfo.processInfo.systemUptime) {
            statsLock.lock(); latestStats = stats; statsLock.unlock()
            onStats?(stats)
        }
        onFrame?(buffer)
    }
}

private final class BurstRun: @unchecked Sendable {
    var frames: [(url: URL, spec: BurstFrameSpec?)] = []
    var blur: [String: Float] = [:]
}

private final class BurstDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let queue: DispatchQueue
    private var datas: [Int: Data] = [:]
    private(set) var times: [Double] = []
    private var stamps: [Int: Double] = [:]
    private var error: Error?
    private let completion: (Result<[Data], Error>) -> Void
    init(queue: DispatchQueue, completion: @escaping (Result<[Data], Error>) -> Void) {
        self.queue = queue; self.completion = completion
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error { self.error = error; return }
        guard photo.isRawPhoto, let data = photo.fileDataRepresentation() else { return }
        datas[photo.sequenceCount] = data
        stamps[photo.sequenceCount] = CMTimeGetSeconds(photo.timestamp)
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        let result: Result<[Data], Error>
        if let e = error ?? self.error {
            result = .failure(CaptureError.underlying(e))
        } else {
            let ordered = datas.keys.sorted().compactMap { datas[$0] }
            times = datas.keys.sorted().map { stamps[$0] ?? .nan }
            result = ordered.isEmpty ? .failure(CaptureError.noData) : .success(ordered)
        }
        queue.async { self.completion(result) }
    }
}
extension CameraCapture: AVCaptureMetadataOutputObjectsDelegate {
    public func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let code = objects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first, !code.isEmpty else { return }
        onCode?(code)
    }
}

private actor NativeBracket {
    private var task: Task<[CaptureResult], Error>?
    func frame(_ index: Int, start: @escaping @Sendable () async throws -> [CaptureResult]) async throws -> CaptureResult {
        if task == nil { task = Task { try await start() } }
        let all = try await task!.value
        guard index < all.count else { throw CaptureError.noData }
        return all[index]
    }
    var finished: [CaptureResult]? { get async { try? await task?.value } }
}
#endif
