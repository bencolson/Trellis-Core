//
//  main.swift
//  TrellisCore
//
//  Created by Ben Colson on 06/10/2026.
//

import Foundation
import TrellisCore

// Interim front end. `build` and `validate`, `--json` and proper exit codes
// are still to come.
var args = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("trellis: \(message)\n".utf8))
    exit(code)
}

/// Removes `--name value` from `args`, returning the value.
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name) else { return nil }
    guard i + 1 < args.count else { fail("\(name) needs a value") }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}

/// Removes `--name` from `args`, returning whether it was present.
func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}

func printSpaces() {
    let spaces: [ColorSpace] = [.adobeRGB1998, .rec709Gamma24, .rec709Gamma22]
    for space in spaces {
        print(space.label)
        print("  RGB → XYZ: \(space.primaries.rgbToXYZ)")
    }
    let m = RGBPrimaries.rec709.matrix(to: .adobeRGB1998)
    print("Rec. 709 → Adobe RGB (1998), linear: \(m)")
}

func hald() {
    let levelText = option("--level") ?? "8"
    guard let level = Int(levelText), level == 8 || level == 12 else {
        fail("--level must be 8 or 12 (got \(levelText))")
    }
    let out = URL(fileURLWithPath: option("--out") ?? ".", isDirectory: true)
    let withValidation = flag("--with-validation")
    let withReversed = flag("--with-reversed")
    if let extra = args.first { fail("unexpected argument '\(extra)'") }

    do {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let spec = HaldSpec(level: level)
        let haldURL = out.appendingPathComponent("identity-hald-L\(level).tif")
        try Tiff.write(HaldGenerator.identityImage(spec), to: haldURL)
        print("Wrote \(haldURL.path)  (\(spec.size)×\(spec.size), \(spec.steps) steps, 16-bit, Adobe RGB (1998))")
        if withReversed {
            let revURL = out.appendingPathComponent("reversed-hald-L\(level).tif")
            try Tiff.write(HaldGenerator.reversedImage(spec), to: revURL)
            print("Wrote \(revURL.path)")
        }
        if withValidation {
            let valURL = out.appendingPathComponent("validation.tif")
            try Tiff.write(HaldGenerator.validationImage(), to: valURL)
            print("Wrote \(valURL.path)")
        }
    } catch {
        fail("\(error)", code: 1)
    }
}

func inspect() {
    guard let path = args.first else { fail("inspect needs a TIFF path") }
    do {
        let data = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
        print(path)
        print(try Tiff.inspect(data))
        do {
            let image = try Tiff.decode(data)
            let level = HaldSpec(width: image.width, height: image.height).map { "Hald level \($0.level)" } ?? "not Hald-shaped"
            print("decodable         yes (\(level))")
        } catch {
            print("decodable         NO: \(error)")
        }
    } catch {
        fail("\(error)", code: 1)
    }
}

let command = args.isEmpty ? nil : args.removeFirst()
switch command {
case "--version", "version":
    print("trellis \(Trellis.version)")
case "spaces":
    printSpaces()
case "hald":
    hald()
case "inspect":
    inspect()
default:
    print("""
    trellis \(Trellis.version)

    Usage:
      trellis version     Print the version
      trellis spaces      Print the colour spaces and matrices Trellis uses
      trellis hald [--level 8|12] [--out DIR] [--with-validation] [--with-reversed]
                          Write an identity Hald (16-bit TIFF, Adobe RGB (1998))
      trellis inspect FILE.tif
                          Describe a TIFF's layout and profile (e.g. a Capture One export)

    Coming soon: trellis build | validate
    """)
}
