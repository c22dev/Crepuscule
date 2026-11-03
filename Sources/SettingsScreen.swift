// Crepuscule - SettingsScreen.swift
// Constantin Clerc (c22dev) - 0.1
import SwiftUI

struct SettingsScreen: View {
    @Bindable var library: Library
    @Bindable var camera: CameraModel
    @State private var confirmReset = false
    @State private var introOpen = false
    @State private var cacheBytes = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink { CameraSettings(camera: camera) } label: {
                        SettingsRow("Camera", "camera.fill", Color(white: 0.42), value: camera.aspect.label)
                    }
                    NavigationLink { CaptureSettings(library: library, camera: camera) } label: {
                        SettingsRow("Capture", "square.stack.3d.down.right.fill", Ink.dusk, value: library.burstMerge ? "Burst Merge" : "Single Frame")
                    }
                    NavigationLink { ExportSettings(library: library) } label: {
                        SettingsRow("Export", "square.and.arrow.up.fill", Ink.ember, value: exportSummary)
                    }
                    NavigationLink { LibrarySettings(library: library, cacheBytes: $cacheBytes) } label: {
                        SettingsRow("Library", "photo.on.rectangle.angled.fill", .teal, value: librarySummary)
                    }
                }
                Section {
                    Button("Show Introduction") { introOpen = true }
                    Button("Reset Settings", role: .destructive) { confirmReset = true }
                        .confirmationDialog("Reset all settings? Your photos aren't affected.", isPresented: $confirmReset, titleVisibility: .visible) {
                            Button("Reset Settings", role: .destructive, action: resetAll)
                        }
                } footer: {
                    VStack(spacing: Space.xs) {
                        Text("Crepuscule").font(.display(.title3, weight: .regular)).foregroundStyle(Ink.paper.opacity(0.85))
                        Text("proudly made by c22dev").font(.caption).foregroundStyle(Ink.paper.opacity(0.7))
                        Text(version).font(.instrument(.caption2))
                    }
                    .frame(maxWidth: .infinity).padding(.top, Space.l)
                    .accessibilityElement(children: .combine)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                }
            }
            .fullScreenCover(isPresented: $introOpen) { IntroductionView { introOpen = false } }
            .onAppear { Task { cacheBytes = await RenderEngine.shared.cacheBytes() } }
        }
    }

    private var exportSummary: String {
        let format = library.settings.exportFormat == .heic ? "HEIF" : "JPEG"
        let size = library.settings.exportLongSide.map { "\($0) px" } ?? "Full"
        return "\(format) · \(size)"
    }

    private var librarySummary: String {
        library.settings.useDiskCache ? ByteCountFormatter.string(fromByteCount: Int64(cacheBytes), countStyle: .file) : "No Cache"
    }

    private var version: String {
        let i = Bundle.main.infoDictionary
        return "\(i?["CFBundleShortVersionString"] as? String ?? "0.1") (\(i?["CFBundleVersion"] as? String ?? "1"))"
    }

    private func resetAll() {
        library.settings = AppSettings()
        library.attachRaw = true
        library.captureFrameStack = false
        library.burstMerge = true
        library.bracketMetering = .locked
        library.appleVignetteAmount = 1
        camera.shutterLimit = 0
        camera.muteShutter = false
        camera.nightBursts = true
        library.autoNightClean = true
        camera.scanCodes = true
        camera.showGrid = false
        camera.showLook = false
        camera.aspect = .native
        for key in ["showHistogram", "lensReadout", "defaultLens"] { UserDefaults.standard.removeObject(forKey: key) }
    }
}

private struct SettingsRow: View {
    let title: String, symbol: String, color: Color, value: String
    init(_ title: String, _ symbol: String, _ color: Color, value: String) {
        (self.title, self.symbol, self.color, self.value) = (title, symbol, color, value)
    }
    var body: some View {
        LabeledContent {
            Text(value).monospacedDigit()
        } label: {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
                    .frame(width: 28, height: 28).background(color.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
    }
}

private struct CameraSettings: View {
    @Bindable var camera: CameraModel
    @AppStorage("lensReadout") private var readout = LensReadout.focal.rawValue
    @AppStorage("defaultLens") private var defaultLens = 0
    @AppStorage("showHistogram") private var showHistogram = false

    var body: some View {
        Form {
            Section("Viewfinder") {
                Toggle("Show Look", isOn: $camera.showLook)
                Toggle("Grid", isOn: $camera.showGrid)
                Toggle("Histogram", isOn: $showHistogram)
                Toggle("Scan Codes", isOn: $camera.scanCodes)
                Picker("Lens Readout", selection: $readout) {
                    ForEach(LensReadout.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
            }
            Section("Defaults") {
                Picker("Aspect Ratio", selection: Binding(get: { camera.aspect }, set: { camera.setAspect($0) })) {
                    ForEach(AspectRatioPreset.pickable, id: \.self) { Text("\($0.label) (\($0.figure))").tag($0) }
                }
                Picker("Lens", selection: $defaultLens) {
                    Text("Automatic").tag(0)
                    ForEach(camera.backLenses) { Text("\($0.focalLength) mm").tag($0.focalLength) }
                }
            }
            Section {
                Picker("Shutter Limit", selection: $camera.shutterLimit) {
                    Text("None").tag(0)
                    ForEach(CameraCapture.shutterLimitChoices, id: \.self) { Text("1/\($0) s").tag($0) }
                }
                Toggle("Mute Shutter Sound", isOn: $camera.muteShutter)
            } header: { Text("Shutter") } footer: {
                Text("Shutter Limit is the slowest speed auto exposure will choose.")
            }
        }
        .navigationTitle("Camera")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct CaptureSettings: View {
    @Bindable var library: Library
    @Bindable var camera: CameraModel

    var body: some View {
        Form {
            Section {
                Toggle("Burst Merge", isOn: $library.burstMerge.animation(Motion.smooth))
            } footer: {
                Text("Combines several frames for less noise and more highlight detail.")
            }
            if library.burstMerge {
                Section {
                    Stepper(value: $library.settings.highlightRetentionStops, in: 0.5...4, step: 0.5) {
                        LabeledContent("Highlight Protection", value: String(format: "%.1f stops", library.settings.highlightRetentionStops))
                    }
                    Toggle("Night Bursts", isOn: $camera.nightBursts.animation(Motion.smooth))
                    if camera.nightBursts { Toggle("Auto Night Clean", isOn: $library.autoNightClean) }
                    Toggle("Keep Burst Frames", isOn: $library.captureFrameStack)
                } footer: {
                    Text("In low light, Night Bursts takes up to 16 short frames; a moon shows by the exposure when it will. Auto Night Clean smooths the dark sky on those shots, and you can still turn it on per photo in the editor. Keeping burst frames lets you merge again later, but uses much more space.")
                }
            }
            Section {
                Picker("Bracket Metering", selection: $library.bracketMetering) {
                    Text("Locked").tag(CameraCapture.BracketMetering.locked)
                    Text("Closed Loop").tag(CameraCapture.BracketMetering.closedLoop)
                    Text("Native").tag(CameraCapture.BracketMetering.native)
                }
            } header: { Text("Bracketing") } footer: {
                Text("Locked uses the first reading. Closed Loop re-meters each frame. Native is fastest.")
            }
            Section {
                VStack(alignment: .leading) {
                    LabeledContent("Vignette Correction", value: "\(Int((library.appleVignetteAmount * 100).rounded()))%")
                    Slider(value: $library.appleVignetteAmount, in: 0...1, step: 0.05)
                }
            } header: { Text("Lens") } footer: {
                Text("How much of Apple's vignette correction to apply. Lower keeps more natural lens shading.")
            }
        }
        .navigationTitle("Capture")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ExportSettings: View {
    @Bindable var library: Library
    private var size: Binding<Int> {
        Binding(get: { library.settings.exportLongSide ?? 0 }, set: { library.settings.exportLongSide = $0 == 0 ? nil : $0 })
    }
    private var quality: Binding<Int> {
        Binding(get: { Int((library.settings.exportQuality * 100).rounded()) }, set: { library.settings.exportQuality = Float($0) / 100 })
    }

    var body: some View {
        Form {
            Section("File") {
                Picker("Format", selection: $library.settings.exportFormat) {
                    Text("HEIF").tag(AppSettings.Format.heic)
                    Text("JPEG").tag(AppSettings.Format.jpeg)
                }
                Picker("Size", selection: size) {
                    Text("Full Size").tag(0)
                    ForEach([6144, 4096, 2880, 1920], id: \.self) { Text("\($0) px").tag($0) }
                }
                Picker("Quality", selection: quality) {
                    ForEach([100, 95, 90, 85, 80, 70], id: \.self) { Text("\($0)%").tag($0) }
                }
            }
            Section {
                Toggle("Save Each Shot to Photos", isOn: $library.settings.autoExport)
                Toggle("Keep RAW with Photo", isOn: $library.attachRaw)
            } header: { Text("Photos") } footer: {
                Text("Size is the long edge of the exported image.")
            }
        }
        .navigationTitle("Export")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LibrarySettings: View {
    @Bindable var library: Library
    @Binding var cacheBytes: Int

    var body: some View {
        Form {
            Section {
                LabeledContent("Default Grade", value: library.settings.perImageDefaults == Grade() ? "None" : "Custom")
                if library.settings.perImageDefaults != Grade() {
                    Button("Clear Default Grade", role: .destructive) {
                        withAnimation(Motion.smooth) { library.settings.perImageDefaults = Grade() }
                    }
                }
            } header: { Text("Editing") } footer: { Text("New photos open with this grade, and Show Look previews it in the viewfinder. Set it from the editor's More menu.") }
            Section {
                Toggle("Keep Proxies on Disk", isOn: $library.settings.useDiskCache)
                LabeledContent("Proxy Cache", value: ByteCountFormatter.string(fromByteCount: Int64(cacheBytes), countStyle: .file))
                Button("Clear Proxy Cache", role: .destructive) {
                    Task {
                        await RenderEngine.shared.clearCache()
                        cacheBytes = await RenderEngine.shared.cacheBytes()
                    }
                }
                .disabled(cacheBytes == 0)
            } header: { Text("Storage") } footer: {
                Text("Proxies make photos open and edit instantly. They're rebuilt from the RAW when needed, stored compressed, and the oldest are removed past 300 MB.")
            }
            Section("Credits") {
                Text(IntroCredits.settingsLine).font(.footnote).foregroundStyle(Ink.stone)
            }
        }
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.inline)
        .task { cacheBytes = await RenderEngine.shared.cacheBytes() }
    }
}
