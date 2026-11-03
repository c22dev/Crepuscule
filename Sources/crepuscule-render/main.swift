// Crepuscule - main.swift
// Constantin Clerc (c22dev) - 0.1
import Crepuscule
import Foundation

let usage = "usage: crepuscule-render <input.dng> <output.png> --lut <file.cube> [--preset default|optical|no-halation|bw] [--grade grade.json] [--seed N] [--max-dimension N] [--long-side N] [--quality 0-1]\n"
var positional: [String] = [], options: [String: String] = [:]
var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    if a.hasPrefix("--") { options[String(a.dropFirst(2))] = it.next() ?? "" } else { positional.append(a) }
}
guard positional.count == 2, let lutPath = options["lut"] else {
    FileHandle.standardError.write(Data(usage.utf8))
    exit(2)
}
do {
    var grade = Presets.factoryDefault
    if let name = options["preset"] {
        guard let p = Presets.all[name] else { throw PipelineError.decode("unknown preset \(name)") }
        grade = p
    }
    if let path = options["grade"] { grade = try JSONDecoder().decode(Grade.self, from: Data(contentsOf: URL(fileURLWithPath: path))) }
    let renderer = try ColorPipelineRenderer()
    let lut = try renderer.loadCube(url: URL(fileURLWithPath: lutPath))
    let image = try renderer.render(dng: URL(fileURLWithPath: positional[0]), grade: grade, lut: lut,
                                    seed: options["seed"].flatMap(Float.init), maxDimension: options["max-dimension"].flatMap(Int.init),
                                    exportLongSide: options["long-side"].flatMap(Int.init))
    let out = URL(fileURLWithPath: positional[1])
    switch out.pathExtension.lowercased() {
    case "jpg", "jpeg", "heic":
        guard let quality = options["quality"].flatMap(Float.init) else { throw PipelineError.decode("--quality is required for JPEG and HEIC") }
        let format: ExportFormat = out.pathExtension.lowercased() == "heic" ? .heic : .jpeg
        let meta = ExportEncoder.metadata(from: URL(fileURLWithPath: positional[0]), software: "crepuscule-render")
        try ExportEncoder.encode(image, format: format, quality: quality, metadata: meta).write(to: out)
    default:
        try ColorPipelineRenderer.writePNG(image, to: out)
    }
    print("wrote \(positional[1]) (\(image.width)x\(image.height))")
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
