// Crepuscule - MotionGate.swift
// Constantin Clerc (c22dev) - 0.1
#if os(iOS)
import CoreMotion
import Foundation

public final class MotionGate: @unchecked Sendable {
    private let manager = CMMotionManager()
    private let opQueue = OperationQueue()
    private let lock = NSLock()
    private var detector = StillnessDetector()
    private var history = MotionHistory()

    public init() {}

    public func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 60
        manager.startDeviceMotionUpdates(to: opQueue) { [weak self] motion, _ in
            guard let self, let r = motion?.rotationRate else { return }
            let t = motion?.timestamp ?? ProcessInfo.processInfo.systemUptime
            lock.lock(); detector.add(rotationRate: r.x, r.y, r.z); history.add(time: t, rate: (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot()); lock.unlock()
        }
    }

    public func stop() {
        manager.stopDeviceMotionUpdates()
        lock.lock(); detector = StillnessDetector(); history = MotionHistory(); lock.unlock()
    }

    public var rotationRate: Double? { lock.withLock { detector.rmsRate } }

    public func blurPixels(from start: Double, to end: Double, horizontalFOVDegrees fov: Double, imageWidth: Int) -> Float? {
        let angle = lock.withLock { history.angle(from: start, to: end) }
        guard let angle, fov > 0 else { return nil }
        return Float(angle * Double(imageWidth) / (fov * .pi / 180))
    }

    public func waitUntilStill(duration: Double, horizontalFOVDegrees fov: Double, imageWidth: Int, timeout: Double = 0.6) async {
        guard manager.isDeviceMotionAvailable else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !Task.isCancelled {
            let still = lock.withLock { detector.isStill(duration: duration, horizontalFOVDegrees: fov, imageWidth: imageWidth) }
            if still { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
#endif
