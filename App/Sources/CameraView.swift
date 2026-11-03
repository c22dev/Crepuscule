// Crepuscule - CameraView.swift
// Constantin Clerc (c22dev) - 0.1
import AVKit
import Crepuscule
import SwiftUI

struct CameraView: View {
    @Bindable var model: CameraModel
    let library: Library
    let hero: Namespace.ID
    let captureEnabled: Bool
    let openLibrary: () -> Void
    let openSettings: () -> Void
    @State private var display = ViewfinderDisplay()
    @State private var ambientDisplay = ViewfinderDisplay(fixedSize: CGSize(width: AmbientGrid.width * 2, height: AmbientGrid.height * 2))
    @AppStorage("lensReadout") private var readout = LensReadout.focal.rawValue
    @Namespace private var glass

    var body: some View {
        ZStack {
            Ink.ground.ignoresSafeArea()
            switch model.phase {
            case .denied: PermissionView()
            case .failed(let message):
                ContentUnavailableView("The camera didn't start", systemImage: "camera.fill", description: Text(message))
            default: layout
            }
        }
        .onAppear { model.pump.display = display; model.pump.ambientDisplay = ambientDisplay }
        .onCameraCaptureEvent(isEnabled: captureEnabled && model.live, defaultSoundDisabled: model.muteShutter) { event in
            if event.phase == .ended { model.pressShutter() }
        }
        .onChange(of: model.controlState) { model.syncControls() }
    }

    private var layout: some View {
        VStack(spacing: 0) {
            GlassEffectContainer(spacing: 10) { topRow.padding(.horizontal, 16) }
                .opacity(model.controlsFullscreen ? 0 : 1)
            ViewfinderPane(model: model, display: display)
                .overlay(alignment: .topTrailing) { readoutChip.padding(10).allowsHitTesting(false) }
                .padding(.top, 10)
            LensPill(model: model, readout: LensReadout(rawValue: readout) ?? .focal).padding(.top, 12)
                .opacity(model.controlsFullscreen ? 0 : 1)
            bottomRow.padding(.top, 18).padding(.bottom, 20)
        }
        .ignoresSafeArea(edges: .bottom)
        .animation(Motion.snappy, value: model.controlsFullscreen)
        .background { AmbientBackdrop(display: ambientDisplay).ignoresSafeArea() }
    }

    private var lookMenu: some View {
        Menu {
            Toggle("Show on Viewfinder", isOn: $model.showLook)
            Section("Look for New Photos") {
                ForEach(model.looks, id: \.name) { look in
                    Button { model.chooseLook(look.grade) } label: {
                        if model.defaultLook == look.grade { Label(look.name, systemImage: "checkmark") } else { Text(look.name) }
                    }
                }
            }
        } label: {
            Image(systemName: "camera.filters")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(model.showLook ? Ink.ember : Ink.paper)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Look")
    }

    private var topRow: some View {
        HStack(spacing: 8) {
            Button { cycleFlash() } label: {
                Image(systemName: flashSymbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(model.flashMode == .off ? Ink.paper : Ink.ember)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .disabled(model.isFront)
            .opacity(model.isFront ? 0.4 : 1)
            .accessibilityLabel("Flash \(flashName)")
            Menu {
                Picker("Aspect Ratio", selection: Binding(get: { model.aspect }, set: { model.setAspect($0) })) {
                    ForEach(AspectRatioPreset.pickable, id: \.self) { Text("\($0.label)  \($0.figure)").tag($0) }
                }
            } label: {
                HStack(spacing: 7) {
                    let r = model.aspect.ratio().map { max($0, 1 / $0) } ?? 4.0 / 3
                    RoundedRectangle(cornerRadius: Radius.glyph - 0.5).stroke(lineWidth: 1.5)
                        .frame(width: 17, height: 17 / r)
                        .frame(width: 18, height: 14)
                        .animation(.snappy, value: model.aspect)
                    Text(model.aspect.figure).font(.instrument(13))
                }
                .frame(minHeight: 44).padding(.horizontal, 14)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive())
            .accessibilityLabel("Aspect ratio, \(model.aspect.label)")
            lookMenu
            Spacer()
            Menu {
                Section("Drive") {
                    Picker("Drive", selection: $model.drive) {
                        ForEach(DriveMode.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    }
                }
                Section("Timer") {
                    Picker("Timer", selection: $model.timer) {
                        Text("Off").tag(SelfTimer.off)
                        Text("3 Seconds").tag(SelfTimer.three)
                        Text("10 Seconds").tag(SelfTimer.ten)
                    }
                }
            } label: {
                Image(systemName: driveSymbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(driveActive || model.timer != .off ? Ink.ember : Ink.paper)
                    .contentTransition(.symbolEffect(.replace))
                    .animation(Motion.snappy, value: driveSymbol)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("Drive \(model.drive.title), timer \(model.timer == .off ? "off" : "\(model.timer.rawValue) seconds")")
            Button(action: openSettings) {
                Image(systemName: "gearshape").font(.system(size: 16, weight: .medium)).frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("Settings")
        }
    }

    private var readoutChip: some View {
        VStack(spacing: 1) {
            HStack(spacing: 3) {
                if status == nil && model.nightActive { Image(systemName: "moon.fill").accessibilityLabel("Night burst") }
                Text(topLine)
            }
            .engraved(size: 8.5).foregroundStyle(status == nil && model.nightActive ? Ink.ember : .white.opacity(0.7))
                .contentTransition(.interpolate)
            Text(bottomLine).font(.instrument(14, weight: .semibold)).tracking(Tracking.tight)
                .foregroundStyle(status == nil ? Ink.paper : Ink.ember)
                .contentTransition(.numericText(countsDown: counting))
        }
        .animation(Motion.snappy, value: status?.1)
        .frame(minWidth: 64, minHeight: 44).padding(.horizontal, Space.s + 2)
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.chip))
    }

    private var flashSymbol: String {
        switch model.flashMode {
        case .on: return "bolt.fill"
        case .auto: return "bolt.badge.automatic"
        default: return "bolt.slash"
        }
    }
    private var flashName: String {
        switch model.flashMode { case .on: return "on"; case .auto: return "auto"; default: return "off" }
    }
    private func cycleFlash() {
        switch model.flashMode {
        case .off: model.flashMode = .auto
        case .auto: model.flashMode = .on
        default: model.flashMode = .off
        }
        Haptics.tick()
    }

    private var driveActive: Bool { model.drive != .single }
    private var driveSymbol: String {
        if model.timer == .three { return "3.circle" }
        if model.timer == .ten { return "10.circle" }
        return driveActive ? model.drive.symbol : "timer"
    }

    private var status: (String, String)? {
        switch model.progress {
        case .steadying: return ("HOLD", "STILL")
        case .shot(let i, let n) where n > 1: return ("FRAME", "\(i)/\(n)")
        case .countdown(let n): return ("TIMER", "\(n)")
        default: return nil
        }
    }
    private var counting: Bool { if case .countdown = model.progress { true } else { false } }
    private var topLine: String { status?.0 ?? "ISO \(Int(model.reading.iso))" }
    private var bottomLine: String { status?.1 ?? ExposureText.shutter(model.reading.duration) }

    private var bottomRow: some View {
        HStack {
            NewestPhotoButton(library: library, hero: hero, action: openLibrary)
            Spacer()
            ShutterButton(model: model)
            Spacer()
            Button { model.flipCamera() } label: {
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 17))
                    .symbolEffect(.rotate.clockwise, options: .speed(1.6), value: model.flips)
                    .frame(width: 48, height: 48)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .frame(width: 76)
            .disabled(model.frontLens == nil)
            .accessibilityLabel(model.isFront ? "Switch to back camera" : "Switch to front camera")
        }
        .padding(.horizontal, 22)
    }
}

private struct ViewfinderPane: View {
    @Bindable var model: CameraModel
    let display: ViewfinderDisplay
    @State private var focus: CGPoint?
    @State private var focusStamp = 0
    @State private var lockedAt = Date.distantPast
    @State private var pinching = false
    @State private var startBias: Float?
    @AppStorage("showHistogram") private var showHistogram = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let w = min(geo.size.width, geo.size.height * 3 / 4)
            let box = CGSize(width: w, height: w * 4 / 3)
            ZStack {
                Group {
                    if !model.showLook, model.phase == .running, let session = model.captureSession, let queue = model.sessionQueue {
                        PreviewLayerView(session: session, sessionQueue: queue, angle: model.previewAngle, lensID: model.active?.deviceID)
                            .scaleEffect(model.active?.cropFactor ?? 1)
                            .animation(Motion.smooth, value: model.active?.cropFactor)
                    } else {
                        ViewfinderSurface(display: display)
                    }
                }
                    .blur(radius: model.switching ? 20 : 0)
                    .scaleEffect(model.switching && !reduceMotion ? 1.04 : 1)
                    .animation(Motion.smooth, value: model.switching)
                FrameMask(ratio: model.aspect.screenRatio(landscapeHold: model.landscapeHold))
                    .fill(Color.black.opacity(0.72), style: FillStyle(eoFill: true))
                    .animation(Motion.smooth, value: model.aspect)
                    .allowsHitTesting(false)
                if model.showGrid {
                    ThirdsGrid(ratio: model.aspect.screenRatio(landscapeHold: model.landscapeHold))
                        .stroke(.white.opacity(0.35), lineWidth: 0.5)
                        .animation(Motion.smooth, value: model.aspect)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
                Color.black.opacity(model.flash ? 0.85 : 0)
                    .animation(model.flash ? nil : .easeOut(duration: 0.22), value: model.flash)
                    .allowsHitTesting(false)
                if let focus {
                    FocusMark().position(focus).id(focusStamp).allowsHitTesting(false)
                }
                if startBias != nil || model.bias != 0 {
                    BiasScale(bias: model.bias).frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 10).allowsHitTesting(false)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
                if case .countdown(let n) = model.progress {
                    Text("\(n)").font(.instrument(120, weight: .ultraLight)).tracking(Tracking.tight).foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 12)
                        .contentTransition(.numericText(countsDown: true)).animation(Motion.snappy, value: n)
                        .transition(.scale(scale: 1.4).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
                if showHistogram { VStack {
                    Spacer()
                    HStack {
                        Histogram(stats: model.stats)
                            .frame(width: 64, height: 24)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .glassEffect(.regular, in: .rect(cornerRadius: Radius.plate))
                        Spacer()
                    }
                }
                .padding(10)
                .allowsHitTesting(false) }
                if model.exposureLocked {
                    VStack {
                        Button {
                            lockedAt = Date()
                            model.unlockExposure()
                            Haptics.tick()
                        } label: {
                            Label("AE Lock", systemImage: "lock.fill").engraved(.caption2)
                                .foregroundStyle(Ink.ember).padding(.horizontal, 10).frame(minHeight: 32)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .padding(.top, 10)
                        .accessibilityHint("Unlocks exposure")
                        Spacer()
                    }
                    .transition(.opacity)
                }
                if let code = model.scannedCode, model.notice == nil {
                    let system = model.codeAction
                    VStack {
                        Spacer()
                        Button {
                            Haptics.tick()
                            if let system { system.perform() } else { performFallback(code) }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: system?.systemImage ?? code.systemImage).font(.body.weight(.medium)).frame(width: 22)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(system?.title ?? code.title).font(.footnote.weight(.semibold)).lineLimit(1)
                                    if let sub = system?.subtitle ?? code.subtitle {
                                        Text(sub).font(.caption2).foregroundStyle(.black.opacity(0.6)).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if let system, system.hasMoreOptions {
                                Button("More Options", systemImage: "ellipsis.circle") { system.showOptions() }
                            }
                            if case .wifi(_, let password?, _, _) = code.kind {
                                Button("Copy Password", systemImage: "key") { UIPasteboard.general.string = password }
                            }
                            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = code.raw }
                            ShareLink(item: code.raw)
                        }
                        .animation(Motion.snappy, value: system?.title)
                        .foregroundStyle(.black)
                        .background(Color(red: 1, green: 0.78, blue: 0.04), in: .rect(cornerRadius: Radius.chip))
                        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
                        .padding(.bottom, 56).padding(.horizontal, 24)
                    }
                    .transition(.rise)
                }
                if let notice = model.notice {
                    VStack {
                        Spacer()
                        Button { model.notice = nil } label: {
                            Text(notice).font(.footnote.weight(.medium)).padding(.horizontal, 14).padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(in: .rect(cornerRadius: Radius.chip))
                        .padding(.bottom, 56)
                    }
                    .transition(.rise)
                    .task(id: notice) {
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        model.notice = nil
                    }
                }
            }
            .animation(Motion.snappy, value: model.notice)
            .animation(Motion.fade, value: startBias != nil || model.bias != 0)
            .animation(Motion.snappy, value: model.progress.map { if case .countdown = $0 { true } else { false } } ?? false)
            .frame(width: box.width, height: box.height)
            .clipped()
            .keyframeAnimator(initialValue: 0.0, trigger: model.flips) { content, turn in
                content.rotation3DEffect(.degrees(reduceMotion ? 0 : (turn <= 90 ? turn : turn - 180)), axis: (0, 1, 0), perspective: 0.4)
            } keyframes: { _ in
                CubicKeyframe(0, duration: 0.01)
                CubicKeyframe(180, duration: 0.5)
            }
            .contentShape(Rectangle())
            .gesture(biasDrag)
            .simultaneousGesture(SpatialTapGesture().onEnded { tap($0.location, box) })
            .simultaneousGesture(MagnifyGesture().onChanged { v in
                if !pinching { pinching = true; model.beginZoom() }
                model.updateZoom(scale: Double(v.magnification))
            }.onEnded { _ in
                pinching = false
                model.endZoom()
            })
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.6).sequenced(before: DragGesture(minimumDistance: 0)).onEnded { v in
                if case .second(true, let drag?) = v {
                    focus = drag.location; focusStamp += 1
                    lockedAt = Date()
                    model.lockExposure(at: CGPoint(x: drag.location.x / box.width, y: drag.location.y / box.height))
                }
            })
            .position(x: geo.size.width / 2, y: box.height / 2)
        }
    }

    private func performFallback(_ code: ScannedCode) {
        if let url = code.actionURL {
            UIApplication.shared.open(url) { ok in
                if !ok { UIPasteboard.general.string = code.raw; model.notice = "Copied to clipboard" }
            }
            return
        }
        if case .wifi(let ssid, let password?, _, _) = code.kind {
            UIPasteboard.general.string = password
            model.notice = "Password for “\(ssid)” copied"
            return
        }
        UIPasteboard.general.string = code.raw
        model.notice = "Copied to clipboard"
    }

    private func tap(_ p: CGPoint, _ box: CGSize) {
        guard Date().timeIntervalSince(lockedAt) > 0.3 else { return }
        if model.exposureLocked, p.y < 50, abs(p.x - box.width / 2) < 60 { return }
        focus = p
        focusStamp += 1
        model.focus(at: CGPoint(x: p.x / box.width, y: p.y / box.height))
        Haptics.tick()
    }

    private var biasDrag: some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { v in
                guard abs(v.translation.height) > abs(v.translation.width) || startBias != nil else { return }
                let start = startBias ?? model.bias
                startBias = start
                let stepped = ((start - Float(v.translation.height / 110)) * 10).rounded() / 10
                if stepped != model.bias {
                    if stepped == 0 { Haptics.bump() }
                    model.setBias(stepped)
                }
            }
            .onEnded { _ in startBias = nil }
    }
}

struct Histogram: View {
    let stats: FrameStats
    var body: some View {
        Canvas { ctx, size in
            let n = stats.luma.count
            let w = size.width / CGFloat(n)
            for (i, v) in stats.luma.enumerated() {
                let h = max(CGFloat(v) * size.height, 0.5)
                let clipping = i >= n - 2 && stats.hardClipFraction > 0.005
                ctx.fill(Path(CGRect(x: CGFloat(i) * w, y: size.height - h, width: max(w - 0.3, 0.6), height: h)),
                         with: .color(clipping ? Ink.ember : .white.opacity(0.85)))
            }
        }
        .accessibilityLabel(stats.hardClipFraction > 0.005 ? "Histogram, highlights clipping" : "Histogram")
    }
}

private func openFrame(in rect: CGRect, ratio: CGFloat) -> CGRect {
    var w = rect.width, h = rect.height
    if w / h > ratio { w = h * ratio } else { h = w / ratio }
    return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
}

private struct FrameMask: Shape {
    var ratio: CGFloat
    var animatableData: CGFloat { get { ratio } set { ratio = newValue } }
    func path(in rect: CGRect) -> Path {
        var p = Path(rect)
        p.addRect(openFrame(in: rect, ratio: ratio))
        return p
    }
}

private struct ThirdsGrid: Shape {
    var ratio: CGFloat
    var animatableData: CGFloat { get { ratio } set { ratio = newValue } }
    func path(in rect: CGRect) -> Path {
        let f = openFrame(in: rect, ratio: ratio)
        var p = Path()
        for i in 1...2 {
            let x = f.minX + f.width * CGFloat(i) / 3, y = f.minY + f.height * CGFloat(i) / 3
            p.move(to: CGPoint(x: x, y: f.minY)); p.addLine(to: CGPoint(x: x, y: f.maxY))
            p.move(to: CGPoint(x: f.minX, y: y)); p.addLine(to: CGPoint(x: f.maxX, y: y))
        }
        return p
    }
}

private struct FocusMark: View {
    @State private var settled = false
    var body: some View {
        RoundedRectangle(cornerRadius: 8).stroke(Ink.ember, lineWidth: 1.5)
            .frame(width: 64, height: 64)
            .scaleEffect(settled ? 1 : 1.35).opacity(settled ? 1 : 0)
            .onAppear { withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { settled = true } }
    }
}

private struct BiasScale: View {
    let bias: Float
    var body: some View {
        VStack(spacing: 6) {
            Text(ExposureText.ev(bias)).font(.instrument(12, weight: .semibold))
                .foregroundStyle(bias == 0 ? .white : Ink.ember)
                .contentTransition(.numericText(value: Double(bias)))
                .shadow(color: .black.opacity(0.4), radius: 4)
            ZStack {
                Capsule().fill(.white.opacity(0.45)).frame(width: 2, height: 96)
                Circle().fill(Ink.ember).frame(width: 10, height: 10).offset(y: CGFloat(-bias) * 16)
            }
        }
    }
}

private struct LensPill: View {
    let model: CameraModel
    let readout: LensReadout
    @Namespace private var pill

    var body: some View {
        let current = model.active.flatMap(model.stop(for:))
        HStack(spacing: 0) {
            ForEach(model.backLenses) { lens in
                let on = lens == current
                let parts = readout.parts(on ? (model.active?.focalLength ?? lens.focalLength) : lens.focalLength)
                Button { model.select(lens) } label: {
                    VStack(spacing: -1) {
                        Text(parts.value).font(.instrument(on ? 15 : 13, weight: on ? .semibold : .medium)).tracking(Tracking.tight)
                            .minimumScaleFactor(0.7).lineLimit(1)
                            .contentTransition(.numericText())
                        if on { Text(parts.unit).engraved(size: 8).transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .top))) }
                    }
                    .foregroundStyle(on ? Ink.paper : Ink.paper.opacity(0.82))
                    .frame(width: 48, height: 48)
                    .background {
                        if on { Circle().fill(Ink.dusk).matchedGeometryEffect(id: "on", in: pill) }
                        else if model.zoomReadout == lens.focalLength, lens.cropFactor == 1 { Circle().stroke(Ink.dusk, lineWidth: 2) }
                    }
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(parts.value) \(parts.unit)")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .animation(Motion.smooth, value: current)
        .animation(Motion.snappy, value: model.active?.focalLength)
        .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { v in
            if !sliding { sliding = true; model.beginZoom() }
            model.updateZoom(scale: pow(2, Double(v.translation.width) / 120))
        }.onEnded { _ in
            sliding = false
            model.endZoom()
        })
        .padding(3)
        .glassEffect()
        .animation(Motion.snappy, value: model.zoomReadout)
    }

    @State private var sliding = false
}

struct DuskSweep: Shape {
    var fraction: CGFloat
    var wedge = false
    var animatableData: CGFloat {
        get { fraction }
        set { fraction = newValue }
    }
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let f = min(max(fraction, 0), 1)
        guard f > 0 else { return p }
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let start = Angle.degrees(-90), end = Angle.degrees(-90 + 360 * Double(f))
        if wedge {
            p.move(to: c)
            p.addArc(center: c, radius: hypot(rect.width, rect.height), startAngle: start, endAngle: end, clockwise: false)
            p.closeSubpath()
        } else {
            p.addArc(center: c, radius: min(rect.width, rect.height) / 2, startAngle: start, endAngle: end, clockwise: false)
        }
        return p
    }
}

struct ShutterButton: View {
    let model: CameraModel
    @GestureState private var pressed = false

    private enum Edge: Equatable { case none, locked, night }

    private var fraction: CGFloat {
        switch model.progress {
        case .shot(let i, let n): return CGFloat(i) / CGFloat(max(n, 1))
        case .countdown(let n): return 1 - CGFloat(n - 1) / CGFloat(max(model.timer.rawValue, 1))
        default: return 0
        }
    }
    private var showsProgress: Bool {
        switch model.progress {
        case .countdown, .steadying: return true
        case .shot(_, let n): return n > 1 || model.timer != .off
        case nil: return false
        }
    }
    private var sequence: Bool { model.firing && (model.timer != .off || model.drive != .single) }
    private var capturing: Bool { model.firing && !sequence }
    private var edge: Edge {
        if model.firing || showsProgress { return .none }
        if model.exposureLocked { return .locked }
        if model.nightActive { return .night }
        return .none
    }

    var body: some View {
        ZStack {
            Circle().fill(Color(white: 0.16)).frame(width: 86, height: 86)
            Circle().strokeBorder(Color(red: 0.72, green: 0.78, blue: 1).opacity(0.16), lineWidth: 9)
                .frame(width: 86, height: 86)
                .opacity(edge == .night ? 1 : 0)
            Image(systemName: "moon.fill")
                .font(.system(size: 7.5, weight: .semibold))
                .foregroundStyle(Ink.paper.opacity(0.85))
                .offset(y: -38.5)
                .opacity(edge == .night ? 1 : 0)
            Circle().strokeBorder(Ink.ember.opacity(0.9), lineWidth: 2)
                .frame(width: 86, height: 86)
                .opacity(edge == .locked ? 1 : 0)
            Circle().stroke(Ink.paper.opacity(0.12), lineWidth: 4)
                .frame(width: 80, height: 80)
                .opacity(showsProgress ? 1 : 0)
            DuskSweep(fraction: showsProgress ? fraction : 0)
                .stroke(Ink.duskRing, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .frame(width: 80, height: 80)
                .shadow(color: Ink.dusk.opacity(showsProgress ? 0.45 : 0), radius: 5)
                .animation(.easeInOut(duration: 0.4), value: fraction)
            RoundedRectangle(cornerRadius: sequence ? 6 : 34, style: .continuous)
                .fill(.white)
                .frame(width: sequence ? 28 : 68, height: sequence ? 28 : 68)
                .opacity(capturing ? 0.8 : 1)
                .scaleEffect(pressed ? 0.88 : capturing ? 0.84 : 1)
                .animation(.spring(response: 0.26, dampingFraction: 0.72), value: pressed)
                .animation(.spring(response: 0.22, dampingFraction: 0.7), value: capturing)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: sequence)
        }
        .animation(Motion.fade, value: edge)
        .animation(Motion.fade, value: showsProgress)
        .frame(width: 88, height: 88)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0).updating($pressed) { _, s, _ in s = true }.onEnded { _ in model.pressShutter() })
        .accessibilityElement()
        .accessibilityLabel(sequence ? "Stop" : "Shutter")
        .accessibilityValue(accessibilityState)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.pressShutter() }
    }

    private var accessibilityState: String {
        switch model.progress {
        case .countdown(let n): return "Timer, \(n)"
        case .steadying: return "Hold still"
        case .shot(let i, let n) where n > 1: return "Shot \(i) of \(n)"
        default: break
        }
        if capturing { return "Capturing" }
        switch edge {
        case .locked: return "Exposure locked"
        case .night: return "Night burst"
        case .none: return ""
        }
    }
}

struct NewestPhotoButton: View {
    static let heroID = "newest-photo"
    let library: Library
    let hero: Namespace.ID
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ringFraction: CGFloat = 0
    @State private var ringOpacity: Double = 0
    @State private var popScale: CGFloat = 1
    @State private var ringRun = 0

    private var mergingID: UUID? {
        guard let id = library.newest?.id, library.merging.contains(id) else { return nil }
        return id
    }

    var body: some View {
        let shape = ConcentricRectangle(uniformTopCorners: .fixed(Radius.thumb), bottomLeadingCorner: .concentric(minimum: .fixed(Radius.thumb)), bottomTrailingCorner: .fixed(Radius.thumb))
        Button(action: action) {
            ZStack {
                Ink.raised
                if let id = library.newest?.id, let image = library.thumbnail(id) {
                    Image(uiImage: image).resizable().scaledToFill().id(id)
                        .transition(.asymmetric(insertion: .scale(scale: 1.6).combined(with: .opacity), removal: .opacity))
                }
            }
            .frame(width: 76, height: 76)
            .clipShape(shape)
            .overlay(shape.stroke(Color(white: 0.32), lineWidth: 2.5))
            .overlay {
                shape.stroke(Ink.duskRing, lineWidth: 2.5)
                    .mask(DuskSweep(fraction: ringFraction, wedge: true))
                    .shadow(color: Ink.dusk.opacity(0.5), radius: 3)
                    .opacity(ringOpacity)
                    .allowsHitTesting(false)
            }
            .contentShape(shape)
            .animation(Motion.smooth, value: library.newest?.id)
            .matchedTransitionSource(id: Self.heroID, in: hero) { $0.clipShape(RoundedRectangle(cornerRadius: Radius.thumb, style: .continuous)) }
            .keyframeAnimator(initialValue: 1.0, trigger: library.newest?.id) { content, scale in
                content.scaleEffect(reduceMotion ? 1 : scale)
            } keyframes: { _ in
                SpringKeyframe(0.86, duration: 0.12, spring: .snappy)
                SpringKeyframe(1.0, duration: 0.45, spring: .bouncy(duration: 0.45, extraBounce: 0.15))
            }
            .scaleEffect(popScale)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open newest photo")
        .accessibilityValue(mergingID != nil ? "Merging burst" : "")
        .onChange(of: mergingID, initial: true) { old, new in
            if let new {
                if new != old || ringOpacity == 0 { startRing(new) }
            } else if let old {
                if library.newest?.id == old, library.item(old)?.mergeAlg != nil { finishRing() } else { hideRing() }
            }
        }
    }

    private func startRing(_ id: UUID) {
        ringRun += 1
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { ringFraction = 0 }
        let run = ringRun
        let item = library.item(id)
        let frames = Double(item?.frameCount ?? 4)
        let expected = item?.isNightBurst == true ? max(6, frames * 0.4) : (item?.cropFactor ?? 1) >= 1.95 ? 4.5 : 3
        Task { @MainActor in
            guard run == ringRun else { return }
            withAnimation(Motion.fade) { ringOpacity = reduceMotion ? 0.7 : 1 }
            if reduceMotion {
                ringFraction = 1
            } else {
                withAnimation(.timingCurve(0.2, 0.7, 0.3, 1, duration: expected)) { ringFraction = 0.9 }
            }
        }
    }

    private func finishRing() {
        ringRun += 1
        let run = ringRun
        withAnimation(.easeOut(duration: 0.3)) { ringFraction = 1; ringOpacity = 1 }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if !reduceMotion {
            withAnimation(Motion.pop) { popScale = 1.06 }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(160))
            withAnimation(Motion.pop) { popScale = 1 }
            try? await Task.sleep(for: .milliseconds(340))
            guard run == ringRun else { return }
            withAnimation(.easeOut(duration: 0.5)) { ringOpacity = 0 }
        }
    }

    private func hideRing() {
        ringRun += 1
        withAnimation(Motion.fade) { ringOpacity = 0 }
    }
}

private struct PermissionView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Camera Access", systemImage: "camera.fill")
        } description: {
            Text("Turn on camera access to shoot RAW.")
        } actions: {
            Button("Open Settings") {
                if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
            }
            .buttonStyle(.glassProminent).tint(Ink.dusk)
        }
    }
}
