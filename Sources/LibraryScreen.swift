// Crepuscule - LibraryScreen.swift
// Constantin Clerc (c22dev) - 0.1
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct LibraryScreen: View {
    let library: Library
    let close: () -> Void
    @State private var path: [UUID]
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showPhotosPicker = false
    @State private var showFiles = false
    @State private var importing = false
    @State private var problem: String?
    @State private var selecting = false
    @State private var selected: Set<UUID> = []
    @State private var confirmDelete = false
    @State private var saving = false
    @Namespace private var zoom

    init(library: Library, openNewest: Bool, close: @escaping () -> Void) {
        self.library = library
        self.close = close
        _path = State(initialValue: openNewest ? library.newest.map { [$0.id] } ?? [] : [])
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if library.items.isEmpty {
                    ContentUnavailableView {
                        Label("No Photos", systemImage: "photo.on.rectangle")
                    } description: {
                        Text("Shoot something, or import a DNG.")
                    } actions: {
                        Button("Import") { showFiles = true }.buttonStyle(.glass)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            DayGrid(library: library, zoom: zoom, selecting: selecting, selected: $selected)
                                .padding(.top, 8)
                                .padding(.bottom, 20)
                        }
                        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
                        .onAppear { if let last = library.newest?.id { proxy.scrollTo(last, anchor: .bottom) } }
                    }
                }
            }
            .background(Ink.ground.ignoresSafeArea())
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .safeAreaInset(edge: .bottom, spacing: 0) { if selecting { selectionBar.transition(.move(edge: .bottom).combined(with: .opacity)) } }
            .navigationDestination(for: UUID.self) { id in
                PhotoPager(library: library, start: id, close: close)
                    .navigationTransition(.zoom(sourceID: id, in: zoom))
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .photosPicker(isPresented: $showPhotosPicker, selection: $pickerItems, matching: .images, preferredItemEncoding: .current)
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.rawImage, UTType(filenameExtension: "dng") ?? .rawImage], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { importFiles(urls) }
        }
        .onChange(of: pickerItems) { _, new in
            guard !new.isEmpty else { return }
            importPicked(new)
            pickerItems = []
        }
        .alert("Couldn't Import", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(problem ?? "") }
    }

    private var header: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 12) {
                Button(action: close) {
                    Image(systemName: "camera").font(.system(size: 18)).frame(width: 48, height: 48)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Back to camera")
                VStack(alignment: .leading, spacing: 1) {
                    Text("Library").font(.display(.title2))
                    Text(library.items.count == 1 ? "1 Photo" : "\(library.items.count) Photos")
                        .engraved(.caption2).foregroundStyle(Ink.stone)
                        .contentTransition(.numericText())
                        .animation(Motion.snappy, value: library.items.count)
                }
                .shadow(color: .black.opacity(0.5), radius: 6)
                Spacer()
                if importing { ProgressView().controlSize(.small) }
                Menu {
                    Button { showPhotosPicker = true } label: { Label("From Photos", systemImage: "photo.on.rectangle") }
                    Button { showFiles = true } label: { Label("From Files", systemImage: "folder") }
                } label: {
                    Image(systemName: "plus").font(.system(size: 16, weight: .medium)).frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Import RAW photos")
                Button {
                    withAnimation(Motion.snappy) { selecting.toggle(); selected = [] }
                } label: {
                    Text(selecting ? "Cancel" : "Select").font(.system(size: 16, weight: .medium))
                        .contentTransition(.interpolate)
                        .frame(height: 44).padding(.horizontal, 16)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive())
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 8)
        }
    }

    private var selectionBar: some View {
        HStack {
            Button {
                saving = true
                let picks = library.items.filter { selected.contains($0.id) }
                Task {
                    defer { saving = false }
                    do {
                        for item in picks { try await library.saveToPhotos(item) }
                        withAnimation { selecting = false; selected = [] }
                    } catch { problem = error.localizedDescription }
                }
            } label: {
                Group {
                    if saving { ProgressView().controlSize(.small) } else { Image(systemName: "square.and.arrow.down") }
                }
                .frame(width: 48, height: 48)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("Save to Photos")
            Spacer()
            Text(selected.isEmpty ? "Select Photos" : "\(selected.count) Selected").font(.headline).monospacedDigit()
                .contentTransition(.numericText())
                .animation(Motion.snappy, value: selected.count)
            Spacer()
            Button { confirmDelete = true } label: {
                Image(systemName: "trash").frame(width: 48, height: 48)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("Delete")
            .confirmationDialog("Delete \(selected.count) photos and their RAWs?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete \(selected.count) Photos", role: .destructive) {
                    withAnimation(Motion.smooth) {
                        selected.forEach(library.delete)
                        selected = []
                        selecting = false
                    }
                }
            }
        }
        .disabled(selected.isEmpty || saving)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func importFiles(_ urls: [URL]) {
        importing = true
        Task {
            defer { importing = false }
            var failed: [String] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do { try library.add(raw: url, aspect: .native, driveTag: nil, move: false) } catch { failed.append(url.lastPathComponent) }
            }
            if !failed.isEmpty { problem = "\(failed.joined(separator: ", ")) couldn't be read as RAW." }
        }
    }

    private func importPicked(_ picks: [PhotosPickerItem]) {
        importing = true
        Task {
            defer { importing = false }
            var skipped = 0
            for pick in picks {
                guard pick.supportedContentTypes.contains(where: { $0.conforms(to: .rawImage) }),
                      let data = try? await pick.loadTransferable(type: Data.self) else { skipped += 1; continue }
                let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".dng")
                do {
                    try data.write(to: temp)
                    _ = try DNGMetadata(url: temp)
                    try library.add(raw: temp, aspect: .native, driveTag: nil)
                } catch {
                    skipped += 1
                    try? FileManager.default.removeItem(at: temp)
                }
            }
            if skipped > 0 { problem = "\(skipped) of \(picks.count) weren't RAW, so they were skipped." }
        }
    }
}

private struct DayGrid: View {
    let library: Library
    let zoom: Namespace.ID
    let selecting: Bool
    @Binding var selected: Set<UUID>
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    private var days: [(day: Date, items: [PhotoItem])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: library.items) { calendar.startOfDay(for: $0.created) }
        return groups.keys.sorted().map { ($0, groups[$0]!.sorted { $0.created < $1.created }) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(days, id: \.day) { day in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(day.day.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                            .font(.display(.headline))
                        Spacer()
                        Text("\(day.items.count)").font(.instrument(.caption)).foregroundStyle(Ink.stone)
                    }
                    .padding(.horizontal, 16)
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(day.items) { item in
                            Group { if selecting {
                                Button {
                                    withAnimation(Motion.pop) {
                                        if selected.remove(item.id) == nil { selected.insert(item.id) }
                                    }
                                    Haptics.tick()
                                } label: { GridCell(library: library, item: item, selecting: true, picked: selected.contains(item.id)) }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(selected.contains(item.id) ? .isSelected : [])
                            } else {
                                NavigationLink(value: item.id) {
                                    GridCell(library: library, item: item, selecting: false, picked: false)
                                        .matchedTransitionSource(id: item.id, in: zoom)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Photo, \(item.created.formatted(date: .abbreviated, time: .shortened))"
                                                    + (item.stackSummary.map { ", \($0)" } ?? "")
                                                    + (library.merging.contains(item.id) ? ", merging" : ""))
                            } }
                            .id(item.id)
                        }
                    }
                }
            }
        }
    }
}

private struct GridCell: View {
    let library: Library
    let item: PhotoItem
    let selecting: Bool
    let picked: Bool
    private var merging: Bool { library.merging.contains(item.id) }
    var body: some View {
        Color(white: 0.1).aspectRatio(1, contentMode: .fit)
            .overlay {
                if let t = library.thumbnail(item.id) {
                    Image(uiImage: t).resizable().scaledToFill()
                        .saturation(merging ? 0.55 : 1)
                        .animation(Motion.smooth, value: merging)
                        .scaleEffect(picked ? 0.88 : 1)
                        .clipShape(RoundedRectangle(cornerRadius: picked ? 8 : 0, style: .continuous))
                        .opacity(picked ? 0.75 : 1)
                }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                if let tag = item.driveTag {
                    Text(tag).engraved(size: 8.5).foregroundStyle(.white)
                        .shadow(radius: 2).padding(5)
                }
            }
            .overlay(alignment: .topTrailing) {
                if item.frameCount > 1 {
                    StackBadge(item: item, merging: merging).padding(5)
                        .opacity(picked ? 0 : 1)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if selecting {
                    Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, picked ? Ink.dusk : .black.opacity(0.25))
                        .font(.system(size: 22)).shadow(color: .black.opacity(0.3), radius: 2)
                        .contentTransition(.symbolEffect(.replace))
                        .padding(5)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
    }
}

private struct StackBadge: View {
    let item: PhotoItem
    let merging: Bool

    private var symbol: String {
        if item.isNightBurst { return "moon.fill" }
        if item.superResolved == true { return "plus.magnifyingglass" }
        return "square.stack.3d.down.right.fill"
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.pulse, options: .repeating, isActive: merging)
            if item.isNightBurst, item.superResolved == true {
                Image(systemName: "plus.magnifyingglass").transition(.opacity)
            } else if item.superResolved != true {
                Text("\(item.frameCount)").font(.instrument(9, weight: .semibold))
            }
        }
        .font(.system(size: 8.5, weight: .semibold))
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.35), radius: 1)
        .padding(.horizontal, 6)
        .frame(height: 17)
        .glassEffect(.regular.tint(.black.opacity(0.2)), in: .capsule)
        .opacity(merging ? 0.85 : 1)
        .animation(Motion.fade, value: merging)
        .animation(Motion.snappy, value: item.superResolved)
    }
}
