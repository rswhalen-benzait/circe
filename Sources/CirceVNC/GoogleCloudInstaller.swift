import CryptoKit
import Foundation

/// Installs Google's Cloud CLI for Circe when the Mac has none (or only a broken one): a pinned release of
/// the official archive plus a relocatable CPython (python-build-standalone), each verified against a SHA-256
/// shipped with Circe, into ~/Library/Application Support/Circe/GoogleCloud. No sudo, no shell profile edits,
/// no `gcloud init`; sign-ins stay in gcloud's normal store (~/.config/gcloud), shared with any other gcloud.
public enum GoogleCloudInstaller {
    struct Artifact { var url: URL; var sha256: String; var megabytes: Int }

    static let sdkVersion = "588.0.0"
    static let pythonRelease = "20261026"
    static let pythonVersion = "3.12.16"

    static var isAppleSilicon: Bool {
        var info = utsname(); uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) } == "arm64"
    }

    static var sdk: Artifact {
        let arch = isAppleSilicon ? "arm" : "x86_64"
        return Artifact(url: URL(string: "https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-\(sdkVersion)-darwin-\(arch).tar.gz")!,
                        sha256: isAppleSilicon ? "0f580f1323d0465b11d1d7c506e701c27729e9c5ea0e1d0f855a4dc3e665db89"
                                               : "7941b3911838373f6af9fe96f957913127c531c9b4c5104ee9c0e9e9a55c5fb6", megabytes: 54)
    }

    static var python: Artifact {
        let triple = isAppleSilicon ? "aarch64-apple-darwin" : "x86_64-apple-darwin"
        let name = "cpython-\(pythonVersion)+\(pythonRelease)-\(triple)-install_only.tar.gz"
        return Artifact(url: URL(string: "https://github.com/astral-sh/python-build-standalone/releases/download/\(pythonRelease)/\(name.replacingOccurrences(of: "+", with: "%2B"))")!,
                        sha256: isAppleSilicon ? "fbf4afef53c2a6b72bb741bc06d5671a9dfaf87bd84e5aa73ac9b3d0d589f14e"
                                               : "a962e47df522889eaa7ff0d6a56203f1079f68aabb65ffdbe8455f362bc769f3", megabytes: 25)
    }

    public static var root: URL {
        if let path = ProcessInfo.processInfo.environment["CIRCE_GCLOUD_ROOT"] { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Circe/GoogleCloud", isDirectory: true)
    }
    static var sdkDirectory: URL { root.appendingPathComponent("sdk-\(sdkVersion)", isDirectory: true) }
    static var pythonDirectory: URL { root.appendingPathComponent("python-\(pythonVersion)", isDirectory: true) }

    /// Circe's own gcloud, when installed.
    public static var managedGCloud: URL? {
        let url = sdkDirectory.appendingPathComponent("google-cloud-sdk/bin/gcloud")
        return FileManager.default.isExecutableFile(atPath: url.path) && managedPython != nil ? url : nil
    }
    public static var managedPython: URL? {
        let url = pythonDirectory.appendingPathComponent("python/bin/python3")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// Settings Circe's gcloud needs: its Python, and no self-update prompts.
    static func environment(for executable: URL) -> [String: String] {
        guard executable.path.hasPrefix(root.path), let python = managedPython else { return [:] }
        return ["CLOUDSDK_PYTHON": python.path, "CLOUDSDK_COMPONENT_MANAGER_DISABLE_UPDATE_CHECK": "1"]
    }

    public static var downloadMegabytes: Int { sdk.megabytes + python.megabytes }

    /// Downloads, verifies, unpacks and health-checks both pieces; replaces nothing until all of it works.
    public static func install(cancel: GoogleCloud.CancelToken, progress: @escaping (String) -> Void) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        progress("Downloading Python for Google’s tools (\(python.megabytes) MB)…")
        let pythonArchive = try download(python, to: staging, cancel: cancel)
        progress("Downloading Google Cloud tools (\(sdk.megabytes) MB)…")
        let sdkArchive = try download(sdk, to: staging, cancel: cancel)

        progress("Unpacking…")
        let pythonStage = staging.appendingPathComponent("python-stage", isDirectory: true)
        let sdkStage = staging.appendingPathComponent("sdk-stage", isDirectory: true)
        try extract(pythonArchive, into: pythonStage)
        try extract(sdkArchive, into: sdkStage)
        if cancel.isCancelled { throw GoogleCloud.Failure.cancelled }

        progress("Checking Google Cloud tools…")
        let python = pythonStage.appendingPathComponent("python/bin/python3")
        let gcloud = sdkStage.appendingPathComponent("google-cloud-sdk/bin/gcloud")
        guard fm.isExecutableFile(atPath: python.path), fm.isExecutableFile(atPath: gcloud.path) else {
            throw GoogleCloud.Failure.other("The downloaded tools were incomplete. Circe hasn’t installed them.")
        }
        try healthCheck(gcloud: gcloud, python: python)

        // Move into place only after everything checks out; keep any previous copy until then.
        for (stage, final) in [(pythonStage, pythonDirectory), (sdkStage, sdkDirectory)] {
            let old = staging.appendingPathComponent("old-\(final.lastPathComponent)")
            if fm.fileExists(atPath: final.path) { try fm.moveItem(at: final, to: old) }
            do { try fm.moveItem(at: stage, to: final) }
            catch { if fm.fileExists(atPath: old.path) { try? fm.moveItem(at: old, to: final) }; throw error }
        }
        progress("Google Cloud tools are ready.")
    }

    static func download(_ artifact: Artifact, to directory: URL, cancel: GoogleCloud.CancelToken) throws -> URL {
        let destination = directory.appendingPathComponent(artifact.url.lastPathComponent.removingPercentEncoding ?? "download.tar.gz")
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var outcome: Result<URL, Error> = .failure(GoogleCloud.Failure.timedOut)
        let task = URLSession.shared.downloadTask(with: artifact.url) { location, response, error in
            if let error { outcome = .failure(error) }
            else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                outcome = .failure(GoogleCloud.Failure.other("Google’s download server answered \(http.statusCode)."))
            } else if let location {
                do { try FileManager.default.moveItem(at: location, to: destination); outcome = .success(destination) }
                catch { outcome = .failure(error) }
            }
            done.signal()
        }
        cancel.onCancel { task.cancel() }
        task.resume()
        if done.wait(timeout: .now() + 900) == .timedOut { task.cancel(); throw GoogleCloud.Failure.timedOut }
        if cancel.isCancelled { throw GoogleCloud.Failure.cancelled }
        let file: URL
        do { file = try outcome.get() }
        catch let failure as GoogleCloud.Failure { throw failure }
        catch { throw GoogleCloud.Failure.offline }
        guard try sha256(of: file) == artifact.sha256 else {
            throw GoogleCloud.Failure.other("The download couldn’t be verified, so Circe hasn’t installed it. Try again later.")
        }
        return file
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Lists the archive first and refuses absolute or `..` paths, then unpacks and refuses symlinks that
    /// point outside the destination.
    static func extract(_ archive: URL, into destination: URL) throws {
        let listing = try tar(["-tzf", archive.path])
        for entry in listing.split(separator: "\n") where entry.hasPrefix("/") || entry.split(separator: "/").contains("..") {
            throw GoogleCloud.Failure.other("The download contained an unsafe file path (\(entry)). Circe hasn’t installed it.")
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        _ = try tar(["-xzf", archive.path, "-C", destination.path])
        let base = destination.resolvingSymlinksInPath().path
        let enumerator = FileManager.default.enumerator(at: destination, includingPropertiesForKeys: [.isSymbolicLinkKey])
        while let item = enumerator?.nextObject() as? URL {
            guard (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true else { continue }
            let target = item.resolvingSymlinksInPath().path
            if !target.hasPrefix(base + "/") && target != base {
                throw GoogleCloud.Failure.other("The download contained a link outside its folder. Circe hasn’t installed it.")
            }
        }
    }

    static func tar(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out; process.standardError = err; process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        _ = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw GoogleCloud.Failure.other("Circe couldn’t unpack the download.") }
        return String(decoding: data, as: UTF8.self)
    }

    static func healthCheck(gcloud: URL, python: URL) throws {
        let process = Process()
        process.executableURL = gcloud
        process.arguments = ["version", "--format=json"]
        var environment = GoogleCloud.environment()
        environment["CLOUDSDK_PYTHON"] = python.path
        environment["CLOUDSDK_COMPONENT_MANAGER_DISABLE_UPDATE_CHECK"] = "1"
        process.environment = environment
        let out = Pipe()
        process.standardOutput = out; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, String(decoding: data, as: UTF8.self).contains("\"Google Cloud SDK\"") else {
            throw GoogleCloud.Failure.other("Google’s tools didn’t start on this Mac after installing.")
        }
    }
}
