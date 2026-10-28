import Foundation
import PilotCore

/// What `pilot convert` reaches (CLI W13): Convert's tools, its one job and the progress tip it runs under, as the
/// Files page, Finder's service and the menu's Convert to… reach them. The tests hand in their own, so nothing converts,
/// shows or reads Homebrew.
@MainActor
final class ControlConvert {
    var converter: @MainActor () -> Converter = { .installed() }
    /// Starts the job under the progress tip and answers its run; nil when every file is already in the format.
    var start: @MainActor ([URL], ConvertFormat, Converter) -> Task<ConvertBatch.Outcome, Never>? = { ConvertFiles.start($0, to: $1, with: $2) }
    /// The running job's progress line, nil when none runs.
    var running: @MainActor () -> String? = { ConvertFiles.job == nil ? nil : ConvertFiles.progressText }
    /// The progress tip's Cancel.
    var cancel: @MainActor () -> Void = { ConvertFiles.job?.cancel() }
    var isFolder: (URL) -> Bool? = { url in
        var folder: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &folder) ? folder.boolValue : nil
    }
}

extension ControlVerbs {
    /// `convert`: Tools › Files and Convert to…, one job at a time under the same progress tip with Cancel. The output
    /// lands beside each original under a free name and never replaces a file, so it asks no Allow.
    func registerConvert(_ convert: ControlConvert) {
        let formats = ConvertFormat.allCases.map(\.rawValue)
        register(ControlVerb("convert", help: "Converts files as Tools › Files does: the formats they share, the conversion and its result, the catalogue and its tools.",
                             usage: "pilot convert <file…> [--to <format>] | convert --formats | convert --cancel | convert",
                             flags: [.init("to", help: "the format to convert to (\(formats.joined(separator: ", "))); without it, the formats the files share"),
                                     .init("formats", help: "what Convert reads, the formats each kind can become, and whether ffmpeg and webp are installed", takesValue: false),
                                     .init("cancel", help: "stops the running conversion after the file in hand, keeping the ones finished, as the tip's Cancel does", takesValue: false)],
                             schema: { .object(["formats": .array(formats.map(JSONValue.string))]) },
                             index: { .object(["formats": .array(formats.map(JSONValue.string))]) },
                             detail: { word in
                                 guard let format = Self.format(word) else { return nil }
                                 let kinds = Convert.catalogue.filter { $0.to.contains(format) }.map(\.kind)
                                 return "\(format.title): from \(kinds.joined(separator: ", "))" + (format.tool.map { "; needs \($0.formula) from Homebrew" } ?? "")
                             }) { call throws(ControlError) in
            let args = call.arguments()
            if args.has("formats") || args.has("cancel") {
                guard args.positional.isEmpty else { throw ControlError(.badRequest, "--\(args.has("formats") ? "formats" : "cancel") takes no files") }
                return args.has("formats") ? Self.catalogue(convert.converter()) : Self.cancel(convert)
            }
            guard !args.positional.isEmpty else {
                // The job's progress, as the tip shows it.
                let progress = convert.running()
                return .object(["running": .bool(progress != nil), "progress": progress.map(JSONValue.string) ?? .null])
            }
            let urls = try args.positional.map { path throws(ControlError) in try Self.file(path, cwd: call.cwd, isFolder: convert.isFolder) }
            let converter = convert.converter()
            let options = converter.options(for: urls)
            guard !options.isEmpty else {
                throw ControlError(.badValue, urls.count == 1 ? "Pilot cannot convert \(urls[0].lastPathComponent)" : "these files have no format in common to convert to")
            }
            guard args.has("to") else {
                return .object(["files": .array(urls.map { .string($0.path) }), "formats": .array(options.map(Self.option))])
            }
            let asked = try args.required("to")
            guard let format = Self.format(asked) else { throw ControlError(.badValue, "no format \(asked); formats: \(formats.joined(separator: ", "))") }
            guard let option = options.first(where: { $0.format == format }) else {
                throw ControlError(.badValue, "these files cannot become \(format.title); they can become \(options.map(\.format.rawValue).joined(separator: ", "))")
            }
            if let tool = option.needs {
                throw ControlError(.notReady, "\(format.title) needs \(tool.formula) from Homebrew; pilot add packages --package \(tool.package?.key ?? tool.formula) installs it after Allow")
            }
            if let progress = convert.running() { throw ControlError(.taken, "a conversion is running (\(progress)); pilot convert --cancel stops it") }
            let batch = ConvertBatch(urls, to: format)
            let outcome = await convert.start(urls, format, converter)?.value ?? ConvertBatch.Outcome()
            return .object(["format": .string(format.rawValue),
                            "written": .array(outcome.written.map { .string($0.path) }),
                            "failed": .array(outcome.failed.map { .object(["file": .string($0.0.path), "error": .string($0.1)]) }),
                            "skipped": .array(batch.skipped.map { .string($0.path) }),
                            "cancelled": .bool(outcome.cancelled),
                            "summary": .string(batch.summary(outcome))])
        })
    }

    /// A format by its name or title, `jpeg` and `htm` too.
    private static func format(_ name: String) -> ConvertFormat? {
        let name = name.lowercased()
        return ConvertFormat(rawValue: ["jpeg": "jpg", "htm": "html"][name] ?? name)
    }

    /// A path from the caller's folder, `~` expanded, that must be a file.
    private static func file(_ path: String, cwd: String?, isFolder: (URL) -> Bool?) throws(ControlError) -> URL {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, relativeTo: cwd.map { URL(fileURLWithPath: $0, isDirectory: true) })
            .standardizedFileURL
        switch isFolder(url) {
        case nil: throw ControlError(.badValue, "no file at \(url.path)")
        case true?: throw ControlError(.badValue, "\(url.path) is a folder; Convert takes files")
        case false?: return url
        }
    }

    private static func option(_ option: ConvertOption) -> JSONValue {
        .object(["format": .string(option.format.rawValue), "title": .string(option.format.title),
                 "needs": option.needs.map { .string($0.formula) } ?? .null])
    }

    /// The Files page's catalogue and its tools, installed or not.
    private static func catalogue(_ converter: Converter) -> JSONValue {
        .object([
            "kinds": .array(Convert.catalogue.map { .object(["kind": .string($0.kind), "reads": .string($0.reads), "to": .array($0.to.map { .string($0.rawValue) })]) }),
            "tools": .array(ConvertTool.allCases.map { tool in
                .object(["tool": .string(tool.formula), "writes": .string(ConvertPage.needs(tool)), "installed": .bool(converter.tools[tool] != nil),
                         "install": .string("pilot add packages --package \(tool.package?.key ?? tool.formula)")])
            }),
        ])
    }

    private static func cancel(_ convert: ControlConvert) -> JSONValue {
        guard let progress = convert.running() else { return .object(["cancelled": .bool(false), "note": .string("no conversion is running")]) }
        convert.cancel()
        return .object(["cancelled": .bool(true), "progress": .string(progress),
                        "note": .string("the file in hand stops; the ones finished are kept")])
    }
}
