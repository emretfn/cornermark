import CornermarkL10n
import Foundation

// Checks the interface translations against the code.
//   swift run L10nCheck           verify only; exits 1 on any problem
//   swift run L10nCheck --write   rewrite Localization/en.json from the code and regenerate the embedded catalogs, then verify

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let localizationDir = root.appendingPathComponent("Localization")
let generatedDir = root.appendingPathComponent("Sources/CornermarkL10n/Catalogs")
let scannedTargets = ["Cornermark", "CornermarkCapture", "CornermarkCore", "CornermarkDesign", "CornermarkEditor", "CornermarkShell", "CornermarkVideoEditor"]
let write = CommandLine.arguments.contains("--write")

var problems: [String] = []
func problem(_ s: String) { problems.append(s) }

// MARK: Source strings

enum Source: Equatable {
    case text
    case plural(one: String)
}

struct Found {
    var entries: [String: Source] = [:]
    var sites: [String: String] = [:]
}

func unescape(_ literal: String, at site: String) -> String? {
    if literal.contains("\\(") {
        problem("\(site): interpolation inside a translated literal; use a {name} placeholder")
        return nil
    }
    var out = ""
    var it = literal.makeIterator()
    while let c = it.next() {
        guard c == "\\" else { out.append(c); continue }
        guard let e = it.next() else { break }
        switch e {
        case "n": out.append("\n")
        case "t": out.append("\t")
        case "0": out.append("\0")
        case "u":
            _ = it.next()
            var hex = ""
            while let h = it.next(), h != "}" { hex.append(h) }
            guard let v = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(v) else {
                problem("\(site): bad unicode escape \\u{\(hex)}")
                return nil
            }
            out.unicodeScalars.append(scalar)
        default: out.append(e)
        }
    }
    return out
}

let lit = #""((?:[^"\\\n]|\\.)*)""#
let anyCall = try! NSRegularExpression(pattern: #"\b(tr|trKey|trPlural)\("#)
let textCall = try! NSRegularExpression(pattern: #"\b(?:tr|trKey)\(\s*"# + lit)
let pluralCall = try! NSRegularExpression(pattern: #"\btrPlural\(\s*one:\s*"# + lit + #"\s*,\s*other:\s*"# + lit)

func scan() -> Found {
    var found = Found()
    let fm = FileManager.default
    for target in scannedTargets {
        let dir = root.appendingPathComponent("Sources/\(target)")
        guard let files = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
        for case let file as URL in files where file.pathExtension == "swift" {
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            for (n, line) in text.components(separatedBy: "\n").enumerated() {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                let site = "\(file.path.replacingOccurrences(of: root.path + "/", with: "")):\(n + 1)"
                let ns = line as NSString
                let range = NSRange(location: 0, length: ns.length)
                let calls = anyCall.numberOfMatches(in: line, range: range)
                var matched = 0
                func record(_ key: String, _ source: Source) {
                    if let prior = found.entries[key], prior != source {
                        problem("\(site): \"\(key)\" is used as both \(prior) and \(source) (first at \(found.sites[key]!))")
                    }
                    found.entries[key] = source
                    found.sites[key] = found.sites[key] ?? site
                }
                for m in textCall.matches(in: line, range: range) {
                    matched += 1
                    if let key = unescape(ns.substring(with: m.range(at: 1)), at: site) { record(key, .text) }
                }
                for m in pluralCall.matches(in: line, range: range) {
                    matched += 1
                    if let one = unescape(ns.substring(with: m.range(at: 1)), at: site),
                       let other = unescape(ns.substring(with: m.range(at: 2)), at: site) { record(other, .plural(one: one)) }
                }
                if matched != calls {
                    problem("\(site): a tr, trKey or trPlural call whose English is not a one-line string literal")
                }
            }
        }
    }
    return found
}

// MARK: Catalog files

let placeholder = try! NSRegularExpression(pattern: #"\{([A-Za-z][A-Za-z0-9_]*)\}"#)
func placeholders(_ s: String) -> [String] {
    placeholder.matches(in: s, range: NSRange(location: 0, length: (s as NSString).length)).map { (s as NSString).substring(with: $0.range(at: 1)) }.sorted()
}

func jsonData(_ object: Any) -> Data {
    var data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    data.append(0x0A)
    return data
}

func englishCatalog(_ found: Found) -> [String: Any] {
    var out: [String: Any] = [:]
    for (key, source) in found.entries {
        switch source {
        case .text: out[key] = key
        case .plural(let one): out[key] = ["one": one, "other": key]
        }
    }
    return out
}

func loadJSON(_ url: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

func check(_ language: Language, _ found: Found) -> [String: Any]? {
    let url = localizationDir.appendingPathComponent("\(language.rawValue).json")
    guard let dict = loadJSON(url) else {
        problem("\(language.rawValue): Localization/\(language.rawValue).json missing or not a JSON object")
        return nil
    }
    let required = language.requiredPluralCategories
    var missing = 0
    for (key, source) in found.entries.sorted(by: { $0.key < $1.key }) {
        guard let value = dict[key] else { missing += 1; problem("\(language.rawValue): missing \"\(key)\""); continue }
        let expected = placeholders(key)
        switch source {
        case .text:
            guard let s = value as? String else { problem("\(language.rawValue): \"\(key)\" must be a string"); continue }
            if s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { problem("\(language.rawValue): \"\(key)\" is empty") }
            if placeholders(s) != expected {
                problem("\(language.rawValue): \"\(key)\" has placeholders \(placeholders(s)), English has \(expected)")
            }
        case .plural:
            guard let forms = value as? [String: String] else { problem("\(language.rawValue): \"\(key)\" must be an object of plural forms"); continue }
            let given = Set(forms.keys.compactMap(PluralCategory.init(rawValue:)))
            if given.count != forms.count { problem("\(language.rawValue): \"\(key)\" has a key that is not a plural category") }
            if given != required {
                problem("\(language.rawValue): \"\(key)\" has forms \(given.map(\.rawValue).sorted()), needs \(required.map(\.rawValue).sorted())")
            }
            // A form may leave the number out ("one day"), but must not invent or drop any other placeholder.
            let others = expected.filter { $0 != "count" }
            for (category, s) in forms {
                let got = placeholders(s)
                if got.filter({ $0 != "count" }) != others || got.filter({ $0 == "count" }).count > 1 {
                    problem("\(language.rawValue): \"\(key)\" [\(category)] has placeholders \(got), English has \(expected)")
                }
                if s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { problem("\(language.rawValue): \"\(key)\" [\(category)] is empty") }
            }
            if given.contains(.other), let other = forms["other"], !placeholders(other).contains("count"), expected.contains("count") {
                problem("\(language.rawValue): \"\(key)\" [other] must show {count}")
            }
        }
    }
    for key in dict.keys where found.entries[key] == nil { problem("\(language.rawValue): stale key \"\(key)\" no longer in the code") }
    if missing > 0 { problem("\(language.rawValue): \(missing) missing") }
    return dict
}

// MARK: Generated Swift

func identifier(_ language: Language) -> String { "`" + language.rawValue.replacingOccurrences(of: "-", with: "_") + "`" }
let header = "// Generated by `swift run L10nCheck --write` from Localization/. Do not edit.\n"

func generated(_ catalogs: [(Language, [String: Any])]) -> [String: String] {
    var files: [String: String] = [:]
    var index = header + "\nenum Catalogs {\n    static let json: [String: String] = [\n"
    for (language, dict) in catalogs {
        let json = String(decoding: jsonData(dict), as: UTF8.self)
        if json.contains("\"\"\"#") { problem("\(language.rawValue): catalog contains a raw string terminator") }
        files["\(language.rawValue).swift"] = header + "\nextension Catalogs {\n    static let \(identifier(language)) = #\"\"\"\n\(json)\"\"\"#\n}\n"
        index += "        \"\(language.rawValue)\": \(identifier(language)),\n"
    }
    index += "    ]\n}\n"
    files["Catalogs.swift"] = index
    return files
}

// MARK: Run

let found = scan()
let english = englishCatalog(found)
let enURL = localizationDir.appendingPathComponent("en.json")
if write {
    try! FileManager.default.createDirectory(at: localizationDir, withIntermediateDirectories: true)
    try! jsonData(english).write(to: enURL)
} else if (try? Data(contentsOf: enURL)) != jsonData(english) {
    problem("Localization/en.json is out of date with the code; run swift run L10nCheck --write")
}

let onDisk = Set(((try? FileManager.default.contentsOfDirectory(atPath: localizationDir.path)) ?? []).filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) })
for name in onDisk where Language(rawValue: name) == nil { problem("Localization/\(name).json is not a supported language") }

var catalogs: [(Language, [String: Any])] = []
for language in Language.allCases where language != .en {
    if let dict = check(language, found) { catalogs.append((language, dict)) }
}

let expectedFiles = generated(catalogs)
let existing = Set(((try? FileManager.default.contentsOfDirectory(atPath: generatedDir.path)) ?? []).filter { $0.hasSuffix(".swift") })
if write {
    try! FileManager.default.createDirectory(at: generatedDir, withIntermediateDirectories: true)
    for stale in existing.subtracting(expectedFiles.keys) { try? FileManager.default.removeItem(at: generatedDir.appendingPathComponent(stale)) }
    for (name, contents) in expectedFiles { try! contents.write(to: generatedDir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
} else {
    for (name, contents) in expectedFiles where (try? String(contentsOf: generatedDir.appendingPathComponent(name), encoding: .utf8)) != contents {
        problem("Sources/CornermarkL10n/Catalogs/\(name) is out of date; run swift run L10nCheck --write")
    }
    for stale in existing.subtracting(expectedFiles.keys) { problem("Sources/CornermarkL10n/Catalogs/\(stale) has no catalog") }
}

let plurals = found.entries.values.filter { if case .plural = $0 { return true } else { return false } }.count
print("\(found.entries.count) strings (\(plurals) plural) in the code, \(catalogs.count) of \(Language.allCases.count - 1) translations present")
for p in problems.prefix(200) { print("FAIL \(p)") }
if problems.count > 200 { print("... and \(problems.count - 200) more") }
print(problems.isEmpty ? "RESULT ok" : "RESULT \(problems.count) problems")
exit(problems.isEmpty ? 0 : 1)
