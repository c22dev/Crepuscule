// Crepuscule - PhotoPager.swift
// Constantin Clerc (c22dev) - 0.1
import AVFoundation
import SwiftUI

struct PhotoPager: View {
    let library: Library
    let close: () -> Void
    @State private var selection: UUID
    @State private var editing: UUID?
    @State private var saving = false
    @State private var saved: Set<UUID> = []
    @State private var note: String?
    @State private var preparingShare = false
    @State private var infoFor: UUID?
    @State private var sharing: ShareFile?
    @State private var chromeHidden = false
    @Environment(\.dismiss) private var dismiss

    init(library: Library, start: UUID, close: @escaping () -> Void) {
        self.library = library
        self.close = close
        _selection = State(initialValue: start)
    }

    private var current: PhotoItem? { library.item(selection) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $selection) {
                ForEach(library.items.reversed()) { item in
                    PhotoPage(library: library, item: item, isCurrent: item.id == selection, prefetches: editing == nil) { withAnimation(Motion.fade) { chromeHidden.toggle() } }
                        .tag(item.id).ignoresSafeArea()
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            .onChange(of: selection) {
                let keep = library.item(selection).map(library.rawURL)
                Task { if let keep { await DetailEngine.shared.release(keeping: keep) } else { await DetailEngine.shared.release() } }
            }
            .onDisappear { Task { await DetailEngine.shared.release() } }
            VStack(spacing: 0) {
                topBar
                    .offset(y: chromeHidden ? -24 : 0)
                    .opacity(chromeHidden ? 0 : 1)
                Spacer()
                if let note {
                    Text(note).font(.system(size: 13, weight: .medium)).foregroundStyle(Ink.paper)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .glassEffect()
                        .padding(.bottom, 10)
                        .transition(.rise)
                }
                bottomBar
                    .offset(y: chromeHidden ? 24 : 0)
                    .opacity(chromeHidden ? 0 : 1)
            }
            .allowsHitTesting(!chromeHidden)
        }
        .statusBarHidden(chromeHidden)
        .toolbar(.hidden, for: .navigationBar)
        .fullScreenCover(item: Binding(get: { editing.map(EditTarget.init) }, set: { editing = $0?.id })) { t in
            if let item = library.item(t.id) { EditScreen(library: library, item: item) }
        }
        .sheet(item: Binding(get: { infoFor.map(EditTarget.init) }, set: { infoFor = $0?.id })) { t in
            if let item = library.item(t.id) { InfoPanel(library: library, item: item).presentationDetents([.medium]) }
        }
        .sheet(item: $sharing) { ShareSheet(url: $0.url) }
        .task {
            #if targetEnvironment(simulator)
            if DemoFlags.openEditor { editing = selection }
            if ProcessInfo.processInfo.arguments.contains("-demoSave"), let item = current { save(item) }
            #endif
        }
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").font(.system(size: 17, weight: .medium)).frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("Library")
            Spacer()
            if let item = current {
                VStack(spacing: 1) {
                    Text(item.created.formatted(.dateTime.month(.wide).day())).font(.display(.headline))
                    Text(item.created.formatted(date: .omitted, time: .shortened)).font(.instrument(.caption2)).foregroundStyle(Ink.stone)
                        .contentTransition(.numericText())
                }
                .animation(Motion.snappy, value: selection)
                Spacer()
                Button(action: { save(item) }) {
                    Group {
                        if saving { ProgressView().controlSize(.small).transition(.scale(scale: 0.5).combined(with: .opacity)) }
                        else if saved.contains(item.id) {
                            Image(systemName: "checkmark").font(.system(size: 14, weight: .bold))
                                .transition(.scale(scale: 0.3).combined(with: .opacity))
                        }
                        else { Text("Save").font(.system(size: 15, weight: .semibold)).transition(.opacity) }
                    }
                    .animation(Motion.pop, value: saving)
                    .animation(Motion.pop, value: saved.contains(item.id))
                    .foregroundStyle(.white)
                    .frame(minWidth: 62, minHeight: 44)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive())
                .disabled(saving)
                .accessibilityLabel(saved.contains(item.id) ? "Saved to Photos" : "Save to Photos")
            }
        }
        .foregroundStyle(Ink.paper)
        .padding(.horizontal, 12)
    }

    private var bottomBar: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button(action: shareCurrent) {
                        Group {
                            if preparingShare { ProgressView() } else { Image(systemName: "square.and.arrow.up") }
                        }.frame(width: 48, height: 48)
                    }
                        .buttonStyle(.plain).glassEffect(.regular.interactive(), in: .circle)
                        .accessibilityLabel("Share")
                    Button { infoFor = selection } label: { Image(systemName: "info.circle").frame(width: 48, height: 48) }
                        .buttonStyle(.plain).glassEffect(.regular.interactive(), in: .circle)
                        .accessibilityLabel("Details")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button { editing = selection } label: {
                    Label("Edit", systemImage: "slider.horizontal.3")
                        .font(.body.weight(.semibold)).frame(height: 48).padding(.horizontal, 20)
                }
                .buttonStyle(.plain).glassEffect(.regular.tint(Ink.dusk.opacity(0.85)).interactive())
                Menu {
                    Button("Delete Photo and RAW", systemImage: "trash", role: .destructive, action: deleteCurrent)
                } label: {
                    Image(systemName: "trash").frame(width: 48, height: 48)
                }
                .buttonStyle(.plain).glassEffect(.regular.interactive(), in: .circle)
                .tint(.red)
                .accessibilityLabel("Delete")
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .font(.system(size: 18))
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
    }

    private func save(_ item: PhotoItem) {
        saving = true
        Task {
            defer { saving = false }
            do {
                let withRaw = try await library.saveToPhotos(item)
                saved.insert(item.id)
                Haptics.bump()
                show(withRaw ? nil : "Saved without the RAW. Photos wouldn't take the pair.")
            } catch {
                show(error.localizedDescription)
            }
        }
    }

    private func shareCurrent() {
        guard let item = current, !preparingShare else { return }
        preparingShare = true
        Task {
            defer { preparingShare = false }
            do {
                if library.merging.contains(item.id) { withAnimation { note = "Finishing the burst merge…" } }
                await library.awaitMerge(item.id)
                withAnimation { note = "Preparing to share…" }
                let url = try await RenderEngine.shared.export(url: library.rawURL(item), grade: item.grade, seed: item.seed, settings: library.settings)
                withAnimation { note = nil }
                sharing = ShareFile(url: url)
            } catch { show("\(error)") }
        }
    }

    private func deleteCurrent() {
        guard let i = library.items.firstIndex(where: { $0.id == selection }) else { return }
        let id = selection
        let next = library.items.indices.contains(i + 1) ? library.items[i + 1].id : i > 0 ? library.items[i - 1].id : nil
        withAnimation(Motion.smooth) {
            if let next { selection = next } else { dismiss() }
            library.delete(id)
        }
    }

    private func show(_ text: String?) {
        guard let text else { return }
        withAnimation { note = text }
        Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            withAnimation { note = nil }
        }
    }
}

private struct EditTarget: Identifiable { let id: UUID }

struct ShareFile: Identifiable {
    let url: URL
    var id: URL { url }
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ c: UIActivityViewController, context: Context) {}
}

private struct PhotoPage: View {
    let library: Library
    let item: PhotoItem
    var isCurrent = true
    // off in the editor, grade changes would queue full res renders that cant be cancelled
    var prefetches = true
    var onTap: () -> Void = {}
    @State private var image: UIImage?
    @State private var failed: String?
    @State private var framed: CGSize?

    private struct RenderKey: Hashable { let grade: Grade; let merge: Int }
    private struct PrefetchKey: Hashable { let render: RenderKey; let current: Bool; let merging: Bool; let enabled: Bool }
    private var key: RenderKey { RenderKey(grade: item.grade, merge: library.mergeStamp[item.id] ?? 0) }

    var body: some View {
        let url = library.rawURL(item), grade = item.grade, seed = item.seed
        // only the visible page gets a full res render, never the photo a merge is rewriting
        let detail: ZoomableImage.Detail = { @Sendable in try? await DetailEngine.shared.fullResolution(url: url, grade: grade, seed: seed) }
        ZoomableImage(image: image ?? library.thumbnail(item.id), sourceSize: framed, detailKey: key,
                      allowsDetail: isCurrent && !library.merging.contains(item.id), keepsDetail: isCurrent, onTap: onTap, detail: detail)
            .overlay {
                if let failed {
                    Text(failed).font(.footnote).foregroundStyle(Ink.stone).padding(30).multilineTextAlignment(.center)
                } else if image == nil, library.thumbnail(item.id) == nil {
                    ProgressView()
                }
            }
            .task(id: key) {
                do {
                    let useDisk = library.settings.useDiskCache
                    let cg = try await RenderEngine.shared.preview(url: url, grade: grade, seed: seed, useDisk: useDisk)
                    image = UIImage(cgImage: cg)
                    failed = nil
                    framed = try? await RenderEngine.shared.framedSize(url: url, grade: grade, useDisk: useDisk)
                } catch {
                    if image == nil { failed = "\(error)" }
                }
            }
            .task(id: PrefetchKey(render: key, current: isCurrent, merging: library.merging.contains(item.id), enabled: prefetches)) {
                guard isCurrent, prefetches, !library.merging.contains(item.id) else { return }
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                _ = try? await DetailEngine.shared.fullResolution(url: url, grade: grade, seed: seed)
            }
    }
}

struct ZoomableImage: UIViewRepresentable {
    typealias Detail = @Sendable () async -> CGImage?
    let image: UIImage?
    var sourceSize: CGSize? = nil
    var detailKey: AnyHashable? = nil
    var allowsDetail = true
    var keepsDetail = true
    var onTap: () -> Void = {}
    var detail: Detail? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let s = UIScrollView()
        s.maximumZoomScale = 6
        s.minimumZoomScale = 1
        s.delegate = context.coordinator
        s.showsHorizontalScrollIndicator = false
        s.showsVerticalScrollIndicator = false
        s.backgroundColor = .black
        s.contentInsetAdjustmentBehavior = .never
        let v = context.coordinator.imageView
        v.contentMode = .scaleAspectFit
        v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        v.isAccessibilityElement = true
        v.accessibilityLabel = "Photo"
        s.addSubview(v)
        let d = context.coordinator.detailView
        d.contentMode = .scaleToFill
        d.autoresizingMask = [.flexibleWidth, .flexibleHeight, .flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]
        d.alpha = 0
        v.addSubview(d)
        context.coordinator.scrollView = s
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        tap.numberOfTapsRequired = 2
        s.addGestureRecognizer(tap)
        let single = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.singleTap))
        single.require(toFail: tap)
        s.addGestureRecognizer(single)
        return s
    }

    func updateUIView(_ s: UIScrollView, context: Context) {
        let c = context.coordinator
        c.onTap = onTap
        c.detail = detail
        c.allowsDetail = allowsDetail
        if c.detailKey != detailKey {
            c.detailKey = detailKey
            c.clearDetail(forgetFailure: true)
        }
        if !keepsDetail, c.hasDetail || c.isRequesting {
            c.clearDetail(forgetFailure: false)
            if s.zoomScale != 1 { s.setZoomScale(1, animated: false) }
        }
        if !c.hasDetail { c.sourceSize = sourceSize }
        if c.imageView.image !== image {
            UIView.transition(with: c.imageView, duration: c.imageView.image == nil ? 0 : 0.25,
                              options: [.transitionCrossDissolve, .allowUserInteraction]) { c.imageView.image = image }
        }
        DispatchQueue.main.async {
            if s.zoomScale == 1 { c.imageView.frame = s.bounds; s.contentSize = s.bounds.size }
            c.updateZoomLimit()
            c.refine()
        }
    }

    @MainActor final class Coordinator: NSObject, UIScrollViewDelegate {
        let imageView = UIImageView()
        let detailView = UIImageView()
        weak var scrollView: UIScrollView?
        var onTap: () -> Void = {}
        var detail: Detail?
        var sourceSize: CGSize?
        var detailKey: AnyHashable?
        var allowsDetail = true
        private var request: Task<Void, Never>?
        private var generation = 0
        private var shown = false
        private var failed = false
        var hasDetail: Bool { shown }
        var isRequesting: Bool { request != nil }

        @objc func singleTap() { onTap() }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
        @objc func doubleTap(_ g: UITapGestureRecognizer) {
            guard let s = g.view as? UIScrollView else { return }
            s.setZoomScale(s.zoomScale > 1 ? 1 : 3, animated: true)
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) { refine() }
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { refine() }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { if !decelerate { refine() } }

        private var imageRect: CGRect? {
            guard let size = imageView.image?.size, size.width > 0, size.height > 0 else { return nil }
            return AVMakeRect(aspectRatio: size, insideRect: imageView.bounds)
        }

        func clearDetail(forgetFailure: Bool = true) {
            request?.cancel(); request = nil
            generation += 1
            shown = false
            if forgetFailure { failed = false }
            detailView.image = nil
            detailView.alpha = 0
        }

        func updateZoomLimit() {
            guard let s = scrollView, let rect = imageRect, rect.width > 0 else { return }
            let screen = s.window?.screen.scale ?? 3
            let native = sourceSize.map { $0.width / (rect.width * screen) } ?? 3
            s.maximumZoomScale = min(max(native * 2, 6), 16)
        }

        func refine() {
            guard let s = scrollView, let rect = imageRect, let detail, let source = sourceSize,
                  let base = imageView.image, s.bounds.width > 0, let window = s.window,
                  window.bounds.intersects(s.convert(s.bounds, to: window).insetBy(dx: 2, dy: 2)) else { return }
            let screen = window.screen.scale
            let visible = s.convert(s.bounds, to: imageView).intersection(rect)
            guard !visible.isNull, visible.width > 0, visible.height > 0 else { return }
            let onScreen = visible.width * s.zoomScale * screen
            let fraction = visible.width / rect.width
            let basePixels = fraction * base.size.width * base.scale
            let sourcePixels = fraction * source.width
            if basePixels >= min(onScreen, sourcePixels) * 0.9 {
                if s.zoomScale <= 1.01 { clearDetail() }
                return
            }
            guard allowsDetail, !shown, !failed, request == nil else { return }
            // cancelled renders still finish so only the latest one touches state
            generation += 1
            let mine = generation
            request = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled else { return }
                let image = await detail()
                let prepared = await image.map { UIImage(cgImage: $0) }?.byPreparingForDisplay()
                guard let self, self.generation == mine else { return }
                self.request = nil
                guard let image, let rect = self.imageRect else { self.failed = true; return }
                self.shown = true
                self.sourceSize = CGSize(width: image.width, height: image.height)
                self.updateZoomLimit()
                self.detailView.image = prepared ?? UIImage(cgImage: image)
                self.detailView.frame = rect
                UIView.animate(withDuration: 0.2) { self.detailView.alpha = 1 }
            }
        }
    }
}

private struct InfoPanel: View {
    let library: Library
    let item: PhotoItem
    @State private var rows: [(String, String)] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Taken", value: item.created.formatted(date: .abbreviated, time: .shortened))
                    if let tag = item.driveTag { LabeledContent("Drive", value: tag) }
                    if let alg = item.mergeAlg {
                        LabeledContent("Stack", value: (item.isNightBurst ? "Night burst, " : "")
                                       + (item.superResolved == true ? (item.isNightBurst ? "super-resolution" : "Super-resolution") : (item.isNightBurst ? "merged" : "Merged"))
                                       + " (alg \(alg))"
                                       + (item.extraFrames.isEmpty ? "" : ", \(item.extraFrames.count + 1) frames kept"))
                    } else if !item.extraFrames.isEmpty {
                        LabeledContent("Stack", value: library.merging.contains(item.id) ? (item.isNightBurst ? "Night burst, merging…" : "Merging…")
                                       : (item.isNightBurst ? "Night burst, " : "") + "\(item.extraFrames.count + 1) frames, unmerged")
                    }
                }
                if library.canRemerge(item) || (item.mergeAlg == nil && !item.extraFrames.isEmpty) {
                    Section {
                        Button(item.mergeAlg == nil ? "Merge Burst" : "Merge Again") { library.remerge(item.id) }
                            .disabled(library.merging.contains(item.id))
                    } footer: {
                        Text("Merges the kept burst frames into the RAW again.")
                    }
                }
                Section { ForEach(rows, id: \.0) { LabeledContent($0.0, value: $0.1) } }
            }
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            let url = library.rawURL(item)
            rows = await Task.detached { Library.details(of: url) }.value
        }
    }
}
