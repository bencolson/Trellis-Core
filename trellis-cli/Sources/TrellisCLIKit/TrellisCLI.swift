//
//  TrellisCLI.swift
//  TrellisCore
//
//  Created by Ben Colson on 07/10/2026.
//

import Foundation
import TrellisCore

/// Command-line front end: `version | spaces | hald | build | validate | inspect`.
///
/// `run(_:)` never exits the process: the `trellis` executable writes the
/// returned strings and `exit`s with the code, and tests drive it directly.
/// Argument parsing is stdlib-only so the CLI stays portable (Linux CI builds
/// it). All commands accept `--json`, which replaces the human output on
/// stdout with a single JSON object; errors still go to stderr as text and the
/// exit code is unchanged.
///
/// Exit codes:
///   0  success (warnings may be printed)
///   1  runtime error — a file could not be read or written
///   2  usage error — unknown command, missing or invalid arguments
///   3  validation failed — the input is not a usable processed Hald, so no
///      .cube is written
///   4  identity test failed (`validate --identity` measured a non-identity
///      result beyond tolerance)
public enum TrellisCLI {

    public struct Result: Equatable, Sendable {
        public let code: Int32
        public let stdout: String
        public let stderr: String

        public init(code: Int32, stdout: String, stderr: String) {
            self.code = code
            self.stdout = stdout
            self.stderr = stderr
        }
    }

    public static func run(_ arguments: [String]) -> Result {
        var args = arguments
        let json = takeFlag("--json", from: &args)
        guard let command = args.first else { return help(json: json) }
        args.removeFirst()

        switch command {
        case "version": return version(json: json)
        case "spaces": return spaces(json: json)
        case "hald": return hald(args, json: json)
        case "build": return build(args, json: json)
        case "validate": return validate(args, json: json)
        case "verify-recipe": return verifyRecipe(args, json: json)
        case "inspect": return inspect(args)
        case "-h", "--help", "help": return help(json: json)
        default:
            return usageError("unknown command '\(command)'")
        }
    }

    // MARK: - Output collection

    private struct Out {
        var lines: [String] = []
        var errors: [String] = []
        var usageError: String?

        var text: String { lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n" }
        var errorText: String { errors.isEmpty ? "" : errors.joined(separator: "\n") + "\n" }

        mutating func add(_ s: String) { lines.append(s) }
        func done(_ code: Int32) -> Result { Result(code: code, stdout: text, stderr: errorText) }
    }

    private static func jsonString(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func jnull(_ value: Any?) -> Any { value ?? NSNull() }

    // MARK: - Argument parsing

    private static func takeOption(_ name: String, from args: inout [String], out: inout Out) -> String? {
        guard let i = args.firstIndex(of: name) else { return nil }
        guard i + 1 < args.count else {
            out.usageError = "\(name) needs a value"
            return nil
        }
        let value = args[i + 1]
        args.removeSubrange(i...i + 1)
        return value
    }

    private static func takeFlag(_ name: String, from args: inout [String]) -> Bool {
        guard let i = args.firstIndex(of: name) else { return false }
        args.remove(at: i)
        return true
    }

    private static func takePositional(_ name: String, from args: inout [String], out: inout Out) -> String? {
        guard let value = args.first else {
            out.usageError = "missing \(name)"
            return nil
        }
        args.removeFirst()
        return value
    }

    /// Fails on any leftover positional argument (commands take at most one).
    private static func rejectExtras(_ args: [String], out: inout Out) {
        if let extra = args.first { out.usageError = "unexpected argument '\(extra)'" }
    }

    private static func usageError(_ message: String) -> Result {
        Result(code: 2, stdout: "", stderr: "trellis: \(message)\nTry 'trellis --help'.\n")
    }

    private static func failure(_ message: String, code: Int32 = 1) -> Result {
        Result(code: code, stdout: "", stderr: "trellis: \(message)\n")
    }

    /// Commands return `nil` when parsing failed; this converts their partial
    /// output into a code-2 result.
    private static func parsed(_ out: Out) -> Result? {
        out.usageError.map { usageError($0) }
    }

    // MARK: - Commands

    private static func version(json: Bool) -> Result {
        if json {
            return Result(code: 0, stdout: jsonString(["command": "version", "version": Trellis.version]) + "\n", stderr: "")
        }
        return Result(code: 0, stdout: "trellis \(Trellis.version)\n", stderr: "")
    }

    private static func spaces(json: Bool) -> Result {
        let spaces: [ColorSpace] = [.adobeRGB1998, .rec709Gamma24, .rec709Gamma22]
        if json {
            let list = spaces.map { s -> [String: Any] in
                ["label": s.label, "rgb_to_xyz": s.primaries.rgbToXYZ.elements]
            }
            let rec709ToAdobe = RGBPrimaries.rec709.matrix(to: .adobeRGB1998).elements
            let string = jsonString(["command": "spaces", "spaces": list, "rec709_to_adobe": rec709ToAdobe])
            return Result(code: 0, stdout: string + "\n", stderr: "")
        }
        var out = Out()
        for s in spaces {
            out.add(s.label)
            out.add("  RGB → XYZ: \(s.primaries.rgbToXYZ)")
        }
        out.add("Rec. 709 → Adobe RGB (1998), linear: \(RGBPrimaries.rec709.matrix(to: .adobeRGB1998))")
        return out.done(0)
    }

    private static func hald(_ args: [String], json: Bool) -> Result {
        var args = args
        var out = Out()
        let levelText = takeOption("--level", from: &args, out: &out) ?? "8"
        guard let level = Int(levelText), level == 8 || level == 12 else {
            return out.usageError != nil ? parsed(out)! : usageError("--level must be 8 or 12 (got '\(levelText)')")
        }
        let outDir = takeOption("--out", from: &args, out: &out) ?? "."
        let withValidation = takeFlag("--with-validation", from: &args)
        let withReversed = takeFlag("--with-reversed", from: &args)
        rejectExtras(args, out: &out)
        if let u = parsed(out) { return u }

        var files: [[String: Any]] = []
        do {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: outDir, isDirectory: true), withIntermediateDirectories: true)
            let spec = HaldSpec(level: level)
            let haldURL = URL(fileURLWithPath: outDir, isDirectory: true).appendingPathComponent("identity-hald-L\(level).tif")
            try Tiff.write(HaldGenerator.identityImage(spec), to: haldURL)
            files.append(["kind": "identity", "level": level, "path": haldURL.path])
            out.add("Wrote \(haldURL.path)  (\(spec.size)×\(spec.size), \(spec.steps) steps, 16-bit, Adobe RGB (1998))")
            if withReversed {
                let revURL = URL(fileURLWithPath: outDir, isDirectory: true).appendingPathComponent("reversed-hald-L\(level).tif")
                try Tiff.write(HaldGenerator.reversedImage(spec), to: revURL)
                files.append(["kind": "reversed", "level": level, "path": revURL.path])
                out.add("Wrote \(revURL.path)")
            }
            if withValidation {
                let valURL = URL(fileURLWithPath: outDir, isDirectory: true).appendingPathComponent("validation.tif")
                try Tiff.write(HaldGenerator.validationImage(), to: valURL)
                files.append(["kind": "validation", "level": level, "path": valURL.path])
                out.add("Wrote \(valURL.path)")
            }
        } catch {
            return failure("\(error)")
        }
        if json {
            let string = jsonString(["command": "hald", "level": level, "files": files])
            return Result(code: 0, stdout: string + "\n", stderr: "")
        }
        return out.done(0)
    }

    private static func build(_ args: [String], json: Bool) -> Result {
        var args = args
        var out = Out()
        guard let path = takePositional("PROCESSED.tif", from: &args, out: &out) else { return parsed(out) ?? out.done(2) }
        let reversedPath = takeOption("--reversed", from: &args, out: &out)
        let sizeText = takeOption("--cube-size", from: &args, out: &out) ?? "33"
        let modesText = takeOption("--modes", from: &args, out: &out) ?? "rec709-2.4"
        let outDir = takeOption("--out", from: &args, out: &out) ?? "."
        let gamutText = takeOption("--gamut", from: &args, out: &out) ?? "clip"
        rejectExtras(args, out: &out)
        if let u = parsed(out) { return u }

        guard let size = Int(sizeText), size == 33 || size == 65 else {
            return usageError("--cube-size must be 33 or 65 (got '\(sizeText)')")
        }
        guard let modes = parseModes(modesText) else {
            return usageError("unknown mode in '\(modesText)' (use anchor, rec709-2.4, rec709-2.2)")
        }
        guard gamutText == "clip" || gamutText == "compress" else {
            return usageError("--gamut must be clip or compress (got '\(gamutText)')")
        }
        let gamut: (handler: Bake.GamutHandler, label: String) = gamutText == "clip"
            ? (Bake.hardClip, "hard clip in linear Rec 709")
            : (Bake.gamutCompress(), softGamutLabel())

        let processURL = URL(fileURLWithPath: path)
        guard let forward = (try? Tiff.read(contentsOf: processURL)) else {
            return failure("could not read '\(path)' (is it a TIFF?)")
        }
        var reversedImage: RGBImage?
        if let reversedPath {
            guard let image = (try? Tiff.read(contentsOf: URL(fileURLWithPath: reversedPath))) else {
                return failure("could not read reversed Hald '\(reversedPath)' (is it a TIFF?)")
            }
            reversedImage = image
        }

        let report = Validate.report(forward: forward, reversed: reversedImage)
        guard report.ok else {
            if json {
                return Result(code: 3, stdout: jsonString(["command": "build", "ok": false, "report": reportJSON(report)]) + "\n", stderr: "")
            }
            out.add(report.description)
            return out.done(3)
        }

        guard let look = (try? ProcessedHald.read(forward)) else {
            return failure("could not reconstruct the look LUT from '\(path)'")
        }

        var warnings: [String] = []
        if case .spatialOperator = report.locality { warnings.append(report.locality.description) }
        if case .suspect = report.grossFilters { warnings.append(report.grossFilters.description) }

        let lookName = processURL.deletingPathExtension().lastPathComponent
        let spaceLabelFor = { (mode: Bake.Mode) in Bake.space(mode).label }
        var files: [[String: Any]] = []

        if !json {
            out.add(report.description)
            for w in warnings { out.add("warning: \(w)") }
        }

        for mode in modes {
            let baked = Bake.bakeWithReport(look, mode: mode, size: size, gamut: gamut.handler)
            let tally = baked.tally
            let title = "\(lookName) — \(mode.label)"
            let cube = CubeIO.write(baked.lut, title: title, comments: [
                "Trellis \(Trellis.version)",
                "source: \(processURL.lastPathComponent)",
                "input:  \(spaceLabelFor(mode)) code values",
                "output: \(spaceLabelFor(mode)) code values",
                "gamut: \(gamutUpdateFor(mode, gamut.label, tally, gridPoints: size * size * size))",
                "date:  \(dateString())",
            ])
            try? FileManager.default.createDirectory(at: URL(fileURLWithPath: outDir, isDirectory: true), withIntermediateDirectories: true)
            let filename = "\(lookName)_\(mode.fileSuffix)_\(size).cube"
            let url = URL(fileURLWithPath: outDir, isDirectory: true).appendingPathComponent(filename)
            do {
                try Data(cube.utf8).write(to: url)
            } catch {
                return failure("could not write '\(url.path)': \(error)")
            }
            files.append(["mode": mode.fileSuffix, "size": size, "title": title, "path": url.path,
                          "gamut": gamutText, "compressed": tally.compressed, "clipped": tally.clipped])
            if !json {
                out.add("Wrote \(url.path)  (\(size)³, \(mode.label))")
                if tally.compressed > 0 || tally.clipped > 0 {
                    out.add("  gamut: \(tally.compressed) compressed, \(tally.clipped) clipped"
                        + " of \(size * size * size) grid points")
                }
            }
        }

        if json {
            let string = jsonString([
                "command": "build",
                "ok": true,
                "look": lookName,
                "report": reportJSON(report),
                "warnings": warnings,
                "files": files,
            ])
            return Result(code: 0, stdout: string + "\n", stderr: "")
        }
        return out.done(0)
    }

    private static func validate(_ args: [String], json: Bool) -> Result {
        var args = args
        var out = Out()
        guard let path = takePositional("PROCESSED.tif", from: &args, out: &out) else { return parsed(out) ?? out.done(2) }
        let reversedPath = takeOption("--reversed", from: &args, out: &out)
        let identityMode = takeFlag("--identity", from: &args)
        rejectExtras(args, out: &out)
        if let u = parsed(out) { return u }

        guard let forward = (try? Tiff.read(contentsOf: URL(fileURLWithPath: path))) else {
            return failure("could not read '\(path)' (is it a TIFF?)")
        }
        var reversedImage: RGBImage?
        if let reversedPath {
            guard let image = (try? Tiff.read(contentsOf: URL(fileURLWithPath: reversedPath))) else {
                return failure("could not read reversed Hald '\(reversedPath)' (is it a TIFF?)")
            }
            reversedImage = image
        }
        let report = Validate.report(forward: forward, reversed: reversedImage)

        var identity: Validate.IdentityResult?
        if identityMode {
            do {
                identity = try Validate.identity(forward)
            } catch {
                if json {
                    return Result(code: 3, stdout: jsonString(["command": "validate", "ok": false,
                                                         "error": "\(error)"]) + "\n", stderr: "")
                }
                return Result(code: 3, stdout: "", stderr: "trellis: \(error)\n")
            }
        }

        if json {
            var object: [String: Any] = ["command": "validate", "ok": report.ok, "report": reportJSON(report)]
            if let identity { object["identity"] = identityJSON(identity) }
            return Result(code: exitCode(report: report, identity: identity, identityMode: identityMode),
                          stdout: jsonString(object) + "\n", stderr: "")
        }
        out.add(report.description)
        if let identity { out.add(identity.description) }
        return out.done(exitCode(report: report, identity: identity, identityMode: identityMode))
    }

private static func exitCode(report: Validate.Report, identity: Validate.IdentityResult?,
                                  identityMode: Bool) -> Int32 {
        guard report.ok else { return 3 }
        if identityMode, let identity, !identity.pass { return 4 }
        return 0
    }

    /// The standalone recipe check: proves a no-adjustments export of the
    /// identity Hald comes back untouched. Not part of daily baking.
    private static func verifyRecipe(_ args: [String], json: Bool) -> Result {
        var args = args
        var out = Out()
        guard let path = takePositional("PROCESSED.tif", from: &args, out: &out) else { return parsed(out) ?? out.done(2) }
        rejectExtras(args, out: &out)
        if let u = parsed(out) { return u }

        guard let forward = (try? Tiff.read(contentsOf: URL(fileURLWithPath: path))) else {
            return failure("could not read '\(path)' (is it a TIFF?)")
        }
        let identity: Validate.IdentityResult
        do {
            identity = try Validate.identity(forward)
        } catch {
            return Result(code: 3, stdout: json ? jsonString(["command": "verify-recipe", "ok": false,
                                                              "error": "\(error)"]) + "\n" : "",
                          stderr: json ? "" : "trellis: \(error)\n")
        }
        if json {
            let object: [String: Any] = [
                "command": "verify-recipe",
                "ok": identity.pass,
                "pass": identity.pass,
                "max_code_delta": identity.maxCodeDelta,
                "tolerance": identity.tolerance,
                "mean_dE2000": identity.meanDeltaE,
                "max_dE2000": identity.maxDeltaE,
            ]
            return Result(code: identity.pass ? 0 : 4, stdout: jsonString(object) + "\n", stderr: "")
        }
        if identity.pass {
            out.add(String(format: "recipe: PASS — max code shift %.4f (tolerance %.4f) · "
                           + "ΔE2000 mean %.3f, max %.3f",
                           identity.maxCodeDelta, identity.tolerance,
                           identity.meanDeltaE, identity.maxDeltaE))
            out.add("The no-adjustments export came back untouched; this recipe is clean.")
        } else {
            out.add(String(format: "recipe: FAIL — max code shift %.4f (tolerance %.4f)",
                           identity.maxCodeDelta, identity.tolerance))
            out.add("The recipe moved the image. Check: film curve on Auto, input profile not "
                    + "From File, a style applied, or sharpening/NR/clarity still active.")
        }
        return out.done(identity.pass ? 0 : 4)
    }

    private static func inspect(_ args: [String]) -> Result {
        var args = args
        var out = Out()
        guard let path = takePositional("FILE.tif", from: &args, out: &out) else { return parsed(out) ?? out.done(2) }
        rejectExtras(args, out: &out)
        if let u = parsed(out) { return u }
        do {
            let data = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
            out.add(path)
            out.add("\(try Tiff.inspect(data))")
            do {
                let image = try Tiff.decode(data)
                let level = HaldSpec(width: image.width, height: image.height).map { "Hald level \($0.level)" } ?? "not Hald-shaped"
                out.add("decodable         yes (\(level))")
            } catch {
                out.add("decodable         NO: \(error)")
            }
        } catch {
            return failure("\(error)")
        }
        return out.done(0)
    }

    private static func help(json: Bool) -> Result {
        let text = """
        trellis \(Trellis.version)

        Move a Capture One look into 3D LUTs (.cube).

        Usage:
          trellis version [--json]
              Print the version
          trellis spaces [--json]
              Print the colour spaces and matrices Trellis uses
          trellis hald [--level 8|12] [--out DIR] [--with-validation] [--with-reversed] [--json]
              Write an identity Hald (16-bit TIFF, Adobe RGB (1998))
          trellis build PROCESSED.tif [--reversed REVERSED.tif] [--cube-size 33|65]
                      [--modes anchor,rec709-2.4,rec709-2.2] [--gamut clip|compress]
                      [--out DIR] [--json]
              Validate the processed Hald, reconstruct the look, and write one
              .cube per mode (default rec709-2.4, size 33) as <look>_<mode>_<size>.cube;
              --gamut compress uses soft gamut compression (default clip)
          trellis validate PROCESSED.tif [--reversed REVERSED.tif] [--identity] [--json]
              Report profile, bit depth, dimensions, local edits and
              (with --reversed) locality; --identity reports ΔE
          trellis verify-recipe PROCESSED.tif [--json]
              Standalone recipe check: an export of identity-hald-L8.tif
              processed with NO adjustments must come back untouched
              (exit 0 clean / 4 altered / 3 not a usable Hald)
          trellis inspect FILE.tif
              Describe a TIFF's layout and profile

        Exit codes:
          0  success         2  usage error     4  identity test failed
          1  runtime error   3  validation failed
        """
        if json {
            return Result(code: 0, stdout: jsonString(["command": "help",
                                                 "usage": text.trimmingCharacters(in: .whitespacesAndNewlines)]) + "\n", stderr: "")
        }
        return Result(code: 0, stdout: text + "\n", stderr: "")
    }

    // MARK: - Shared pieces

    private static func parseModes(_ text: String) -> [Bake.Mode]? {
        var modes: [Bake.Mode] = []
        for token in text.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch token {
            case "anchor": modes.append(.anchor)
            case "rec709-2.4": modes.append(.rec709_2_4)
            case "rec709-2.2": modes.append(.rec709_2_2)
            default: return nil
            }
        }
        return modes.isEmpty ? nil : modes
    }

    private static func reportJSON(_ r: Validate.Report) -> [String: Any] {
        var locality: [String: Any] = ["status": "unverified"]
        switch r.locality {
        case .clean(let max, let mean):
            locality = ["status": "clean", "max_codes": max, "mean_codes": mean]
        case .spatialOperator(let max, let mean):
            locality = ["status": "spatial_operator", "max_codes": max, "mean_codes": mean]
        case .unverified:
            break
        }
        var gross: [String: Any] = ["status": "not_available"]
        switch r.grossFilters {
        case .clean(let rms, let max):
            gross = ["status": "clean", "rms": rms, "max": max]
        case .suspect(let rms, let max):
            gross = ["status": "suspect", "rms": rms, "max": max]
        case .notAvailable:
            break
        }
        return [
            "ok": r.ok,
            "hald_level": jnull(r.haldLevel),
            "dimensions": jnull(r.dimensions),
            "profile": jnull(r.profile),
            "bit_depth": jnull(r.bitDepth),
            "locality": locality,
            "gross_filters": gross,
        ]
    }

    private static func identityJSON(_ id: Validate.IdentityResult) -> [String: Any] {
        [
            "pass": id.pass,
            "max_code_delta": id.maxCodeDelta,
            "tolerance": id.tolerance,
            "mean_dE2000": id.meanDeltaE,
            "max_dE2000": id.maxDeltaE,
        ]
    }

    private static func dateString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    /// `--gamut compress`'s .cube header line: what ran and with which
    /// calculated (never tuned) limits.
    private static func softGamutLabel() -> String {
        let l = Bake.adobeToRec709Limits
        return String(format: "soft compression toward white (threshold 1.0, "
                      + "calculated limits [%.4f, %.4f, %.4f]) + hard-clip safety net",
                      l.x, l.y, l.z)
    }

    /// The `.cube` header's gamut line: the handling that ran, plus the tally
    /// (how many grid points it compressed or clipped) when anything moved.
    private static func gamutUpdateFor(_ mode: Bake.Mode, _ label: String,
                                       _ tally: Bake.BakeTally, gridPoints: Int) -> String {
        if mode == .anchor { return "n/a (anchor mode: look LUT only)" }
        if tally.compressed > 0 || tally.clipped > 0 {
            return "\(label) — \(tally.compressed) compressed, \(tally.clipped) clipped of \(gridPoints) points"
        }
        return label
    }
}