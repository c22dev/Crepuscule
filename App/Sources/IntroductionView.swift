// Crepuscule - IntroductionView.swift
// Constantin Clerc (c22dev) - 0.1
import SwiftUI

struct IntroductionView: View {
    static let shownKey = "introductionShown.v1"

    let onFinish: () -> Void
    @State private var page = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let count = 4
    private var last: Bool { page == count - 1 }

    var body: some View {
        TabView(selection: $page) {
            WelcomePage(active: page == 0).tag(0)
            IntroPage(number: 1, kicker: "Burst Merge", title: "Many frames, one RAW.",
                      message: "Every press takes a quick burst of RAW frames and merges them into one: less noise without smearing detail, and more highlight detail from the darker frames.",
                      note: ("moon.fill", "In low light, night bursts take up to 16 short frames. A moon shows by the exposure readout when they do."),
                      visualLabel: "A burst of noisy frames gathering into one clean RAW.") {
                BurstVisual(active: page == 1)
            }
            .tag(1)
            IntroPage(number: 2, kicker: "Looks", title: "Film, developed from RAW.",
                      message: "LogC, a print-film curve, halation and grain, applied to the RAW. The look button in the camera's top row picks the look for new photos and can preview it live.",
                      note: ("slider.horizontal.3", "Refine any photo with the editor's Looks tab and its Tone, Color and Texture tools. The RAW is always kept."),
                      visualLabel: "Geraniums in a Swiss village, split between the flat RAW and the film look, alternating between Factory and Mono.") {
                LooksVisual(active: page == 2)
            }
            .tag(2)
            IntroPage(number: 3, kicker: "Zoom", title: "14 to 270 mm.",
                      message: "Slide along the lens pill, or pinch. Past 2× (54 mm), shots are rebuilt with multi-frame super-resolution from the tiny movements of your hands in the burst: real extra detail, not just a crop.",
                      note: ("camera.shutter.button", "With Camera Control, light double-press and choose Zoom."),
                      visualLabel: "A lens scale gliding from 14 to 270 millimetres, with super-resolution past 54.") {
                ZoomVisual(active: page == 3)
            }
            .tag(3)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .safeAreaBar(edge: .top, spacing: 0) { topBar }
        .safeAreaBar(edge: .bottom, spacing: 0) { controls }
        .background { backdrop }
        .preferredColorScheme(.dark)
        .sensoryFeedback(.selection, trigger: page)
    }

    private var backdrop: some View {
        ZStack {
            Ink.ground
            RadialGradient(colors: [Ink.dusk.opacity(0.16), .clear], center: .top, startRadius: 0, endRadius: 460)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private var topBar: some View {
        HStack {
            Spacer()
            Button("Skip", action: finish)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Ink.paper)
                .padding(.horizontal, 16).frame(minHeight: 36)
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .accessibilityHint("Closes the introduction")
                .opacity(last ? 0 : 1)
                .disabled(last)
                .accessibilityHidden(last)
        }
        .padding(.horizontal, 20).padding(.top, Space.s)
        .frame(minHeight: 44)
        .animation(Motion.fade, value: last)
    }

    private var controls: some View {
        VStack(spacing: Space.xl) {
            PageDots(page: $page, count: count)
            Button(action: advance) {
                Text(last ? "Start Shooting" : "Continue")
                    .font(.headline)
                    .contentTransition(.opacity)
                    .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.glassProminent).tint(Ink.dusk).controlSize(.large)
            .frame(maxWidth: 440)
            .animation(Motion.fade, value: last)
        }
        .padding(.horizontal, 28).padding(.top, Space.l).padding(.bottom, Space.l)
    }

    private func advance() {
        guard !last else { return finish() }
        withAnimation(reduceMotion ? Motion.fade : Motion.smooth) { page += 1 }
    }

    private func finish() {
        Haptics.shutter()
        UserDefaults.standard.set(true, forKey: Self.shownKey)
        onFinish()
    }
}

private struct PageDots: View {
    @Binding var page: Int
    let count: Int
    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == page ? Ink.dusk : Ink.paper.opacity(0.28))
                    .frame(width: i == page ? 22 : 7, height: 7)
            }
        }
        .animation(Motion.snappy, value: page)
        .frame(minHeight: 16)
        .accessibilityElement()
        .accessibilityLabel("Page")
        .accessibilityValue("\(page + 1) of \(count)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if page < count - 1 { page += 1 }
            case .decrement: if page > 0 { page -= 1 }
            @unknown default: break
            }
        }
    }
}

private struct PageScroll<Content: View>: View {
    @ViewBuilder let content: (CGSize) -> Content
    var body: some View {
        GeometryReader { geo in
            ScrollView {
                content(geo.size)
                    .padding(.horizontal, 28)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
            .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        }
    }
}

private struct WelcomePage: View {
    let active: Bool
    @Environment(\.dynamicTypeSize) private var type

    var body: some View {
        PageScroll { size in
            VStack(spacing: 0) {
                Spacer(minLength: Space.xl)
                Color.clear
                    .frame(maxWidth: 420)
                    .frame(height: type.isAccessibilitySize ? 200 : min(380, size.height * 0.48))
                    .overlay { Image("intro_hero").resizable().scaledToFill() }
                    .clipShape(RoundedRectangle(cornerRadius: Radius.tile + 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.tile + 6, style: .continuous).strokeBorder(Ink.line, lineWidth: 1))
                    .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
                    .scaleEffect(active ? 1 : 0.97)
                    .animation(.easeOut(duration: 1.2), value: active)
                    .accessibilityElement()
                    .accessibilityLabel("Sunset over the Lavaux vineyards on Lake Geneva, in the Crepuscule look.")
                    .accessibilityAddTraits(.isImage)
                    .padding(.horizontal, Space.l)
                Spacer(minLength: Space.xl)
                VStack(spacing: Space.m) {
                    Text("Crepuscule")
                        .font(.display(.largeTitle, weight: .regular))
                        .foregroundStyle(Ink.paper)
                        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                        .accessibilityAddTraits(.isHeader)
                    Text("Film-look RAW camera").engraved(.caption2).foregroundStyle(Ink.stone)
                        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                    Text("Named for dusk, the hour after sunset. Here's what happens each time you press the shutter.")
                        .font(.body).foregroundStyle(Ink.paper.opacity(0.78))
                        .padding(.top, Space.s)
                    Text(IntroCredits.line)
                        .font(.caption2).foregroundStyle(Ink.stone)
                        .padding(.top, Space.xs)
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460)
                .accessibilitySortPriority(1)
                Spacer(minLength: Space.xl)
            }
            .accessibilityElement(children: .contain)
        }
    }
}

private struct IntroPage<Visual: View>: View {
    let number: Int
    let kicker: String
    let title: String
    let message: String
    let note: (symbol: String, text: String)
    let visualLabel: String
    @ViewBuilder let visual: Visual
    @Environment(\.dynamicTypeSize) private var type

    var body: some View {
        PageScroll { size in
            VStack(spacing: 0) {
                Spacer(minLength: Space.l)
                visual
                    .frame(height: type.isAccessibilitySize ? 220 : min(340, size.height * 0.5))
                    .frame(maxWidth: 460)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(visualLabel)
                    .accessibilityAddTraits(.isImage)
                Spacer(minLength: Space.xl)
                text
                    .frame(maxWidth: 460, alignment: .leading)
                    .accessibilitySortPriority(1)
                Spacer(minLength: Space.l)
            }
            .accessibilityElement(children: .contain)
        }
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.s) {
                Text(String(format: "%02d", number)).font(.instrument(.caption2, weight: .semibold)).foregroundStyle(Ink.paper)
                Rectangle().fill(Ink.line).frame(width: 18, height: 1)
                Text(kicker).engraved(.caption2).foregroundStyle(Ink.stone)
            }
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(number) of 3, \(kicker)")
            Text(title)
                .font(.display(.largeTitle, weight: .semibold))
                .foregroundStyle(Ink.paper)
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(.body).foregroundStyle(Ink.paper.opacity(0.8))
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Image(systemName: note.symbol).foregroundStyle(Ink.paper.opacity(0.85)).accessibilityHidden(true)
                Text(note.text).foregroundStyle(Ink.stone)
            }
            .font(.footnote)
            .padding(.horizontal, Space.m).padding(.vertical, Space.m - 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: Radius.chip))
            .accessibilityElement(children: .combine)
            .padding(.top, Space.xs)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private func hold(_ seconds: Double) async -> Bool {
    (try? await Task.sleep(for: .seconds(seconds))) != nil
}

private struct SceneLook: Equatable {
    var name: String

    static let factory = SceneLook(name: "Factory")
    static let mono = SceneLook(name: "Mono")
    static let all = [factory, mono]
    var asset: String {
        switch name {
        case "Mono": return "intro_look_mono"
        default: return "intro_look_factory"
        }
    }
}

// intro pics are cc by-sa 4.0 raws from pixls.us (lavaux by jonathan bieler, flowers/jungfrau by colin mckinney)
enum IntroCredits {
    static let line = "Photos: Jonathan Bieler, Colin Mckinney · CC BY-SA 4.0"
    static let settingsLine = "Introduction photos: Jonathan Bieler, Colin Mckinney · CC BY-SA 4.0"
}

private struct Grain: View {
    let amount: Double
    let seed: UInt64
    var body: some View {
        Canvas { ctx, size in
            var rng = SplitMix(state: seed &* 0x9E37_79B9_7F4A_7C15 &+ 1)
            var light = Path(), dark = Path()
            let n = Int(size.width * size.height / 14)
            for _ in 0..<n {
                let x = Double(rng.next() % 10_000) / 10_000 * size.width
                let y = Double(rng.next() % 10_000) / 10_000 * size.height
                let r = CGRect(x: x, y: y, width: 1, height: 1)
                if rng.next() & 1 == 0 { light.addRect(r) } else { dark.addRect(r) }
            }
            ctx.fill(light, with: .color(.white.opacity(min(1, amount * 0.7))))
            ctx.fill(dark, with: .color(.black.opacity(min(1, amount * 0.8))))
        }
        .allowsHitTesting(false)
    }
}

private struct SplitMix {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private struct ReadoutChip: View {
    let label: String
    let value: String
    var tint: Color = Ink.paper
    var body: some View {
        VStack(spacing: 1) {
            Text(label).engraved(size: 8.5).foregroundStyle(tint == Ink.paper ? .white.opacity(0.7) : tint)
                .contentTransition(.interpolate)
            Text(value).font(.instrument(14, weight: .semibold)).tracking(Tracking.tight).foregroundStyle(tint)
                .contentTransition(.numericText())
        }
        .frame(minWidth: 64, minHeight: 44).padding(.horizontal, Space.s + 2)
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.chip))
    }
}

private struct BurstVisual: View {
    let active: Bool
    @State private var merged = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let count = 5

    var body: some View {
        GeometryReader { geo in
            let w = min(geo.size.width * 0.74, (geo.size.height - 60) * 4 / 3)
            let h = w * 3 / 4
            let shape = RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
            let spread: CGFloat = reduceMotion || !merged ? 1 : 0
            ZStack {
                ForEach(0..<count, id: \.self) { i in
                    let k = CGFloat(i) - CGFloat(count - 1) / 2
                    Image("intro_burst_\(i)").resizable().scaledToFill()
                        .frame(width: w, height: h)
                        .clipShape(shape)
                        .overlay(shape.strokeBorder(Ink.line, lineWidth: 1))
                        .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
                        .rotationEffect(.degrees(Double(k) * 2.4 * spread))
                        .offset(x: k * w * 0.06 * spread, y: -k * w * 0.05 * spread)
                        .opacity(merged && !reduceMotion ? 0.0 : 1 - Double(count - 1 - i) * 0.1)
                }
                Image("intro_burst_merged").resizable().scaledToFill()
                    .frame(width: w, height: h)
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(Ink.paper.opacity(0.25), lineWidth: 1))
                    .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
                    .opacity(merged ? 1 : 0)
                    .scaleEffect(merged || reduceMotion ? 1 : 0.96)
            }
            .overlay(alignment: .topTrailing) {
                ReadoutChip(label: merged ? "Merged" : "Burst", value: merged ? "1 RAW" : "\(count) frames")
                    .padding(Space.s)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .task(id: active) {
            merged = false
            guard active else { return }
            while true {
                guard await hold(1.6) else { return }
                withAnimation(reduceMotion ? Motion.fade : .spring(response: 0.7, dampingFraction: 0.86)) { merged = true }
                guard await hold(2.6) else { return }
                withAnimation(reduceMotion ? Motion.fade : .spring(response: 0.6, dampingFraction: 0.9)) { merged = false }
            }
        }
    }
}

private struct LooksVisual: View {
    let active: Bool
    @State private var index = 0
    @State private var split: CGFloat = 0.5
    @State private var held = false
    @State private var touches = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let looks = SceneLook.all

    var body: some View {
        GeometryReader { geo in
            let tileH: CGFloat = 62
            let h = min(geo.size.height - tileH - Space.l, geo.size.width * 3 / 4)
            let w = h * 4 / 3
            let shape = RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
            VStack(spacing: Space.l) {
                ZStack(alignment: .leading) {
                    Image("intro_look_raw").resizable().scaledToFill().frame(width: w, height: h)
                    ZStack {
                        Image(looks[index].asset).resizable().scaledToFill().frame(width: w, height: h)
                            .id(index)
                            .transition(.opacity)
                    }
                    .mask(alignment: .trailing) { Rectangle().frame(width: w * (1 - split)) }
                    Rectangle().fill(Ink.paper).frame(width: 1.5)
                        .overlay {
                            Circle().fill(Ink.paper).frame(width: held ? 26 : 20, height: held ? 26 : 20)
                                .overlay {
                                    Image(systemName: "arrow.left.and.right")
                                        .font(.system(size: 9, weight: .bold)).foregroundStyle(Ink.ground)
                                }
                                .animation(Motion.snappy, value: held)
                        }
                        .offset(x: w * split - 0.75)
                        .shadow(color: .black.opacity(0.4), radius: 4)
                    Color.clear.frame(width: 64, height: h).contentShape(.rect)
                        .offset(x: w * split - 32)
                        .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("looksSplit"))
                            .onChanged { v in
                                held = true
                                withTransaction(Transaction(animation: nil)) { split = min(max(v.location.x / w, 0.04), 0.96) }
                            }
                            .onEnded { _ in held = false; touches += 1 })
                }
                .coordinateSpace(.named("looksSplit"))
                .frame(width: w, height: h)
                .clipShape(shape)
                .overlay(shape.strokeBorder(Ink.line, lineWidth: 1))
                .overlay(alignment: .topLeading) { tag("RAW").padding(Space.s) }
                .overlay(alignment: .topTrailing) { tag(looks[index].name).padding(Space.s) }
                .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
                HStack(spacing: Space.m) {
                    ForEach(looks.indices, id: \.self) { i in
                        let on = i == index
                        Button {
                            withAnimation(Motion.fade) { index = i }
                            touches += 1
                        } label: {
                            VStack(spacing: 5) {
                                Image(looks[i].asset).resizable().scaledToFill()
                                    .frame(width: 48, height: 36)
                                    .clipShape(RoundedRectangle(cornerRadius: Radius.tile - 4, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: Radius.tile - 4, style: .continuous)
                                        .strokeBorder(on ? Ink.dusk : Ink.line, lineWidth: on ? 2 : 1))
                                Text(looks[i].name).engraved(size: 7.5).lineLimit(1).minimumScaleFactor(0.7)
                                    .foregroundStyle(on ? Ink.dusk : Ink.paper.opacity(0.75))
                            }
                            .frame(width: 62)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(height: tileH)
                .animation(Motion.snappy, value: index)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .task(id: [active ? 1 : 0, held ? 1 : 0, touches]) {
            guard active, !held else { return }
            if touches == 0 { split = 0.5 } else { guard await hold(3) else { return } }
            while true {
                guard await hold(2.4) else { return }
                withAnimation(reduceMotion ? Motion.fade : .easeInOut(duration: 0.6)) { index = (index + 1) % looks.count }
                if !reduceMotion {
                    withAnimation(.easeInOut(duration: 2.2)) { split = split < 0.5 ? 0.62 : 0.38 }
                }
            }
        }
        .onChange(of: active) { _, on in if !on { touches = 0 } }
    }

    private func tag(_ text: String) -> some View {
        Text(text).engraved(size: 8.5).foregroundStyle(Ink.paper)
            .contentTransition(.opacity)
            .padding(.horizontal, Space.s).frame(minHeight: 22)
            .glassEffect(.regular, in: .capsule)
    }
}

private struct ZoomVisual: View {
    let active: Bool
    @State private var mm: Double = 14
    @State private var held = false
    @State private var touches = 0
    @State private var grab: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let route: [Double] = [26, 54, 120, 270, 54, 14]
    private var superRes: Bool { mm > 54 }

    private func set(_ f: Double) {
        let new = min(max(f, 14), 270)
        let lo = min(mm, new), hi = max(mm, new)
        if new != mm {
            if new == 14 || new == 270 { Haptics.bump() }
            else if [26.0, 54].contains(where: { lo < $0 && $0 <= hi }) { Haptics.tick() }
            else if Int(log2(new / 14) * 4) != Int(log2(mm / 14) * 4) { Haptics.detent() }
        }
        withTransaction(Transaction(animation: nil)) { mm = new }
    }

    private func release() { grab = nil; held = false; touches += 1 }

    private var rulerDrag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                let start = grab ?? log2(mm / 14)
                grab = start
                held = true
                set(14 * pow(2, start - Double(v.translation.width / FocalRuler.perStop)))
            }
            .onEnded { _ in release() }
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { v in
                let start = grab ?? mm
                grab = start
                held = true
                // photo scales by (mm/14)^0.65, invert it to stay under the finger
                set(start * pow(Double(v.magnification), 1 / 0.65))
            }
            .onEnded { _ in release() }
    }

    var body: some View {
        GeometryReader { geo in
            let rulerH: CGFloat = 58
            let h = min(geo.size.height - rulerH - Space.l, geo.size.width * 3 / 4)
            let w = h * 4 / 3
            let shape = RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
            VStack(spacing: Space.l) {
                Image("intro_zoom").resizable().scaledToFill()
                    .frame(width: w, height: h)
                    .scaleEffect(pow(mm / 14, 0.65), anchor: UnitPoint(x: 0.42, y: 0.5))
                    .frame(width: w, height: h)
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(Ink.line, lineWidth: 1))
                    .overlay(alignment: .topTrailing) {
                        ReadoutChip(label: "mm", value: "\(Int(mm))").padding(Space.s)
                    }
                    .overlay(alignment: .bottomLeading) {
                        if superRes {
                            Label("Super-Resolution", systemImage: "sparkles")
                                .engraved(size: 8.5).foregroundStyle(Ink.ember)
                                .padding(.horizontal, 10).frame(minHeight: 26)
                                .glassEffect(.regular, in: .capsule)
                                .padding(Space.s)
                                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottomLeading)))
                        }
                    }
                    .animation(Motion.fade, value: superRes)
                    .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
                    .contentShape(shape)
                    .gesture(pinch)
                FocalRuler(mm: mm)
                    .frame(width: min(w, geo.size.width), height: rulerH)
                    .contentShape(.capsule)
                    .highPriorityGesture(rulerDrag)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .task(id: [active ? 1 : 0, held ? 1 : 0, touches]) {
            guard active, !held else { return }
            if touches > 0 {
                guard !reduceMotion, await hold(3) else { return }
            } else {
                if reduceMotion { mm = 120; return }
                mm = 14
            }
            while true {
                for stop in route {
                    guard await hold(stop == 270 ? 2.2 : 1.5) else { return }
                    withAnimation(.spring(response: stop == 14 ? 1.1 : 0.8, dampingFraction: 0.9)) { mm = stop }
                }
            }
        }
        .onChange(of: active) { _, on in if !on { touches = 0 } }
    }
}

private struct FocalRuler: View {
    let mm: Double
    static let perStop: CGFloat = 70
    private let majors: [(mm: Double, mark: String?)] = [(14, nil), (26, nil), (54, "2×"), (270, nil)]

    private func x(_ f: Double) -> CGFloat { CGFloat(log2(f / 14)) * Self.perStop }

    var body: some View {
        GeometryReader { geo in
            let mid = geo.size.width / 2
            ZStack(alignment: .topLeading) {
                Capsule().fill(Ink.ember.opacity(0.55))
                    .frame(width: x(270) - x(54), height: 2)
                    .offset(x: x(54), y: 29)
                ForEach(0...17, id: \.self) { i in
                    let f = 14 * pow(2, Double(i) / 4)
                    Rectangle().fill(Ink.paper.opacity(0.35)).frame(width: 1, height: 6)
                        .offset(x: x(f), y: 10)
                }
                ForEach(majors, id: \.mm) { major in
                    Rectangle().fill(Ink.paper.opacity(0.8)).frame(width: 1.5, height: 12)
                        .offset(x: x(major.mm) - 0.25, y: 7)
                    Text("\(Int(major.mm))").font(.instrument(11, weight: .medium)).foregroundStyle(Ink.paper.opacity(0.85))
                        .fixedSize()
                        .frame(width: 40).offset(x: x(major.mm) - 20, y: 34)
                    if let mark = major.mark {
                        Text(mark).engraved(size: 7.5).foregroundStyle(Ink.ember)
                            .fixedSize().frame(width: 30).offset(x: x(major.mm) - 15, y: -4)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .offset(x: mid - x(mm))
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18),
                                         .init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                                 startPoint: .leading, endPoint: .trailing))
            .overlay {
                Capsule().fill(Ink.dusk).frame(width: 3, height: 26).position(x: mid, y: 16)
            }
        }
        .padding(.vertical, 2)
        .glassEffect(.regular, in: .capsule)
        .accessibilityHidden(true)
    }
}
