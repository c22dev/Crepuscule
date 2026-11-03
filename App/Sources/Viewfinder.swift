// Crepuscule - Viewfinder.swift
// Constantin Clerc (c22dev) - 0.1
import AVFoundation
import CoreImage
import MetalKit
import SwiftUI

final class ViewfinderDisplay: NSObject, MTKViewDelegate, @unchecked Sendable {
    let view: MTKView
    private let queue: MTLCommandQueue
    private let context: CIContext
    private let lock = NSLock()
    private var latest: CIImage?
    private let space = CGColorSpaceCreateDeviceRGB()

    init(fixedSize: CGSize? = nil) {
        let device = MTLCreateSystemDefaultDevice()!
        view = MTKView(frame: .zero, device: device)
        queue = device.makeCommandQueue()!
        context = CIContext(mtlDevice: device, options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])
        super.init()
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.autoResizeDrawable = fixedSize == nil
        if let fixedSize { view.drawableSize = fixedSize }
        view.backgroundColor = .black
        view.isOpaque = true
        view.delegate = self
    }

    func show(_ image: CIImage) {
        lock.withLock { latest = image }
        DispatchQueue.main.async { [weak self] in self?.view.draw() }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let image = lock.withLock({ latest }), let drawable = view.currentDrawable, let cb = queue.makeCommandBuffer() else { return }
        let size = view.drawableSize
        let e = image.extent
        guard e.width > 0, e.height > 0, size.width > 0 else { return }
        let s = max(size.width / e.width, size.height / e.height)
        let scaled = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY).scaledBy(x: 1, y: 1))
            .transformed(by: CGAffineTransform(scaleX: s, y: s))
        let placed = scaled.transformed(by: CGAffineTransform(translationX: (size.width - e.width * s) / 2, y: (size.height - e.height * s) / 2))
        context.render(placed, to: drawable.texture, commandBuffer: cb, bounds: CGRect(origin: .zero, size: size), colorSpace: space)
        cb.present(drawable)
        cb.commit()
    }
}

struct ViewfinderSurface: UIViewRepresentable {
    let display: ViewfinderDisplay
    func makeUIView(context: Context) -> MTKView { display.view }
    func updateUIView(_ uiView: MTKView, context: Context) {}
}

struct PreviewLayerView: UIViewRepresentable {
    let session: AVCaptureSession
    let sessionQueue: DispatchQueue
    let angle: CGFloat
    let lensID: String?

    final class Host: UIView {
        private var sessionQueue: DispatchQueue?
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        func connect(to session: AVCaptureSession, on queue: DispatchQueue) {
            sessionQueue = queue
            let preview = preview
            queue.async {
                preview.session = session
            }
        }

        func rotate(to angle: CGFloat) {
            guard let sessionQueue else { return }
            let preview = preview
            sessionQueue.async {
                if let connection = preview.connection,
                   connection.isVideoRotationAngleSupported(angle), connection.videoRotationAngle != angle {
                    connection.videoRotationAngle = angle
                }
            }
        }

        func disconnect() {
            let preview = preview
            sessionQueue?.async { preview.session = nil }
        }
    }

    func makeUIView(context: Context) -> Host {
        let v = Host()
        v.backgroundColor = .black
        v.preview.videoGravity = .resizeAspectFill
        v.connect(to: session, on: sessionQueue)
        return v
    }

    func updateUIView(_ v: Host, context: Context) {
        v.rotate(to: angle)
    }

    static func dismantleUIView(_ v: Host, coordinator: ()) { v.disconnect() }
}
