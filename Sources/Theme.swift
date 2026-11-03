// Crepuscule - Theme.swift
// Constantin Clerc (c22dev) - 0.1
import SwiftUI

enum Ink {
    static let dusk = Color(red: 0x8B / 255, green: 0x3D / 255, blue: 1)
    static let ember = Color(red: 1, green: 0x7A / 255, blue: 0x2F / 255)
    static let ground = Color.black
    static let editor = Color(red: 0.07, green: 0.07, blue: 0.07)
    static let raised = Color(red: 0.11, green: 0.11, blue: 0.118)
    static let paper = Color.white
    static let stone = Color(white: 0.6)
    static let line = Color.white.opacity(0.14)

    static let duskRing = AngularGradient(gradient: Gradient(colors: [dusk, Color(red: 0xD9 / 255, green: 0x4E / 255, blue: 0x8F / 255), ember, ember]),
                                          center: .center, startAngle: .degrees(-90), endAngle: .degrees(270))
}

extension Font {
    static func instrument(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight).width(.expanded).monospacedDigit()
    }
    static func instrument(_ style: Font.TextStyle, weight: Font.Weight = .medium) -> Font {
        .system(style, weight: weight).width(.expanded).monospacedDigit()
    }
    static func engraving(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold).width(.expanded)
    }
    static func engraving(_ style: Font.TextStyle) -> Font {
        .system(style, weight: .semibold).width(.expanded)
    }
    static func display(_ style: Font.TextStyle = .title3, weight: Font.Weight = .semibold) -> Font {
        .system(style, design: .default, weight: weight)
    }
}

enum Tracking {
    static let engraved: CGFloat = 1.1
    static let tight: CGFloat = -0.5
}

extension View {
    func engraved(size: CGFloat = 9) -> some View {
        font(.engraving(size)).tracking(Tracking.engraved).textCase(.uppercase)
    }
    func engraved(_ style: Font.TextStyle) -> some View {
        font(.engraving(style)).tracking(Tracking.engraved).textCase(.uppercase)
    }
}

enum Space {
    static let hair: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 22
}

enum Radius {
    static let glyph: CGFloat = 3
    static let plate: CGFloat = 10
    static let tile: CGFloat = 12
    static let chip: CGFloat = 16
    static let thumb: CGFloat = 18
}

enum Motion {
    static let snappy = Animation.spring(response: 0.3, dampingFraction: 0.82)
    static let smooth = Animation.spring(response: 0.42, dampingFraction: 0.88)
    static let pop = Animation.spring(response: 0.34, dampingFraction: 0.58)
    static let fade = Animation.easeInOut(duration: 0.22)
}

extension AnyTransition {
    static var rise: AnyTransition {
        .asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.9)),
                    removal: .opacity.combined(with: .scale(scale: 0.95)))
    }
}

enum Haptics {
    static func tick() { UISelectionFeedbackGenerator().selectionChanged() }
    static func detent() { detentGenerator.impactOccurred(intensity: 0.22) }
    private static let detentGenerator = UIImpactFeedbackGenerator(style: .soft)
    static func bump() { UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.8) }
    static func shutter() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func warn() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}

enum LensReadout: String, CaseIterable, Identifiable {
    case focal = "Focal Length", zoom = "Zoom Factor", degrees = "Degrees"
    var id: String { rawValue }
    func parts(_ mm: Int) -> (value: String, unit: String) {
        switch self {
        case .focal: return ("\(mm)", "mm")
        case .zoom:
            let z = Double(mm) / 26
            return (z < 10 && abs(z - z.rounded()) > 0.05 ? String(format: "%.1f", z) : "\(Int(z.rounded()))", "×")
        case .degrees: return ("\(Int((2 * atan(18 / Double(max(mm, 1))) * 180 / .pi).rounded()))", "°")
        }
    }
}

extension AspectRatioPreset {
    var label: String {
        switch self {
        case .native: return "Native"
        case .portrait: return "4:5"
        case .square: return "1:1"
        case .academy: return "Academy"
        case .stills35: return "3:2"
        case .hd: return "16:9"
        case .flat: return "Flat"
        case .scope: return "Scope"
        case .custom: return "Custom"
        }
    }
    var figure: String {
        switch self {
        case .native: return "4:3"
        case .portrait: return "4:5"
        case .square: return "1:1"
        case .academy: return "1.37"
        case .stills35: return "3:2"
        case .hd: return "16:9"
        case .flat: return "1.85"
        case .scope: return "2.39"
        case .custom: return "—"
        }
    }
    static var pickable: [AspectRatioPreset] { [.native, .portrait, .square, .academy, .stills35, .hd, .flat, .scope] }

    func screenRatio(landscapeHold: Bool) -> CGFloat {
        guard let r = ratio() else { return 3.0 / 4 }
        if self == .portrait { return landscapeHold ? CGFloat(1 / r) : CGFloat(r) }
        return CGFloat(1 / max(r, 1 / r))
    }
}

extension DriveMode {
    var title: String {
        switch self {
        case .single: return "Single"
        case .burst3: return "Burst 3"
        case .burst5: return "Burst 5"
        case .bracket3: return "Bracket ±1"
        case .bracket5: return "Bracket ±2"
        }
    }
    var symbol: String {
        switch self {
        case .single: return "square"
        case .burst3, .burst5: return "square.stack.3d.down.right"
        case .bracket3, .bracket5: return "plusminus"
        }
    }
}

struct AspectTile: View {
    let aspect: AspectRatioPreset
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                let r = aspect.ratio() ?? 4.0 / 3
                RoundedRectangle(cornerRadius: Radius.glyph)
                    .stroke(selected ? Ink.dusk : Ink.paper, lineWidth: 1.5)
                    .frame(width: r >= 1 ? 30 : 30 * r, height: r >= 1 ? 30 / r : 30)
                    .frame(height: 30)
                Text(aspect.label).font(.engraving(9.5)).tracking(0.4).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(selected ? Ink.dusk : Ink.paper)
            .frame(width: 62, height: 62)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(aspect.label), \(aspect.figure)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct AmbientBackdrop: View {
    let display: ViewfinderDisplay
    var body: some View {
        ZStack {
            Color.black
            Color.clear.overlay {
                ViewfinderSurface(display: display)
                    .aspectRatio(3.0 / 4, contentMode: .fill)
            }
            Color.black.opacity(0.42)
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
