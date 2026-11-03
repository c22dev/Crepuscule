// Crepuscule - EditScreen.swift
// Constantin Clerc (c22dev) - 0.1
import Crepuscule
import SwiftUI

private enum Tool: String, CaseIterable, Identifiable, Hashable {
    case looks = "Looks", tone = "Tone", color = "Color", texture = "Texture", crop = "Crop"
    var id: String { rawValue }
}

struct EditScreen: View {
    let library: Library
    let item: PhotoItem
    @State private var grade: Grade
    @State private var aspect: AspectRatioPreset
    @State private var tool = Tool.looks
    @State private var image: UIImage?
    @State private var original: UIImage?
    @State private var showOriginal = false
    @State private var confirmCancel = false
    @State private var naming = false
    @State private var lookName = ""
    @State private var fullSize: (width: Int, height: Int)?
    @State private var renderer = PreviewLoop()
    @State private var history: [Grade]
    @State private var position = 0
    @State private var dragging = false
    @State private var selected: [Tool: String] = [:]
    @Namespace private var tabMark
    @Environment(\.dismiss) private var dismiss

    init(library: Library, item: PhotoItem) {
        self.library = library
        self.item = item
        _grade = State(initialValue: item.grade)
        _aspect = State(initialValue: item.aspect)
        _history = State(initialValue: [item.grade])
    }

    private var changed: Bool { grade != item.grade }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            picture.padding(.horizontal, 16)
            tabs.padding(.top, 8)
            panel
                .id(tool)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 12)), removal: .opacity))
                .frame(height: tool == .crop ? 238 : 172, alignment: .top).padding(.bottom, 6)
        }
        .animation(Motion.smooth, value: tool)
        .background(Ink.editor.ignoresSafeArea())
        .task {
            image = library.thumbnail(item.id)
            #if targetEnvironment(simulator)
            if let name = UserDefaults.standard.string(forKey: "demoTool"), let t = Tool(rawValue: name) { tool = t }
            #endif
            renderer.onImage = { image = $0 }
            renderer.request(url: library.rawURL(item), grade: shown(grade), seed: item.seed, useDisk: library.settings.useDiskCache)
            fullSize = try? await RenderEngine.shared.fullSize(of: library.rawURL(item), useDisk: library.settings.useDiskCache)
        }
        .onChange(of: grade) { _, new in
            renderer.request(url: library.rawURL(item), grade: shown(new), seed: item.seed, useDisk: library.settings.useDiskCache)
            if !dragging { commit() }
        }
        .onChange(of: dragging) { _, now in if !now { commit() } }
        .onChange(of: tool) { old, new in
            guard old == .crop || new == .crop else { return }
            renderer.request(url: library.rawURL(item), grade: shown(grade), seed: item.seed, useDisk: library.settings.useDiskCache)
        }
        .alert("Name This Look", isPresented: $naming) {
            TextField("Name", text: $lookName)
            Button("Save") {
                let n = lookName.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { library.saveLook(named: n, grade: grade) }
                lookName = ""
            }
            Button("Cancel", role: .cancel) { lookName = "" }
        }
    }

    private func shown(_ g: Grade) -> Grade {
        guard tool == .crop else { return g }
        var full = g
        full.cropInsets = CropInsets()
        return full
    }

    private func commit() {
        guard grade != history[position] else { return }
        history = Array(history[...position]) + [grade]
        position = history.count - 1
    }

    private func step(_ d: Int) {
        position += d
        grade = history[position]
        Haptics.tick()
    }

    private var topBar: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 8) {
                Button { if changed { confirmCancel = true } else { dismiss() } } label: {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Cancel")
                .confirmationDialog("Discard your changes?", isPresented: $confirmCancel, titleVisibility: .visible) {
                    Button("Discard Changes", role: .destructive) { dismiss() }
                }
                Spacer()
                HStack(spacing: 0) {
                    Button { step(-1) } label: { Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 44) }
                        .disabled(position == 0).opacity(position == 0 ? 0.35 : 1).accessibilityLabel("Undo")
                    Button { step(1) } label: { Image(systemName: "arrow.uturn.forward").frame(width: 44, height: 44) }
                        .disabled(position >= history.count - 1).opacity(position >= history.count - 1 ? 0.35 : 1).accessibilityLabel("Redo")
                    moreMenu
                }
                .font(.system(size: 15, weight: .medium))
                .buttonStyle(.plain)
                .padding(.horizontal, 4)
                .glassEffect(.regular.interactive(), in: .capsule)
                Spacer()
                Button {
                    if changed { library.setGrade(grade, aspect: aspect, for: item.id) }
                    dismiss()
                } label: {
                    Text("Done").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                        .frame(minWidth: 62, minHeight: 44).padding(.horizontal, 4)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(Ink.dusk.opacity(0.85)).interactive(), in: .capsule)
            }
            .foregroundStyle(Ink.paper)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    private var moreMenu: some View {
        Menu {
            Button { naming = true } label: { Label("Save as Look…", systemImage: "plus") }
            Button {
                var g = grade
                g.cropInsets = CropInsets(); g.mirrored = false; g.rotationQuarterTurns = 0; g.fineRotationDegrees = 0
                library.settings.perImageDefaults = g
                Haptics.bump()
            } label: { Label("Set as Default Grade", systemImage: "checkmark.seal") }
            Button(role: .destructive) { apply(Presets.factoryDefault) } label: { Label("Reset Edits", systemImage: "arrow.counterclockwise") }
        } label: {
            Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .accessibilityLabel("More")
    }

    private func framed(_ look: Grade) -> Grade {
        var g = look
        g.cropInsets = grade.cropInsets; g.mirrored = grade.mirrored
        g.rotationQuarterTurns = grade.rotationQuarterTurns; g.fineRotationDegrees = grade.fineRotationDegrees
        return g
    }

    private func apply(_ look: Grade) {
        grade = framed(look)
        Haptics.tick()
    }

    private var lookStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(library.allLooks, id: \.name) { look in
                    LookTile(name: look.name, url: library.rawURL(item), grade: framed(look.grade), seed: item.seed,
                             useDisk: library.settings.useDiskCache, selected: framed(look.grade) == grade) { apply(look.grade) }
                }
                Button { naming = true } label: {
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: Radius.tile).stroke(Ink.line, lineWidth: 1.5)
                            .frame(width: 84, height: 112)
                            .overlay(Image(systemName: "plus").foregroundStyle(Ink.stone))
                        Text("Save").engraved(size: 9).foregroundStyle(Ink.stone)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Save as Look")
            }
            .padding(.horizontal, 16)
        }
        .padding(.top, 14)
    }

    private var picture: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .overlay {
                        if tool == .crop {
                            CropFrame(insets: grade.cropInsets)
                                .animation(Motion.smooth, value: grade.cropInsets)
                                .allowsHitTesting(false)
                                .transition(.opacity)
                        }
                    }
                if showOriginal, let original {
                    Image(uiImage: original).resizable().scaledToFit().transition(.opacity)
                }
            } else {
                ProgressView()
            }
        }
        .overlay(alignment: .top) {
            if showOriginal {
                Text("Original").engraved(.caption2).padding(.horizontal, 10).padding(.vertical, 5)
                    .glassEffect().padding(.top, 10)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: showOriginal)
        .animation(.easeInOut(duration: 0.15), value: original != nil)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.15, maximumDistance: 40) {} onPressingChanged: { pressing in
            showOriginal = pressing
            if pressing, original == nil {
                Task {
                    var g = item.grade
                    g.cropInsets = grade.cropInsets; g.mirrored = grade.mirrored
                    g.rotationQuarterTurns = grade.rotationQuarterTurns; g.fineRotationDegrees = grade.fineRotationDegrees
                    if let cg = try? await RenderEngine.shared.preview(url: library.rawURL(item), grade: g, seed: item.seed, useDisk: library.settings.useDiskCache) {
                        original = UIImage(cgImage: cg)
                    }
                }
            }
        }
        .accessibilityLabel("Photo. Press and hold to compare with the original.")
    }

    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(Tool.allCases) { t in
                let on = t == tool
                Button {
                    withAnimation(Motion.smooth) { tool = t }
                    Haptics.tick()
                } label: {
                    VStack(spacing: 7) {
                        Text(t.rawValue).engraved(.caption2).lineLimit(1).minimumScaleFactor(0.75)
                            .foregroundStyle(on ? Ink.paper : Ink.stone)
                        Color.clear.frame(width: 18, height: 2.5)
                            .matchedGeometryEffect(id: t, in: tabMark, isSource: true)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(t.rawValue)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .overlay {
            Capsule().fill(Ink.dusk)
                .matchedGeometryEffect(id: tool, in: tabMark, isSource: false)
                .allowsHitTesting(false)
        }
        .padding(.horizontal, Space.m)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tool")
    }

    private func adjustments(_ t: Tool) -> [Adjustment] {
        func pct(_ v: Float) -> String { signed(v * 100, "%+.0f") }
        switch t {
        case .looks:
            return []
        case .tone:
            return [
                Adjustment(title: "Exposure", symbol: "plusminus", value: $grade.exposureStops, range: -4...4, neutral: 0) { signed($0, "%+.1f") },
                Adjustment(title: "Contrast", symbol: "circle.lefthalf.filled", value: $grade.atanContrast, range: -4...4, neutral: 0) { signed($0, "%+.2f") },
                Adjustment(title: "Pivot", symbol: "scope", value: $grade.atanPivot, range: 0...1, neutral: 0x1.666666p-2, enabled: grade.atanContrast != 0) { String(format: "%.2f", $0) },
                Adjustment(title: "Highlights", symbol: "sun.max", value: $grade.highlights, range: -1...1, neutral: 0, text: pct),
                Adjustment(title: "Shadows", symbol: "moon", value: $grade.shadows, range: -1...1, neutral: 0, text: pct),
            ]
        case .color:
            return [
                Adjustment(title: "Temperature", symbol: "thermometer.medium", value: $grade.colorTemp, range: -0.12...0.12, neutral: 0) { signed($0 * 1000, "%+.0f") },
                Adjustment(title: "Tint", symbol: "drop", value: $grade.tint, range: -0.06...0.06, neutral: 0) { signed($0 * 1000, "%+.0f") },
                Adjustment(title: "Saturation", symbol: "paintpalette", value: $grade.saturation, range: 0...2, neutral: 1) { signed(($0 - 1) * 100, "%+.0f") },
            ]
        case .texture:
            return [
                Adjustment(title: "Grain", symbol: "circle.grid.3x3", value: $grade.grainAmplitude, range: 0...3, neutral: 1.25) { String(format: "%.2f", $0) },
                Adjustment(title: "Grain Size", symbol: "arrow.up.left.and.arrow.down.right", value: $grade.grainSize, range: 0.4...3, neutral: 1) { String(format: "%.2f", $0) },
            ]
        case .crop:
            return [Adjustment(title: "Straighten", symbol: "angle", value: Binding(get: { Float(grade.fineRotationDegrees) }, set: { grade.fineRotationDegrees = Double($0) }), range: -15...15, neutral: 0) { signed($0, "%+.1f°") }]
        }
    }

    @ViewBuilder private var panel: some View {
        if tool == .looks { lookStrip } else { adjustmentPanel }
    }

    private var adjustmentPanel: some View {
        let list = adjustments(tool)
        let current = list.first { $0.title == selected[tool] } ?? list[0]
        return VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text(current.title).engraved(.caption2).foregroundStyle(Ink.stone)
                Text(current.text(current.value.wrappedValue)).font(.instrument(.subheadline, weight: .semibold))
                    .foregroundStyle(current.value.wrappedValue == current.neutral ? Ink.paper : Ink.ember)
                    .contentTransition(.numericText(value: Double(current.value.wrappedValue)))
                    .animation(dragging ? nil : Motion.snappy, value: current.value.wrappedValue)
            }
            .animation(Motion.snappy, value: current.title)
            HStack(spacing: 10) {
                ForEach(list.filter { $0.title != "Pivot" || current.title == "Contrast" || current.title == "Pivot" }) { a in
                    AdjustmentButton(adjustment: a, selected: a.title == current.title) {
                        withAnimation(Motion.snappy) { selected[tool] = a.title }
                        Haptics.tick()
                    }
                }
                extras
            }
            .frame(maxWidth: .infinity)
            if tool == .crop { aspectRow }
            RulerScrubber(adjustment: current, dragging: $dragging)
                .id(current.title)
                .frame(height: 40)
        }
        .padding(.top, 12)
    }

    @ViewBuilder private var extras: some View {
        switch tool {
        case .color:
            ActionCircle(symbol: "circle.lefthalf.striped.horizontal", title: "Black and White", on: grade.blackAndWhite) { grade.blackAndWhite.toggle() }
        case .texture:
            ActionCircle(symbol: "squareshape.split.3x3", title: "Pixel Grain", on: grade.pixSizeGrain) { grade.pixSizeGrain.toggle() }
            Menu {
                Picker("Halation", selection: Binding(
                    get: { grade.halation.enabled ? (grade.halation.preset == .photochemical ? 1 : 2) : 0 },
                    set: {
                        grade.halation.enabled = $0 != 0
                        if $0 == 1 { grade.halation.preset = .photochemical }
                        if $0 == 2 { grade.halation.preset = .optical }
                    })) {
                    Text("Off").tag(0)
                    Text("Photochemical").tag(1)
                    Text("Optical").tag(2)
                }
            } label: {
                Image(systemName: "sparkles").font(.system(size: 17))
                    .foregroundStyle(grade.halation.enabled ? Ink.paper : Ink.stone)
                    .frame(width: 54, height: 54)
                    .overlay(Circle().stroke(Ink.line, lineWidth: 2))
            }
            .accessibilityLabel("Halation")
        case .crop:
            ActionCircle(symbol: "rotate.right", title: "Rotate", on: false) {
                grade.rotationQuarterTurns = (grade.rotationQuarterTurns + 1) % 4
                setAspect(aspect)
            }
            ActionCircle(symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", title: "Mirror", on: grade.mirrored) { grade.mirrored.toggle() }
        default:
            EmptyView()
        }
    }

    private var aspectRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(AspectRatioPreset.pickable, id: \.self) { a in
                    AspectTile(aspect: a, selected: aspect == a) { setAspect(a) }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func setAspect(_ a: AspectRatioPreset) {
        aspect = a
        guard let fullSize else { return }
        let odd = grade.rotationQuarterTurns % 2 != 0
        let w = Double(odd ? fullSize.height : fullSize.width), h = Double(odd ? fullSize.width : fullSize.height)
        grade.cropInsets = a.uprightCropInsets(imageWidth: w, imageHeight: h, cropFactor: item.superResolved == true ? 1 : (item.cropFactor ?? 1))
    }
}

private func signed(_ v: Float, _ format: String) -> String {
    let s = String(format: format, v)
    return s.trimmingCharacters(in: CharacterSet(charactersIn: "+-0.°")).isEmpty ? "0" : s
}

@MainActor
final class PreviewLoop {
    struct Request { let url: URL; let grade: Grade; let seed: Float; let useDisk: Bool }
    var onImage: ((UIImage) -> Void)?
    private var waiting: Request?
    private var running = false

    func request(url: URL, grade: Grade, seed: Float, useDisk: Bool) {
        waiting = Request(url: url, grade: grade, seed: seed, useDisk: useDisk)
        guard !running else { return }
        running = true
        Task {
            while let r = waiting {
                waiting = nil
                if let cg = try? await RenderEngine.shared.preview(url: r.url, grade: r.grade, seed: r.seed, useDisk: r.useDisk) {
                    onImage?(UIImage(cgImage: cg))
                }
            }
            running = false
        }
    }
}

struct Adjustment: Identifiable {
    let title: String
    let symbol: String
    let value: Binding<Float>
    let range: ClosedRange<Float>
    let neutral: Float
    var enabled = true
    let text: (Float) -> String
    var id: String { title }

    var amount: Double {
        let v = value.wrappedValue
        if v >= neutral { return range.upperBound == neutral ? 0 : Double((v - neutral) / (range.upperBound - neutral)) }
        return range.lowerBound == neutral ? 0 : Double((v - neutral) / (neutral - range.lowerBound))
    }
}

private struct AdjustmentButton: View {
    let adjustment: Adjustment
    let selected: Bool
    let action: () -> Void
    var body: some View {
        let amount = adjustment.amount
        Button(action: action) {
            ZStack {
                Circle().stroke(selected ? Ink.paper.opacity(0.35) : Ink.line, lineWidth: 2)
                Circle()
                    .trim(from: 0, to: abs(amount))
                    .stroke(Ink.dusk, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .scaleEffect(x: amount < 0 ? -1 : 1)
                Image(systemName: adjustment.symbol)
                    .font(.system(size: 17))
                    .foregroundStyle(selected ? Ink.paper : Ink.stone)
            }
            .frame(width: 54, height: 54)
            .contentShape(Circle())
            .animation(Motion.snappy, value: amount)
            .animation(Motion.fade, value: adjustment.enabled)
        }
        .buttonStyle(.plain)
        .opacity(adjustment.enabled ? 1 : 0.35)
        .accessibilityLabel(adjustment.title)
        .accessibilityValue(adjustment.text(adjustment.value.wrappedValue))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct LookTile: View {
    let name: String
    let url: URL
    let grade: Grade
    let seed: Float
    let useDisk: Bool
    let selected: Bool
    let action: () -> Void
    @State private var image: UIImage?

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Ink.raised
                    if let image { Image(uiImage: image).resizable().scaledToFill().transition(.opacity) }
                }
                .frame(width: 84, height: 112)
                .clipShape(RoundedRectangle(cornerRadius: Radius.tile))
                .overlay { RoundedRectangle(cornerRadius: Radius.tile).stroke(selected ? Ink.paper : .clear, lineWidth: 2) }
                .scaleEffect(selected ? 1 : 0.96)
                Text(name).engraved(size: 9).lineLimit(1).minimumScaleFactor(0.8).frame(width: 84)
                    .foregroundStyle(selected ? Ink.paper : Ink.stone)
            }
            .animation(Motion.snappy, value: selected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .task(id: name) {
            guard let cg = try? await RenderEngine.shared.preview(url: url, grade: grade, seed: seed, longSide: 280, useDisk: useDisk) else { return }
            withAnimation(Motion.fade) { image = UIImage(cgImage: cg) }
        }
    }
}

private struct ActionCircle: View {
    let symbol: String
    let title: String
    let on: Bool
    let action: () -> Void
    var body: some View {
        Button { action(); Haptics.tick() } label: {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(on ? Color.black : Ink.stone)
                .frame(width: 54, height: 54)
                .background(on ? Color.white : .clear, in: Circle())
                .overlay(Circle().stroke(on ? .clear : Ink.line, lineWidth: 2))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

private struct CropFrame: View {
    var insets: CropInsets
    var body: some View {
        CropShape(insets: insets).fill(Color.black.opacity(0.62), style: FillStyle(eoFill: true))
            .overlay { CropShape(insets: insets, outlineOnly: true).stroke(Ink.paper.opacity(0.9), lineWidth: 1) }
    }
}

private struct CropShape: Shape {
    var insets: CropInsets
    var outlineOnly = false
    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<Double, Double>> {
        get { .init(.init(insets.left, insets.top), .init(insets.right, insets.bottom)) }
        set { insets = CropInsets(left: newValue.first.first, top: newValue.first.second, right: newValue.second.first, bottom: newValue.second.second) }
    }
    func path(in rect: CGRect) -> Path {
        let r = CGRect(x: rect.minX + rect.width * insets.left, y: rect.minY + rect.height * insets.top,
                       width: rect.width * (1 - insets.left - insets.right), height: rect.height * (1 - insets.top - insets.bottom))
        var p = Path()
        if outlineOnly {
            p.addRect(r)
            for i in 1...2 {
                let x = r.minX + r.width * CGFloat(i) / 3, y = r.minY + r.height * CGFloat(i) / 3
                p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
                p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y))
            }
        } else {
            p.addRect(rect)
            p.addRect(r)
        }
        return p
    }
}

private struct RulerScrubber: View {
    let adjustment: Adjustment
    @Binding var dragging: Bool

    @State private var active = false
    @State private var fine = false
    @State private var anchor: Float = 0
    @State private var startX: CGFloat = 0
    @State private var lastX: CGFloat = 0
    @State private var timer: Task<Void, Never>?
    @State private var lastMark: Int?

    private let length: CGFloat = 340
    // same ~11pt pitch as the camera dial in both modes, one detent per tick
    private var ticks: Int { fine ? 300 : 30 }

    var body: some View {
        let a = adjustment
        let span = a.range.upperBound - a.range.lowerBound
        let value = a.value.wrappedValue
        Canvas { ctx, size in
            let mid = size.width / 2
            let n = ticks
            for i in 0...n {
                let tick = a.range.lowerBound + span * Float(i) / Float(n)
                let x = mid + CGFloat((tick - value) / span) * length * (fine ? 10 : 1)
                guard x > -2, x < size.width + 2 else { continue }
                let major = i % 5 == 0
                let isNeutral = abs(tick - a.neutral) < span / Float(2 * n)
                let h: CGFloat = isNeutral ? 18 : major ? 12 : 7
                ctx.fill(Path(CGRect(x: x - 0.5, y: (size.height - h) / 2, width: 1, height: h)),
                         with: .color(.white.opacity(isNeutral ? 0.9 : major ? 0.5 : 0.25)))
            }
            ctx.fill(Path(roundedRect: CGRect(x: mid - 1, y: 4, width: 2, height: size.height - 8), cornerRadius: 1),
                     with: .color(fine ? Ink.ember : .white))
        }
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.2), .init(color: .black, location: 0.8), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing))
        .contentShape(Rectangle())
        .gesture(a.enabled ? drag : nil)
        .onTapGesture(count: 2) {
            guard a.enabled else { return }
            withAnimation(.snappy) { a.value.wrappedValue = a.neutral }
            Haptics.bump()
        }
        .opacity(a.enabled ? 1 : 0.35)
        .accessibilityElement()
        .accessibilityLabel(a.title)
        .accessibilityValue(a.text(value))
        .accessibilityAdjustableAction { d in
            guard a.enabled else { return }
            let step = span / 40
            a.value.wrappedValue = min(max(value + (d == .increment ? step : -step), a.range.lowerBound), a.range.upperBound)
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                let a = adjustment
                if !active {
                    active = true
                    dragging = true
                    anchor = a.value.wrappedValue
                    startX = v.location.x
                    lastX = v.location.x
                    arm()
                }
                if abs(v.location.x - lastX) > 2 {
                    lastX = v.location.x
                    if !fine { arm() }
                }
                let span = a.range.upperBound - a.range.lowerBound
                var next = anchor - Float((v.location.x - startX) / length) * span * (fine ? 0.1 : 1)
                next = min(max(next, a.range.lowerBound), a.range.upperBound)
                if !fine, abs(next - a.neutral) < span * 0.012 { next = a.neutral }
                if next == a.neutral, a.value.wrappedValue != a.neutral { Haptics.tick() }
                let mark = Int(((next - a.range.lowerBound) / span * Float(ticks)).rounded())
                if let lastMark, mark != lastMark, next != a.neutral { Haptics.detent() }
                lastMark = mark
                a.value.wrappedValue = next
            }
            .onEnded { _ in
                active = false
                lastMark = nil
                dragging = false
                fine = false
                timer?.cancel()
            }
    }

    private func arm() {
        timer?.cancel()
        timer = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled, active, !fine else { return }
            anchor = adjustment.value.wrappedValue
            startX = lastX
            fine = true
            lastMark = nil
            Haptics.bump()
        }
    }
}
