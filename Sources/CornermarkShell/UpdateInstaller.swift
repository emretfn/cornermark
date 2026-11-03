import Darwin
import Foundation
import Security

/// Checks that an unpacked app is the same product as the running one, signed by the same certificate.
enum UpdateVerifier {
    /// The running app's designated requirement. Ad-hoc and unsigned builds have none that a later release could meet.
    static func runningRequirement() throws -> SecRequirement {
        var running: SecCode?
        var code: SecStaticCode?
        var info: CFDictionary?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCopyStaticCode(running, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let flags = ((info as? [String: Any])?[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value,
              flags & SecCodeSignatureFlags.adhoc.rawValue == 0,
              SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement else {
            throw UpdateError.selfNotReleaseSigned
        }
        return requirement
    }

    static func verify(bundle: URL, against requirement: SecRequirement, announced: AppVersion, current: AppVersion?) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError.signatureMismatch
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else { throw UpdateError.signatureMismatch }
        let shipped = (Bundle(url: bundle)?.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init)
        guard let shipped, shipped == announced, let current, shipped > current else { throw UpdateError.versionMismatch }
    }
}

/// Reads the GitHub feed, unpacks a release next to the running app and swaps it in.
final class UpdateInstaller: UpdateServicing {
    static let feed = URL(string: "https://api.github.com/repos/emretfn/cornermark/releases/latest")!

    private let feedURL: URL
    private let bundleURL: URL
    private let session: URLSession

    let currentVersion: AppVersion?

    init(bundleURL: URL = Bundle.main.bundleURL) {
        self.bundleURL = bundleURL
        currentVersion = (Bundle(url: bundleURL)?.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init)
        var feed = Self.feed
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["CORNERMARK_UPDATE_FEED"], let url = URL(string: raw), AppRelease.isTrusted(url) { feed = url }
        #endif
        feedURL = feed
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 900
        config.httpAdditionalHeaders = ["User-Agent": "Cornermark/\(currentVersion?.description ?? "unknown")"]
        session = URLSession(configuration: config)
    }

    func latestRelease() async throws -> AppRelease? {
        var request = URLRequest(url: feedURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await transfer { try await session.data(for: request) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard status == 200 else { throw UpdateError.network("GitHub answered \(status).") }
        return try AppRelease.parse(json: data)
    }

    func stage(_ release: AppRelease) async throws -> StagedUpdate {
        guard let dmgURL = release.dmgURL else { throw UpdateError.noDownload }
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: bundleURL.deletingLastPathComponent().path) else {
            throw UpdateError.cannotReplace(path: bundleURL.path)
        }
        let requirement = try UpdateVerifier.runningRequirement()
        let directory: URL
        do {
            directory = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: bundleURL, create: true)
        } catch {
            throw UpdateError.cannotReplace(path: bundleURL.path)
        }
        do {
            let app = try await unpack(dmgURL, into: directory)
            try UpdateVerifier.verify(bundle: app, against: requirement, announced: release.version, current: currentVersion)
            return StagedUpdate(release: release, directory: directory, app: app)
        } catch {
            try? fm.removeItem(at: directory)
            throw error
        }
    }

    func installAndRelaunch(_ staged: StagedUpdate) throws {
        do { try Self.swap(staged.app, with: bundleURL) } catch {
            Log.shell.error("swap failed: \(error.localizedDescription, privacy: .public)")
            throw UpdateError.cannotReplace(path: bundleURL.path)
        }
        discard(staged)
        let relauncher = Process()
        relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
        relauncher.arguments = ["-c", #"while kill -0 "$1" 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open "$2""#,
                                "sh", String(ProcessInfo.processInfo.processIdentifier), bundleURL.path]
        relauncher.standardOutput = FileHandle.nullDevice
        relauncher.standardError = FileHandle.nullDevice
        do { try relauncher.run() } catch {
            Log.shell.error("relaunch failed: \(error.localizedDescription, privacy: .public)")
            throw UpdateError.relaunchFailed
        }
    }

    func discard(_ staged: StagedUpdate) {
        guard FileManager.default.fileExists(atPath: staged.directory.path) else { return }
        do { try FileManager.default.removeItem(at: staged.directory) } catch {
            Log.shell.error("could not remove \(staged.directory.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Exchanges two paths in one step, so the app is never missing and a failure leaves both untouched.
    static func swap(_ staged: URL, with current: URL) throws {
        guard renamex_np(staged.path, current.path, UInt32(RENAME_SWAP)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    // MARK: Unpacking

    private func unpack(_ dmgURL: URL, into directory: URL) async throws -> URL {
        let fm = FileManager.default
        let dmg = directory.appendingPathComponent(AppRelease.assetName)
        let mount = directory.appendingPathComponent("mnt", isDirectory: true)
        let app = directory.appendingPathComponent("Cornermark.app", isDirectory: true)
        let result: Result<Void, Error>
        do {
            try await download(dmgURL, to: dmg)
            try fm.createDirectory(at: mount, withIntermediateDirectories: true)
            try await run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
            let source = mount.appendingPathComponent("Cornermark.app", isDirectory: true)
            let values = try? source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { throw UpdateError.bundleMissing }
            try await run("/usr/bin/ditto", [source.path, app.path])
            result = .success(())
        } catch {
            result = .failure(error)
        }
        _ = try? await run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
        try? fm.removeItem(at: dmg)
        try result.get()
        return app
    }

    private func download(_ url: URL, to destination: URL) async throws {
        let (file, response) = try await transfer { try await session.download(from: url) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError.network("The download answered \(status).") }
        try FileManager.default.moveItem(at: file, to: destination)
    }

    private func transfer<T>(_ work: () async throws -> T) async throws -> T {
        do { return try await work() } catch let error as URLError { throw UpdateError.network(error.localizedDescription) }
    }

    private func run(_ tool: String, _ arguments: [String]) async throws {
        let name = URL(fileURLWithPath: tool).lastPathComponent
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let errors = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: UpdateError.process("\(name) did not start.")) }
        }
        guard status == 0 else {
            let text = String(decoding: errors.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpdateError.process("\(name) failed. \(text)")
        }
    }
}
