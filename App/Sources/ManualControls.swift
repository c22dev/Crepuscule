// Crepuscule - ManualControls.swift
// Constantin Clerc (c22dev) - 0.1
import Crepuscule
import SwiftUI

enum ManualDial: String, CaseIterable, Identifiable {
    case shutter, iso, aperture, focus
    var id: String { rawValue }
    var title: String {
        switch self {
        case .shutter: return "Shutter"
        case .iso: return "ISO"
        case .aperture: return "Aperture"
        case .focus: return "Focus"
        }
    }
}

struct ManualPanel: View {
    @Bindable var model: CameraModel
    static let height: CGFloat = 112

    private var dials: [ManualDial] {
        ManualDial.allCases.filter {
            switch $0 {
            case .aperture: return model.manualRange?.variableAperture == true
            case .focus: return model.manualRange?.manualFocus == true
            default: return true
            }
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                ForEach(dials) { chip($0) }
            }
            ruler
        }
        .padding(6)
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.thumb))
        .animation(Motion.snappy, value: model.manualDial)
    }

    private func chip(_ dial: ManualDial) -> some View {
        let on = model.manualDial == dial
        let manual = isManual(dial)
        return Button {
            model.manualDial = dial
            Haptics.tick()
        } label: {
            VStack(spacing: 1) {
                HStack(spacing: 3) {
                    Text(dial.title)
                    if !manual { Text("A").foregroundStyle(on ? Ink.paper : Ink.stone) }
                }
                .engraved(size: 7.5)
                .foregroundStyle(on ? Ink.paper : Ink.paper.opacity(0.7))
                Text(value(dial)).font(.instrument(13, weight: .semibold)).tracking(Tracking.tight)
                    .foregroundStyle(manual ? Ink.ember : Ink.paper)
                    .contentTransition(.numericText())
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .background {
                if on { RoundedRectangle(cornerRadius: Radius.chip - 4, style: .continuous).fill(Ink.dusk) }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(dial.title)
        .accessibilityValue(manual ? value(dial) : "Auto, \(value(dial))")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    @ViewBuilder private var ruler: some View {
        let dial = model.manualDial
        let manual = isManual(dial)
        HStack(spacing: 6) {
            Button {
                setAuto(dial)
                Haptics.bump()
            } label: {
                Text(dial == .focus ? "AF" : "Auto").engraved(size: 8.5)
                    .foregroundStyle(Ink.paper)
                    .frame(width: 52, height: 40)
                    .background(manual ? AnyShapeStyle(Ink.line) : AnyShapeStyle(Ink.dusk), in: .capsule)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(dial == .focus ? "Autofocus" : "Auto \(dial.title)")
            .accessibilityAddTraits(manual ? [] : .isSelected)
            StopRuler(count: count(dial), index: index(dial), active: manual, major: { major(dial, $0) },
                      label: dial == .focus ? ("camera.macro", "mountain.2") : nil) { set(dial, $0) }
                .id(dial)
                .accessibilityLabel(dial.title)
                .accessibilityValue(value(dial))
            if fullyManual {
                // in full manual the bias does nothing, the meter says how far off you are
                VStack(spacing: 0) {
                    Text("Meter").engraved(size: 7)
                    Text(ExposureText.ev(model.reading.meterOffset)).font(.instrument(11, weight: .semibold))
                        .foregroundStyle(abs(model.reading.meterOffset) > 1 ? Ink.ember : Ink.paper)
                        .contentTransition(.numericText())
                }
                .frame(width: 44)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(height: 40)
    }

    private var fullyManual: Bool {
        model.manual.iso != nil && model.manual.duration != nil
            && (model.manual.aperture != nil || model.manualRange?.variableAperture != true)
    }

    private func isManual(_ d: ManualDial) -> Bool {
        switch d {
        case .shutter: return model.manual.duration != nil
        case .iso: return model.manual.iso != nil
        case .aperture: return model.manual.aperture != nil
        case .focus: return model.manual.lensPosition != nil
        }
    }

    private func value(_ d: ManualDial) -> String {
        let r = model.reading
        switch d {
        case .shutter: return ExposureText.shutter(model.manual.duration ?? r.duration)
        case .iso: return "\(Int((model.manual.iso ?? r.iso).rounded()))"
        case .aperture: return ExposureText.aperture(model.manual.aperture ?? r.aperture)
        case .focus: return "\(Int(((model.manual.lensPosition ?? r.lensPosition) * 100).rounded()))"
        }
    }

    private func count(_ d: ManualDial) -> Int {
        switch d {
        case .shutter: return model.shutterStops.count
        case .iso: return model.isoStops.count
        case .aperture: return model.apertureStops.count
        case .focus: return 101
        }
    }

    // starts from what auto is doing so the first nudge is one stop away, not a jump
    private func index(_ d: ManualDial) -> Int {
        let r = model.reading
        switch d {
        case .shutter: return ManualStops.nearest(model.manual.duration ?? r.duration, in: model.shutterStops)
        case .iso: return ManualStops.nearest(model.manual.iso ?? r.iso, in: model.isoStops)
        case .aperture: return ManualStops.nearest(model.manual.aperture ?? r.aperture, in: model.apertureStops)
        case .focus: return Int(((model.manual.lensPosition ?? r.lensPosition) * 100).rounded())
        }
    }

    private func major(_ d: ManualDial, _ i: Int) -> Bool {
        func whole(_ v: Double) -> Bool { abs(v - v.rounded()) < 0.1 }
        switch d {
        case .shutter: return model.shutterStops.indices.contains(i) && whole(log2(model.shutterStops[i] * 1000))
        case .iso: return model.isoStops.indices.contains(i) && whole(log2(Double(model.isoStops[i]) / 100))
        case .aperture: return model.apertureStops.indices.contains(i) && whole(log2(Double(model.apertureStops[i] * model.apertureStops[i])))
        case .focus: return i % 10 == 0
        }
    }

    private func set(_ d: ManualDial, _ i: Int) {
        var m = model.manual
        switch d {
        case .shutter: guard model.shutterStops.indices.contains(i) else { return }; m.duration = model.shutterStops[i]
        case .iso: guard model.isoStops.indices.contains(i) else { return }; m.iso = model.isoStops[i]
        case .aperture: guard model.apertureStops.indices.contains(i) else { return }; m.aperture = model.apertureStops[i]
        case .focus: m.lensPosition = Float(min(max(i, 0), 100)) / 100
        }
        model.setManual(m)
    }

    private func setAuto(_ d: ManualDial) {
        var m = model.manual
        switch d {
        case .shutter: m.duration = nil
        case .iso: m.iso = nil
        case .aperture: m.aperture = nil
        case .focus: m.lensPosition = nil
        }
        model.setManual(m)
    }
}

// drag-to-scrub ruler, one tick per stop
private struct StopRuler: View {
    let count: Int
    let index: Int
    let active: Bool
    let major: (Int) -> Bool
    var label: (lead: String, trail: String)?
    let change: (Int) -> Void
    @State private var start: CGFloat?
    @State private var live: CGFloat?
    private let spacing: CGFloat = 11

    init(count: Int, index: Int, active: Bool, major: @escaping (Int) -> Bool, label: (String, String)? = nil, change: @escaping (Int) -> Void) {
        self.count = count; self.index = index; self.active = active; self.major = major
        self.label = label.map { (lead: $0.0, trail: $0.1) }; self.change = change
    }

    var body: some View {
        let position = live ?? CGFloat(index)
        Canvas { ctx, size in
            let mid = size.width / 2
            for i in 0..<count {
                let x = mid + (CGFloat(i) - position) * spacing
                guard x > -2, x < size.width + 2 else { continue }
                let big = major(i)
                let h: CGFloat = big ? 16 : 9
                let fade = 1 - min(abs(x - mid) / mid, 1) * 0.75
                ctx.fill(Path(CGRect(x: x - 0.5, y: (size.height - h) / 2, width: 1, height: h)),
                         with: .color(.white.opacity((big ? 0.85 : 0.45) * fade)))
            }
            ctx.fill(Path(roundedRect: CGRect(x: mid - 1, y: 4, width: 2, height: size.height - 8), cornerRadius: 1),
                     with: .color(active ? Ink.ember : Ink.paper))
        }
        .overlay {
            if let label {
                HStack {
                    Image(systemName: label.lead)
                    Spacer()
                    Image(systemName: label.trail)
                }
                .font(.system(size: 10, weight: .medium)).foregroundStyle(Ink.stone)
                .padding(.horizontal, 2)
                .allowsHitTesting(false)
            }
        }
        .contentShape(.rect)
        .highPriorityGesture(DragGesture(minimumDistance: 0).onChanged { v in
            let s = start ?? CGFloat(index)
            start = s
            let p = min(max(s - v.translation.width / spacing, 0), CGFloat(max(count - 1, 0)))
            live = p
            let i = Int(p.rounded())
            if i != index { Haptics.detent(); change(i) }
        }.onEnded { _ in
            withAnimation(Motion.snappy) { live = nil }
            start = nil
        })
        .accessibilityElement()
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: change(min(index + 1, count - 1))
            case .decrement: change(max(index - 1, 0))
            @unknown default: break
            }
        }
    }
}
