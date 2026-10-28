import Foundation
import AtlasCore

// MARK: - Process timings

let processStart = Date()

// MARK: - Tiny argument parser

struct ParsedArguments {
    var libraryPath: String = LibraryPaths.defaultRoot.path
    var json: Bool = false
    var command: String = ""
    var positionals: [String] = []
    var options: [String: String] = [:]
    var switches: Set<String> = []
}

enum CLIError: Error, CustomStringConvertible {
    case usage(String)

    var description: String {
        switch self {
        case .usage(let message): return message
        }
    }
}

let globalSwitches: Set<String> = ["json", "help", "version"]

func parseArguments(_ raw: [String]) throws -> ParsedArguments {
    var parsed = ParsedArguments()
    var index = 1 // skip executable path

    while index < raw.count {
        let token = raw[index]

        if token == "-h" {
            parsed.switches.insert("help")
            index += 1
            continue
        }
        if token == "-v" {
            parsed.switches.insert("version")
            index += 1
            continue
        }

        if token.hasPrefix("--") {
            let body = String(token.dropFirst(2))
            var name = body
            var inlineValue: String?
            if let equals = body.firstIndex(of: "=") {
                name = String(body[body.startIndex..<equals])
                inlineValue = String(body[body.index(after: equals)...])
            }

            if let inlineValue {
                parsed.options[name] = inlineValue
                index += 1
                continue
            }

            let isKnownSwitch = globalSwitches.contains(name)
            if !isKnownSwitch, index + 1 < raw.count, !raw[index + 1].hasPrefix("--") {
                // Value option belonging to the command (e.g. --mode copy).
                parsed.options[name] = raw[index + 1]
                index += 2
            } else {
                parsed.switches.insert(name)
                index += 1
            }
            continue
        }

        if parsed.command.isEmpty {
            parsed.command = token
        } else {
            parsed.positionals.append(token)
        }
        index += 1
    }

    if let library = parsed.options["library"], !library.isEmpty {
        parsed.libraryPath = (library as NSString).expandingTildeInPath
    }
    // `library` is global, not command-specific.
    parsed.options.removeValue(forKey: "library")
    parsed.json = parsed.switches.contains("json") || parsed.options["json"] != nil
    return parsed
}

// MARK: - Formatting helpers

func formatBytes(_ bytes: Int64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var value = Double(bytes)
    var unit = 0
    while value >= 1024, unit < units.count - 1 {
        value /= 1024
        unit += 1
    }
    if unit == 0 { return "\(bytes) B" }
    return String(format: "%.1f %@", value, units[unit])
}

func formatMilliseconds(_ value: Double) -> String {
    String(format: "%.2f ms", value)
}

func pad(_ string: String, _ width: Int) -> String {
    string.count >= width ? string : string + String(repeating: " ", count: width - string.count)
}

func padLeft(_ string: String, _ width: Int) -> String {
    string.count >= width ? string : String(repeating: " ", count: width - string.count) + string
}

func makeJSONEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
}

func printJSON<T: Encodable>(_ value: T) throws {
    let data = try makeJSONEncoder().encode(value)
    if let string = String(data: data, encoding: .utf8) {
        print(string)
    }
}

// MARK: - Commands

let usageText = """
atlasoss — AtlasOSS library CLI (P0)

USAGE
  atlasoss [--library <path>] [--json] <command> [options]

GLOBAL
  --library <path>     Library folder (default: \(LibraryPaths.defaultRoot.path))
  --json               Machine-readable JSON output
  -h, --help           Show this help
  -v, --version        Print version

COMMANDS
  init                 Create (or open) the library package
  import <folder>      Import a folder
                         --mode copy|connected   (default: connected)
                         --collection <name>     (default: folder name)
  list                 List indexed items
                         --limit <n> --mode <mode> --collection <name>
  collections          List collections
  info                 Show library statistics
  bench                Measure cold-open TTFI (open library -> first item)
                         --iterations <n>        (default: 5)

MODES
  connected   Index files where they live. Writes 0 bytes into originals/.
  copy        Copy into originals/, deduped by SHA-256 content hash.

EXIT CODES
  0 success   1 runtime error   2 usage error
"""

func requireOption(_ parsed: ParsedArguments, _ key: String) throws -> String {
    guard let value = parsed.options[key], !value.isEmpty else {
        throw CLIError.usage("missing required option --\(key)")
    }
    return value
}

func openLibrary(_ parsed: ParsedArguments) throws -> AtlasLibrary {
    try AtlasLibrary(paths: LibraryPaths(path: parsed.libraryPath))
}

func runInit(_ parsed: ParsedArguments) throws {
    let library = try openLibrary(parsed)
    let info = try library.info()
    if parsed.json {
        try printJSON(info)
    } else {
        print("Library ready: \(info.rootPath)")
        print("  database   \(info.databasePath)")
        print("  schema     v\(info.schemaVersion)")
        print("  items      \(info.itemCount)")
        print("  collections \(info.collectionCount)")
    }
}

func runImport(_ parsed: ParsedArguments) throws {
    guard let folder = parsed.positionals.first else {
        throw CLIError.usage("import requires a folder path")
    }

    let modeName = parsed.options["mode"] ?? ImportMode.connected.rawValue
    guard let mode = ImportMode(rawValue: modeName.lowercased()) else {
        throw CLIError.usage("invalid --mode '\(modeName)' (expected: copy | connected)")
    }

    let library = try openLibrary(parsed)
    let report = try library.importFolder(
        path: folder,
        mode: mode,
        collectionName: parsed.options["collection"]
    )

    if parsed.json {
        try printJSON(report)
    } else {
        print("Imported \(report.folder)")
        print("  \(pad("mode", 18))\(report.mode.rawValue)")
        print("  \(pad("collection", 18))\(report.collectionName)")
        print("  \(pad("scanned", 18))\(report.scanned)")
        print("  \(pad("imported", 18))\(report.imported)")
        print("  \(pad("updated", 18))\(report.updated)")
        print("  \(pad("duplicates", 18))\(report.duplicates)")
        print("  \(pad("skipped", 18))\(report.skipped)")
        print("  \(pad("copied originals", 18))\(report.copiedOriginals)")
        print("  \(pad("bytes hashed", 18))\(report.bytesHashed)")
        print("  \(pad("duration", 18))\(formatMilliseconds(report.durationSeconds * 1000))")
        for error in report.errors {
            print("  ! \(error)")
        }
    }
}

func runList(_ parsed: ParsedArguments) throws {
    let library = try openLibrary(parsed)

    var limit: Int?
    if let rawLimit = parsed.options["limit"] {
        guard let parsedLimit = Int(rawLimit), parsedLimit >= 0 else {
            throw CLIError.usage("invalid --limit '\(rawLimit)'")
        }
        limit = parsedLimit
    }

    var mode: ImportMode?
    if let rawMode = parsed.options["mode"] {
        guard let parsedMode = ImportMode(rawValue: rawMode.lowercased()) else {
            throw CLIError.usage("invalid --mode '\(rawMode)' (expected: copy | connected)")
        }
        mode = parsedMode
    }

    let items = try library.items(limit: limit, mode: mode, collectionName: parsed.options["collection"])

    if parsed.json {
        try printJSON(items)
        return
    }

    if items.isEmpty {
        print("No items. Try: atlasoss import <folder> --mode connected")
        return
    }

    print("\(pad("ID", 38))\(pad("KIND", 8))\(pad("MODE", 11))\(padLeft("SIZE", 10))  \(pad("DIMS", 11))NAME")
    print(String(repeating: "-", count: 100))
    for item in items {
        print(
            "\(pad(item.id.uuidString, 38))"
            + "\(pad(item.kind.rawValue, 8))"
            + "\(pad(item.mode.rawValue, 11))"
            + "\(padLeft(formatBytes(item.byteSize), 10))  "
            + "\(pad(item.dimensionsDescription, 11))"
            + item.fileName
        )
    }
    print(String(repeating: "-", count: 100))
    print("\(items.count) item(s)")
}

func runCollections(_ parsed: ParsedArguments) throws {
    let library = try openLibrary(parsed)
    let collections = try library.collections()
    if parsed.json {
        try printJSON(collections)
        return
    }
    if collections.isEmpty {
        print("No collections.")
        return
    }
    print("\(pad("NAME", 32))\(padLeft("ITEMS", 7))  ID")
    print(String(repeating: "-", count: 80))
    for collection in collections {
        print("\(pad(collection.name, 32))\(padLeft(String(collection.itemCount), 7))  \(collection.id.uuidString)")
    }
    print(String(repeating: "-", count: 80))
    print("\(collections.count) collection(s)")
}

func runInfo(_ parsed: ParsedArguments) throws {
    let library = try openLibrary(parsed)
    let info = try library.info()
    if parsed.json {
        try printJSON(info)
        return
    }
    print("Library \(info.rootPath)")
    print("  \(pad("library id", 18))\(info.libraryID)")
    print("  \(pad("schema", 18))v\(info.schemaVersion)")
    print("  \(pad("items", 18))\(info.itemCount)")
    print("  \(pad("collections", 18))\(info.collectionCount)")
    print("  \(pad("connected items", 18))\(info.connectedCount)")
    print("  \(pad("copied items", 18))\(info.copiedCount)")
    print("  \(pad("total bytes", 18))\(formatBytes(info.totalBytes))")
    print("  \(pad("originals files", 18))\(info.originalsFileCount)")
    print("  \(pad("thumbnail files", 18))\(info.thumbnailsFileCount)")
    print("  \(pad("database size", 18))\(formatBytes(info.databaseByteSize))")
    let kinds = info.kindBreakdown.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    print("  \(pad("kinds", 18))\(kinds.isEmpty ? "—" : kinds)")
}

struct BenchResult: Encodable {
    var iterations: Int
    var coldOpenMinMS: Double
    var coldOpenMedianMS: Double
    var coldOpenP95MS: Double
    var coldOpenMaxMS: Double
    var processWallToFirstItemMS: Double
    var itemCount: Int
}

func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let position = fraction * Double(sorted.count - 1)
    let lower = Int(position.rounded(.down))
    let upper = Int(position.rounded(.up))
    if lower == upper { return sorted[lower] }
    let weight = position - Double(lower)
    return sorted[lower] * (1 - weight) + sorted[upper] * weight
}

func runBench(_ parsed: ParsedArguments) throws {
    var iterations = 5
    if let raw = parsed.options["iterations"] {
        guard let value = Int(raw), value > 0 else {
            throw CLIError.usage("invalid --iterations '\(raw)'")
        }
        iterations = value
    }

    // Cold-open = process start -> first item decoded (includes dyld).
    do {
        let warmUp = try openLibrary(parsed) // creates the library if missing
        warmUp.close()
    }

    var samples: [Double] = []
    var firstItemWallMS = 0.0

    for _ in 0..<iterations {
        let begin = Date()
        let library = try openLibrary(parsed)
        _ = try library.items(limit: 1)
        let elapsed = Date().timeIntervalSince(begin) * 1000
        library.close()
        samples.append(elapsed)
        if firstItemWallMS == 0 {
            firstItemWallMS = Date().timeIntervalSince(processStart) * 1000
        }
    }

    let countingLibrary = try openLibrary(parsed)
    let itemCount = try countingLibrary.itemCount()
    countingLibrary.close()

    let sorted = samples.sorted()
    let result = BenchResult(
        iterations: iterations,
        coldOpenMinMS: sorted.first ?? 0,
        coldOpenMedianMS: percentile(sorted, 0.5),
        coldOpenP95MS: percentile(sorted, 0.95),
        coldOpenMaxMS: sorted.last ?? 0,
        processWallToFirstItemMS: firstItemWallMS,
        itemCount: itemCount
    )

    if parsed.json {
        try printJSON(result)
        return
    }
    print("Cold-open TTFI — open library + fetch first item, n=\(result.iterations)")
    print("  \(pad("min", 26))\(formatMilliseconds(result.coldOpenMinMS))")
    print("  \(pad("median", 26))\(formatMilliseconds(result.coldOpenMedianMS))")
    print("  \(pad("p95", 26))\(formatMilliseconds(result.coldOpenP95MS))")
    print("  \(pad("max", 26))\(formatMilliseconds(result.coldOpenMaxMS))")
    print("  \(pad("process -> first item", 26))\(formatMilliseconds(result.processWallToFirstItemMS))")
    print("  \(pad("items in library", 26))\(result.itemCount)")
}

// MARK: - Entry point

func main() -> Int32 {
    let parsed: ParsedArguments
    do {
        parsed = try parseArguments(CommandLine.arguments)
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        return 2
    }

    if parsed.switches.contains("version") {
        print("atlasoss \(AtlasVersion.semantic) (schema v\(AtlasSchema.currentVersion))")
        return 0
    }

    if parsed.switches.contains("help") || parsed.command.isEmpty || parsed.command == "help" {
        print(usageText)
        return parsed.command.isEmpty && !parsed.switches.contains("help") ? 2 : 0
    }

    do {
        switch parsed.command {
        case "init":
            try runInit(parsed)
        case "import":
            try runImport(parsed)
        case "list":
            try runList(parsed)
        case "collections":
            try runCollections(parsed)
        case "info":
            try runInfo(parsed)
        case "bench":
            try runBench(parsed)
        default:
            FileHandle.standardError.write(Data("error: unknown command '\(parsed.command)'\n\n".utf8))
            FileHandle.standardError.write(Data((usageText + "\n").utf8))
            return 2
        }
    } catch let error as CLIError {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        return 2
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        return 1
    }
    return 0
}

exit(main())
