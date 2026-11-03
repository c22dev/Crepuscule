// Crepuscule - NewestPhotoButton.swift
// Constantin Clerc (c22dev) - 0.1
import Crepuscule
import SwiftUI

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

    private var mergeProgress: Double { mergingID.flatMap { library.mergeProgress[$0] } ?? 0 }

    var body: some View {
        let still = reduceMotion
        let shape = ConcentricRectangle(uniformTopCorners: .fixed(Radius.thumb), bottomLeadingCorner: .concentric(minimum: .fixed(Radius.thumb)), bottomTrailingCorner: .fixed(Radius.thumb))
        Button(action: action) {
            ZStack {
                Ink.raised
                if let id = library.newest?.id, let image = library.thumbnail(id) {
                    Image(uiImage: image).resizable().scaledToFill().upright().id(id)
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
                content.scaleEffect(still ? 1 : scale)
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
        .onChange(of: mergeProgress) { _, p in
            guard mergingID != nil, ringOpacity > 0 else { return }
            // stays a hair short of full so finishRing has a last step
            let target = CGFloat(min(p, 1)) * 0.95
            guard target > ringFraction else { return }
            if reduceMotion { ringFraction = target } else { withAnimation(.easeOut(duration: 0.35)) { ringFraction = target } }
        }
    }

    private func startRing(_ id: UUID) {
        ringRun += 1
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { ringFraction = 0 }
        let run = ringRun
        Task { @MainActor in
            guard run == ringRun else { return }
            withAnimation(Motion.fade) { ringOpacity = reduceMotion ? 0.7 : 1 }
            let target = CGFloat(min(library.mergeProgress[id] ?? 0, 1)) * 0.95
            if reduceMotion { ringFraction = target } else { withAnimation(.easeOut(duration: 0.35)) { ringFraction = target } }
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
