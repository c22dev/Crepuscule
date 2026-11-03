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
        VStack(spacing: 0) {
            topBar
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
            controls
        }
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

private struct DuskMark: View {
    let active: Bool
    @State private var settled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let sun = side * 0.56
            let horizon = side * 0.6
            let rise = settled ? sun * 0.08 : sun * 0.3
            let width = min(geo.size.width, side * 1.35)
            ZStack(alignment: .top) {
                Circle().fill(Ink.dusk.opacity(0.22)).frame(width: sun * 1.5, height: sun * 1.5)
                    .blur(radius: sun * 0.3)
                    .offset(y: horizon - sun * 0.75 - rise)
                VStack(spacing: 0) {
                    Color.clear.frame(width: width, height: horizon).overlay(alignment: .top) {
                        Circle().fill(LinearGradient(gradient: Ink.duskStops, startPoint: .top, endPoint: .bottom))
                            .frame(width: sun, height: sun)
                            .offset(y: horizon - sun / 2 - rise)
                    }
                    .clipped()
                    Color.clear.frame(width: width, height: side - horizon).overlay(alignment: .top) {
                        Circle().fill(LinearGradient(gradient: Ink.duskStops, startPoint: .bottom, endPoint: .top))
                            .frame(width: sun, height: sun)
                            .offset(y: rise - sun / 2)
                    }
                    .clipped()
                    .mask {
                        VStack(spacing: side * 0.028) {
                            ForEach(0..<6, id: \.self) { i in
                                Capsule().frame(width: sun * (1 - CGFloat(i) * 0.13), height: max(1.5, side * 0.018 - CGFloat(i) * 1.2))
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.top, side * 0.03)
                    }
                    .opacity(0.4)
                }
                Rectangle().fill(Ink.paper.opacity(0.55)).frame(width: width, height: 1).offset(y: horizon)
                    .mask(LinearGradient(colors: [.clear, .black, .black, .clear], startPoint: .leading, endPoint: .trailing))
            }
            .frame(width: geo.size.width, height: side)
            .frame(maxHeight: .infinity)
        }
        .task(id: active) {
            guard active else { return }
            if reduceMotion { settled = true; return }
            settled = false
            guard await hold(0.25) else { return }
            withAnimation(.easeOut(duration: 3.2)) { settled = true }
        }
    }
}

private struct SceneLook: Equatable {
    var name: String
    var saturation: Double
    var contrast: Double
    var brightness: Double
    var halation: Double
    var grain: Double
    var warmth: Double

    static let raw = SceneLook(name: "RAW", saturation: 0.42, contrast: 0.6, brightness: 0.07, halation: 0, grain: 0, warmth: 0)
    static let factory = SceneLook(name: "Factory", saturation: 1, contrast: 1.12, brightness: 0, halation: 0.4, grain: 0.22, warmth: 0.12)
    static let optical = SceneLook(name: "Optical", saturation: 1.06, contrast: 1.05, brightness: 0.02, halation: 0.85, grain: 0.26, warmth: 0.18)
    static let noHalation = SceneLook(name: "No Halation", saturation: 1, contrast: 1.16, brightness: 0, halation: 0, grain: 0.22, warmth: 0.08)
    static let mono = SceneLook(name: "Mono", saturation: 0, contrast: 1.28, brightness: 0, halation: 0.3, grain: 0.36, warmth: 0)
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

private struct Ridge: Shape {
    let points: [CGPoint]
    func path(in r: CGRect) -> Path {
        var p = Path()
        let pts = points.map { CGPoint(x: r.minX + $0.x * r.width, y: r.minY + $0.y * r.height) }
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: pts[0])
        for i in 1..<pts.count {
            let mid = CGPoint(x: (pts[i - 1].x + pts[i].x) / 2, y: (pts[i - 1].y + pts[i].y) / 2)
            p.addQuadCurve(to: mid, control: pts[i - 1])
        }
        p.addLine(to: pts[pts.count - 1])
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

private struct DuskScene: View {
    var look: SceneLook = .raw
    var noise: Double = 0
    var seed: UInt64 = 1
    static let sunCenter = UnitPoint(x: 0.6, y: 0.55)

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let sun = w * 0.17
            ZStack {
                LinearGradient(stops: [
                    .init(color: Color(red: 0.09, green: 0.09, blue: 0.2), location: 0),
                    .init(color: Color(red: 0.3, green: 0.22, blue: 0.4), location: 0.38),
                    .init(color: Color(red: 0.86, green: 0.52, blue: 0.4), location: 0.58),
                    .init(color: Color(red: 0.95, green: 0.72, blue: 0.5), location: 0.66),
                ], startPoint: .top, endPoint: .bottom)
                Ellipse().fill(Color(red: 1, green: 0.78, blue: 0.55).opacity(0.5))
                    .frame(width: w * 0.9, height: h * 0.22).blur(radius: w * 0.07)
                    .position(x: w * 0.6, y: h * 0.56)
                Circle().fill(Color(red: 1, green: 0.93, blue: 0.8))
                    .frame(width: sun, height: sun)
                    .position(x: w * Self.sunCenter.x, y: h * Self.sunCenter.y)
                Ridge(points: [.init(x: 0, y: 0.6), .init(x: 0.12, y: 0.55), .init(x: 0.26, y: 0.59), .init(x: 0.4, y: 0.51),
                               .init(x: 0.5, y: 0.58), .init(x: 0.68, y: 0.6), .init(x: 0.84, y: 0.55), .init(x: 1, y: 0.6)])
                    .fill(Color(red: 0.26, green: 0.18, blue: 0.3))
                Ridge(points: [.init(x: 0, y: 0.78), .init(x: 0.18, y: 0.69), .init(x: 0.36, y: 0.76), .init(x: 0.56, y: 0.71),
                               .init(x: 0.76, y: 0.8), .init(x: 1, y: 0.73)])
                    .fill(Color(red: 0.08, green: 0.07, blue: 0.11))
                Circle().fill(Color(red: 1, green: 0.3, blue: 0.16))
                    .frame(width: sun * 2.2, height: sun * 2.2).blur(radius: w * 0.05)
                    .position(x: w * Self.sunCenter.x, y: h * Self.sunCenter.y)
                    .blendMode(.screen)
                    .opacity(look.halation * 0.75)
                Color(red: 1, green: 0.55, blue: 0.2).opacity(look.warmth).blendMode(.softLight)
            }
            .saturation(look.saturation)
            .contrast(look.contrast)
            .brightness(look.brightness)
            .overlay {
                if look.grain + noise > 0 { Grain(amount: look.grain + noise, seed: seed) }
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }
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
                        .overlay { Circle().fill(Ink.paper).frame(width: 9, height: 9) }
                        .offset(x: w * split - 0.75)
                        .shadow(color: .black.opacity(0.4), radius: 4)
                }
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
        .task(id: active) {
            guard active else { return }
            split = 0.5
            while true {
                guard await hold(2.4) else { return }
                withAnimation(reduceMotion ? Motion.fade : .easeInOut(duration: 0.6)) { index = (index + 1) % looks.count }
                if !reduceMotion {
                    withAnimation(.easeInOut(duration: 2.2)) { split = split < 0.5 ? 0.62 : 0.38 }
                }
            }
        }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let route: [Double] = [26, 54, 120, 270, 54, 14]
    private var superRes: Bool { mm > 54 }

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
                    .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
                FocalRuler(mm: mm)
                    .frame(width: min(w, geo.size.width), height: rulerH)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .task(id: active) {
            guard active else { return }
            if reduceMotion { mm = 120; return }
            mm = 14
            while true {
                for stop in route {
                    guard await hold(stop == 270 ? 2.2 : 1.5) else { return }
                    withAnimation(.spring(response: stop == 14 ? 1.1 : 0.8, dampingFraction: 0.9)) { mm = stop }
                }
            }
        }
    }
}

private struct FocalRuler: View {
    let mm: Double
    private let perStop: CGFloat = 70
    private let majors: [(mm: Double, mark: String?)] = [(14, nil), (26, nil), (54, "2×"), (270, nil)]

    private func x(_ f: Double) -> CGFloat { CGFloat(log2(f / 14)) * perStop }

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
