// Crepuscule - CaptureIntents.swift
// Constantin Clerc (c22dev) - 0.1
import AppIntents
import Foundation

struct LockedCaptureContext: Codable, Sendable {
    var stack = true
    var muteShutter = false
    var shutterLimit = 0
    var nightBursts = true
    var highlightRetentionStops = 2.0

    init(stack: Bool = true, muteShutter: Bool = false, shutterLimit: Int = 0, nightBursts: Bool = true, highlightRetentionStops: Double = 2) {
        self.stack = stack; self.muteShutter = muteShutter; self.shutterLimit = shutterLimit
        self.nightBursts = nightBursts; self.highlightRetentionStops = highlightRetentionStops
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stack = try c.decodeIfPresent(Bool.self, forKey: .stack) ?? true
        muteShutter = try c.decodeIfPresent(Bool.self, forKey: .muteShutter) ?? false
        shutterLimit = try c.decodeIfPresent(Int.self, forKey: .shutterLimit) ?? 0
        nightBursts = try c.decodeIfPresent(Bool.self, forKey: .nightBursts) ?? true
        highlightRetentionStops = try c.decodeIfPresent(Double.self, forKey: .highlightRetentionStops) ?? 2
    }
}

struct CrepusculeCaptureIntent: CameraCaptureIntent {
    typealias AppContext = LockedCaptureContext
    static let title: LocalizedStringResource = "Open Camera"
    static let description = IntentDescription("Opens the Crepuscule camera, even from the Lock Screen.")

    @MainActor func perform() async throws -> some IntentResult {
        #if CREPUSCULE_APP
        IntentRouter.shared.request(.camera)
        #endif
        return .result()
    }
}

enum DriveOption: String, AppEnum {
    case single, burst3, burst5, bracket3, bracket5
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Drive"
    static let caseDisplayRepresentations: [DriveOption: DisplayRepresentation] = [
        .single: "Single", .burst3: "Burst 3", .burst5: "Burst 5", .bracket3: "Bracket 3", .bracket5: "Bracket 5",
    ]
}

enum TimerOption: Int, AppEnum {
    case off = 0, three = 3, ten = 10
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Timer"
    static let caseDisplayRepresentations: [TimerOption: DisplayRepresentation] = [
        .off: "Off", .three: "3 Seconds", .ten: "10 Seconds",
    ]
}

struct TakePhotoIntent: AppIntent {
    static let title: LocalizedStringResource = "Take Photo"
    static let description = IntentDescription("Opens Crepuscule and takes a RAW photo. Drive and timer apply to this shot only.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Drive") var drive: DriveOption?
    @Parameter(title: "Timer") var timer: TimerOption?

    static var parameterSummary: some ParameterSummary {
        Summary("Take a photo") {
            \.$drive
            \.$timer
        }
    }

    @MainActor func perform() async throws -> some IntentResult {
        #if CREPUSCULE_APP
        IntentRouter.shared.request(.shoot(drive: drive.flatMap { .init(rawValue: $0.rawValue) }, timer: timer.flatMap { .init(rawValue: $0.rawValue) }))
        #endif
        return .result()
    }
}

struct OpenLibraryIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Library"
    static let description = IntentDescription("Opens your latest Crepuscule photo.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @MainActor func perform() async throws -> some IntentResult {
        #if CREPUSCULE_APP
        IntentRouter.shared.request(.library)
        #endif
        return .result()
    }
}
