// Crepuscule - PhotoPager.swift
// Constantin Clerc (c22dev) - 0.1
import Crepuscule
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
                    PhotoPage(library: library, item: item) { withAnimation(Motion.fade) { chromeHidden.toggle() } }
                        .tag(item.id).ignoresSafeArea()
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
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
    var onTap: () -> Void = {}
    @State private var image: UIImage?
    @State private var failed: String?

    private struct RenderKey: Equatable { let grade: Grade; let merge: Int }

    var body: some View {
        ZoomableImage(image: image ?? library.thumbnail(item.id), onTap: onTap)
            .overlay {
                if let failed {
                    Text(failed).font(.footnote).foregroundStyle(Ink.stone).padding(30).multilineTextAlignment(.center)
                } else if image == nil, library.thumbnail(item.id) == nil {
                    ProgressView()
                }
            }
            .task(id: RenderKey(grade: item.grade, merge: library.mergeStamp[item.id] ?? 0)) {
                do {
                    let cg = try await RenderEngine.shared.preview(url: library.rawURL(item), grade: item.grade, seed: item.seed, useDisk: library.settings.useDiskCache)
                    image = UIImage(cgImage: cg)
                    failed = nil
                } catch {
                    if image == nil { failed = "\(error)" }
                }
            }
    }
}

struct ZoomableImage: UIViewRepresentable {
    let image: UIImage?
    var onTap: () -> Void = {}

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
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        tap.numberOfTapsRequired = 2
        s.addGestureRecognizer(tap)
        let single = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.singleTap))
        single.require(toFail: tap)
        s.addGestureRecognizer(single)
        return s
    }

    func updateUIView(_ s: UIScrollView, context: Context) {
        context.coordinator.onTap = onTap
        if context.coordinator.imageView.image !== image {
            UIView.transition(with: context.coordinator.imageView, duration: context.coordinator.imageView.image == nil ? 0 : 0.25,
                              options: [.transitionCrossDissolve, .allowUserInteraction]) { context.coordinator.imageView.image = image }
        }
        DispatchQueue.main.async {
            if s.zoomScale == 1 { context.coordinator.imageView.frame = s.bounds; s.contentSize = s.bounds.size }
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let imageView = UIImageView()
        var onTap: () -> Void = {}
        @objc func singleTap() { onTap() }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
        @objc func doubleTap(_ g: UITapGestureRecognizer) {
            guard let s = g.view as? UIScrollView else { return }
            s.setZoomScale(s.zoomScale > 1 ? 1 : 3, animated: true)
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
