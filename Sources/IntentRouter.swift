// Crepuscule - IntentRouter.swift
// Constantin Clerc (c22dev) - 0.1
import AppIntents
import Observation

enum IntentAction: Equatable {
    case camera
    case shoot(drive: DriveMode?, timer: SelfTimer?)
    case library
    case look(String)
}

@MainActor @Observable
final class IntentRouter {
    static let shared = IntentRouter()
    private(set) var pending: [IntentAction] = []
    func request(_ action: IntentAction) { pending.append(action) }
    func take() -> IntentAction? { pending.isEmpty ? nil : pending.removeFirst() }
}

struct LookEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Look"
    static let defaultQuery = LookQuery()
    let id: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(id)") }
}

struct LookQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [LookEntity] {
        let names = Library.storedLookNames()
        return identifiers.filter(names.contains).map(LookEntity.init)
    }
    func suggestedEntities() async throws -> [LookEntity] { Library.storedLookNames().map(LookEntity.init) }
}

struct SetLookIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Look"
    static let description = IntentDescription("Opens the Crepuscule camera with a look for new photos.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Look") var look: LookEntity

    static var parameterSummary: some ParameterSummary { Summary("Set look to \(\.$look)") }

    @MainActor func perform() async throws -> some IntentResult {
        IntentRouter.shared.request(.look(look.id))
        return .result()
    }
}

struct CrepusculeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CrepusculeCaptureIntent(), phrases: ["Open \(.applicationName)", "Open the \(.applicationName) camera"],
                    shortTitle: "Open Camera", systemImageName: "camera.aperture")
        AppShortcut(intent: TakePhotoIntent(), phrases: ["Take a photo with \(.applicationName)", "Shoot with \(.applicationName)"],
                    shortTitle: "Take Photo", systemImageName: "camera.shutter.button")
        AppShortcut(intent: OpenLibraryIntent(), phrases: ["Show my \(.applicationName) photos", "Open \(.applicationName) library"],
                    shortTitle: "Open Library", systemImageName: "photo.on.rectangle.angled")
        AppShortcut(intent: SetLookIntent(), phrases: ["Change the look in \(.applicationName)"],
                    shortTitle: "Set Look", systemImageName: "camera.filters")
    }
}
