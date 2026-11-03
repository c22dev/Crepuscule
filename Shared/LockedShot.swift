// Crepuscule - LockedShot.swift
// Constantin Clerc (c22dev) - 0.1
import Foundation

struct LockedShot: Codable {
    struct Frame: Codable {
        var name: String
        var scale: Float
    }
    var base: String
    var frames: [Frame]
    var blur: [String: Float]
    var created: Date
    var night: Bool?
    var aspect: Int?
    var cropFactor: Double?
    var bias: Float?
    var tag: String?
    var look: Data?

    static let suffix = ".shot.json"
}
