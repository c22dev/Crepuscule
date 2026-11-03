// Crepuscule - CrepusculeControls.swift
// Constantin Clerc (c22dev) - 0.1
import AppIntents
import SwiftUI
import WidgetKit

@main
struct CrepusculeWidgets: WidgetBundle {
    var body: some Widget {
        OpenCameraControl()
        TakePhotoControl()
        OpenLibraryControl()
    }
}

struct OpenCameraControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "ch.cclerc.crepuscule.camera") {
            ControlWidgetButton(action: CrepusculeCaptureIntent()) {
                Label("Crepuscule", systemImage: "camera.aperture")
            }
        }
        .displayName("Open Camera")
        .description("Opens the Crepuscule camera, even from the Lock Screen.")
    }
}

struct TakePhotoControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "ch.cclerc.crepuscule.shoot") {
            ControlWidgetButton(action: TakePhotoIntent()) {
                Label("Take Photo", systemImage: "camera.shutter.button")
            }
        }
        .displayName("Take Photo")
        .description("Opens Crepuscule and takes a photo.")
    }
}

struct OpenLibraryControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "ch.cclerc.crepuscule.library") {
            ControlWidgetButton(action: OpenLibraryIntent()) {
                Label("Library", systemImage: "photo.on.rectangle.angled")
            }
        }
        .displayName("Open Library")
        .description("Opens your latest Crepuscule photo.")
    }
}
