import Foundation
import Darwin
import CryptoKit

/// Downloads MLX-converted models from Hugging Face, ModelScope, or any
/// HF-compatible mirror (e.g. hf-mirror.com).
///
/// ```swift
/// let session = try await MinerUKit.Session.load(
///     source: .recommended, in: appSupport.appendingPathComponent("MinerU")
/// ) { p in print(p.fraction) }
///
/// // Any other location: a repo id, or a full URL of a model page.
/// let other = try ModelStore.Source.parse("https://hf-mirror.com/owner/model")
/// ```
///
/// The default repository is gated on Hugging Face: file downloads need an
/// access token of an account that has accepted the model's terms. Pass it
/// via ``Source/token``, or set `HF_TOKEN` / log in with `huggingface-cli`.
public enum ModelStore {

    // MARK: - Source

    public struct Source: Sendable, Equatable {
        public enum API: String, Sendable {
            /// huggingface.co / hf-mirror.com layout (`/resolve/` + `/api/models/.../tree`)
            case huggingFace
            /// modelscope.cn layout (`/api/v1/models/.../repo`)
            case modelScope
        }

        public var repo: String
        public var revision: String
        public var base: URL
        public var api: API
        /// Access token (Hugging Face `hf_…`). Only ever sent over https to
        /// `base`, never to the CDN hosts a download redirects to.
        public var token: String?

        public init(repo: String, revision: String, base: URL, api: API, token: String? = nil) {
            self.repo = repo
            self.revision = revision
            self.base = base
            self.api = api
            self.token = token
        }

        /// Copy with an access token.
        public func with(token: String?) -> Source {
            var copy = self
            let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
            copy.token = (trimmed?.isEmpty ?? true) ? nil : trimmed
            return copy
        }

        /// Token to use for requests: the explicit one, else (only for
        /// huggingface.co) the user's environment / CLI login.
        var effectiveToken: String? {
            if let token { return token }
            return base.host(percentEncoded: false)?.lowercased() == "huggingface.co"
                ? ModelStore.environmentToken() : nil
        }

        /// A request for `url` carrying the bearer token when it is safe to.
        func request(for url: URL) -> URLRequest {
            var request = URLRequest(url: url)
            if let token = effectiveToken, url.scheme?.lowercased() == "https",
               url.host(percentEncoded: false) == base.host(percentEncoded: false) {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            return request
        }

        public static func huggingFace(_ repo: String, revision: String = "main",
                                       token: String? = nil) -> Source {
            Source(repo: repo, revision: revision,
                   base: URL(string: "https://huggingface.co")!, api: .huggingFace).with(token: token)
        }

        /// HF-compatible CDN mirror (useful when huggingface.co is unreachable).
        public static func hfMirror(_ repo: String, revision: String = "main",
                                    token: String? = nil) -> Source {
            Source(repo: repo, revision: revision,
                   base: URL(string: "https://hf-mirror.com")!, api: .huggingFace).with(token: token)
        }

        public static func modelScope(_ repo: String, revision: String = "master") -> Source {
            Source(repo: repo, revision: revision,
                   base: URL(string: "https://modelscope.cn")!, api: .modelScope)
        }

        public static func custom(_ repo: String, base: URL, api: API = .huggingFace,
                                  revision: String = "main", token: String? = nil) -> Source {
            Source(repo: repo, revision: revision, base: base, api: api).with(token: token)
        }

        // MARK: Parsing

        public enum ParseError: Swift.Error, LocalizedError, Equatable {
            case empty
            case invalid(String)
            public var errorDescription: String? {
                switch self {
                case .empty: return "Model address is empty"
                case .invalid(let s):
                    return "Not a model address: '\(s)'. Use owner/name or a model page URL."
                }
            }
        }

        /// Builds a source from what a user would paste:
        /// - `owner/name` (Hugging Face)
        /// - `https://huggingface.co/owner/name[/tree/<revision>]`
        /// - `https://hf-mirror.com/owner/name` (any HF-compatible host)
        /// - `https://modelscope.cn/models/owner/name[/tree/<revision>]`
        ///
        /// Anything on a host other than modelscope.cn is assumed to speak
        /// the Hugging Face API. The host is checked by ``HostPolicy`` when
        /// downloading, not here.
        public static func parse(_ text: String, token: String? = nil) throws -> Source {
            let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !input.isEmpty else { throw ParseError.empty }

            guard input.contains("://") else {
                // Bare repo id: exactly owner/name.
                let parts = input.split(separator: "/", omittingEmptySubsequences: false)
                guard parts.count == 2, parts.allSatisfy(isRepoComponent) else {
                    throw ParseError.invalid(input)
                }
                return .huggingFace(input, token: token)
            }

            guard let url = URL(string: input),
                  let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty,
                  url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "http"
            else { throw ParseError.invalid(input) }

            var parts = url.pathComponents.filter { $0 != "/" }
            let isModelScope = host == "modelscope.cn" || host.hasSuffix(".modelscope.cn")
            // "models/" prefix on ModelScope pages, "models/" never on HF but harmless.
            if parts.first == "models" { parts.removeFirst() }
            guard parts.count >= 2, isRepoComponent(Substring(parts[0])), isRepoComponent(Substring(parts[1]))
            else { throw ParseError.invalid(input) }
            let repo = parts[0] + "/" + parts[1]

            // .../tree/<revision> or .../resolve/<revision>/...
            var revision: String?
            if parts.count >= 4, ["tree", "blob", "resolve"].contains(parts[2]) {
                revision = parts[3]
            }

            let baseString = (url.scheme ?? "https") + "://" + host + (url.port.map { ":\($0)" } ?? "")
            let base = URL(string: baseString)!
            if isModelScope {
                return Source(repo: repo, revision: revision ?? "master", base: base,
                              api: .modelScope)
            }
            return Source(repo: repo, revision: revision ?? "main", base: base,
                          api: .huggingFace).with(token: token)
        }

        private static func isRepoComponent(_ part: Substring) -> Bool {
            !part.isEmpty && part != "." && part != ".."
                && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
        }

        // MARK: URL building

        func listingURL() -> URL {
            switch api {
            case .huggingFace:
                var comps = URLComponents(
                    url: base.appendingPathComponent("api/models/\(repo)/tree/\(revision)"),
                    resolvingAgainstBaseURL: false)!
                comps.queryItems = [URLQueryItem(name: "recursive", value: "true")]
                return comps.url!
            case .modelScope:
                var comps = URLComponents(
                    url: base.appendingPathComponent("api/v1/models/\(repo)/repo/files"),
                    resolvingAgainstBaseURL: false)!
                comps.queryItems = [
                    URLQueryItem(name: "Revision", value: revision),
                    URLQueryItem(name: "Recursive", value: "true"),
                ]
                return comps.url!
            }
        }

        func fileURL(_ path: String) -> URL {
            switch api {
            case .huggingFace:
                return base.appendingPathComponent("\(repo)/resolve/\(revision)")
                    .appendingPathComponent(path)
            case .modelScope:
                var comps = URLComponents(
                    url: base.appendingPathComponent("api/v1/models/\(repo)/repo"),
                    resolvingAgainstBaseURL: false)!
                comps.queryItems = [
                    URLQueryItem(name: "Revision", value: revision),
                    URLQueryItem(name: "FilePath", value: path),
                ]
                return comps.url!
            }
        }
    }

    /// Default model: MLX 4-bit (affine, group size 64) conversion of
    /// MinerU2.5-Pro-2605-1.2B (~1.7 GB, Apache-2.0).
    ///
    /// The repository is **gated** on Hugging Face (automatic approval): accept
    /// the terms on the model page once and supply an access token, otherwise
    /// downloads fail with ``Error/authenticationRequired(_:)``.
    public static let recommended = Source.huggingFace("playstonex/MinerU2.5-Pro-2605-1.2B-mlx-4bit")

    /// Page where access to the default repository is requested.
    public static let recommendedPage = URL(string: "https://huggingface.co/playstonex/MinerU2.5-Pro-2605-1.2B-mlx-4bit")!

    /// Token from `HF_TOKEN` / `HUGGING_FACE_HUB_TOKEN`, or the one
    /// `huggingface-cli login` stored (`~/.cache/huggingface/token`).
    /// Always nil inside an App Sandbox without those, in which case the app
    /// has to ask the user for a token.
    public static func environmentToken() -> String? {
        let env = ProcessInfo.processInfo.environment
        for key in ["HF_TOKEN", "HUGGING_FACE_HUB_TOKEN"] {
            if let value = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        let home = env["HF_HOME"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cache/huggingface")
        let file = home.appendingPathComponent("token")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    // MARK: - Progress

    public struct Progress: Sendable, Equatable {
        public let file: String
        public let fileIndex: Int
        public let fileCount: Int
        public let fileBytes: Int64
        public let fileTotal: Int64
        public let totalBytes: Int64
        public let grandTotal: Int64
        /// Bytes transferred per second, averaged over the download so far.
        /// Zero until the first non-trivial interval elapses.
        public let bytesPerSecond: Double
        public var fraction: Double {
            grandTotal > 0 ? Double(totalBytes) / Double(grandTotal) : 0
        }

        public init(
            file: String, fileIndex: Int, fileCount: Int,
            fileBytes: Int64, fileTotal: Int64,
            totalBytes: Int64, grandTotal: Int64,
            bytesPerSecond: Double = 0
        ) {
            self.file = file
            self.fileIndex = fileIndex
            self.fileCount = fileCount
            self.fileBytes = fileBytes
            self.fileTotal = fileTotal
            self.totalBytes = totalBytes
            self.grandTotal = grandTotal
            self.bytesPerSecond = bytesPerSecond
        }

        /// Seconds remaining at the current average rate, or nil when it
        /// cannot be estimated yet (no measured rate, or already complete).
        public var estimatedTimeRemaining: TimeInterval? {
            guard bytesPerSecond > 0, grandTotal > 0 else { return nil }
            let remaining = grandTotal - totalBytes
            guard remaining > 0 else { return nil }
            return Double(remaining) / bytesPerSecond
        }

        /// `"1.7 GB"`-style rendering of a byte count (SI units, matching
        /// what download hosts advertise).
        public static func formatBytes(_ bytes: Int64) -> String {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return formatter.string(fromByteCount: bytes)
        }

        /// Total vs grand total, e.g. `"420 MB / 1.7 GB"`.
        public var progressDescription: String {
            "\(Self.formatBytes(totalBytes)) / \(Self.formatBytes(grandTotal))"
        }
    }

    struct RemoteFile {
        let path: String
        let size: Int64
        /// sha256 for LFS-backed files when the listing API provides one
        /// (HF tree API `lfs.oid`); nil otherwise.
        let sha256: String?
    }

    public enum Error: Swift.Error, LocalizedError {
        case disallowedHost(String)
        case listingFailed(String, Int)
        case downloadFailed(String, Int)
        case noModelFiles(String)
        case sizeMismatch(String, expected: Int64, got: Int64)
        case checksumMismatch(String)
        case incomplete(String)
        /// A model directory (or a file it should contain) is not on disk.
        case modelNotFound(String)
        /// `verify(at:)` needs a manifest, but the directory has none.
        case manifestMissing(String)
        /// 401/403: gated or private repository, missing/invalid token, or
        /// terms not accepted yet.
        case authenticationRequired(String)

        public var errorDescription: String? {
            switch self {
            case .disallowedHost(let h): return "Refusing to fetch from disallowed host: \(h)"
            case .listingFailed(let r, let code): return "File listing failed for '\(r)' (HTTP \(code))"
            case .downloadFailed(let f, let code): return "Download failed for '\(f)' (HTTP \(code))"
            case .noModelFiles(let r): return "Repository '\(r)' contains no model files"
            case .sizeMismatch(let f, let e, let g): return "'\(f)' is \(g) bytes, expected \(e)"
            case .checksumMismatch(let f): return "'\(f)' failed sha256 verification"
            case .incomplete(let d): return "Downloaded directory is missing config.json or weights: \(d)"
            case .modelNotFound(let d): return "No model found at: \(d)"
            case .manifestMissing(let d): return "No MinerUKit manifest at: \(d). Re-download to enable verification."
            case .authenticationRequired(let r):
                return "'\(r)' needs authorization. Open the model page, accept its terms, "
                    + "then provide a Hugging Face access token (read permission)."
            }
        }
    }

    // MARK: - Download

    /// Maximum attempts per file (1 initial + 4 retries with exponential backoff).
    static let downloadAttempts = 5

    /// Downloads the model files of `source` into `destination` (created if
    /// needed) and returns the directory.
    ///
    /// Resumable: files already present with the expected size — and matching
    /// sha256 when the listing API provides one — are skipped, so an
    /// interrupted download resumes by calling again with the same arguments.
    /// Transient network failures retry with exponential backoff (1s…8s);
    /// checksum mismatches are deterministic and do not retry. Honors task
    /// cancellation.
    @discardableResult
    public static func download(
        _ source: Source,
        to destination: URL,
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> URL {
        try HostPolicy.validate(source.base)
        let files = try await listFiles(source).filter { isModelFile($0.path) }
        guard !files.isEmpty else { throw Error.noModelFiles(source.repo) }

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let grandTotal = files.reduce(Int64(0)) { $0 + $1.size }
        var completed: Int64 = 0
        let meter = RateMeter()  // measures throughput over actually-transferred bytes

        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            let target = destination.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if isCached(target, file) {
                completed += file.size
                progress?(Progress(
                    file: file.path, fileIndex: index + 1, fileCount: files.count,
                    fileBytes: file.size, fileTotal: file.size,
                    totalBytes: completed, grandTotal: grandTotal,
                    bytesPerSecond: meter.rate()))
                continue
            }
            let doneBefore = completed  // Sendable snapshot for the progress closure
            for attempt in 1...downloadAttempts {
                do {
                    try await downloadFile(source, file: file, to: target) { done, total in
                        let rate = meter.observe(fileBytes: done)
                        progress?(Progress(
                            file: file.path, fileIndex: index + 1, fileCount: files.count,
                            fileBytes: done, fileTotal: total,
                            totalBytes: doneBefore + done, grandTotal: grandTotal,
                            bytesPerSecond: rate))
                    }
                    break
                } catch is CancellationError {
                    throw CancellationError()
                } catch let mismatch as Error {
                    // deterministic failures: retrying cannot help
                    if case .checksumMismatch = mismatch { throw mismatch }
                    if case .authenticationRequired = mismatch { throw mismatch }
                    guard attempt < downloadAttempts else { throw mismatch }
                } catch {
                    guard attempt < downloadAttempts else { throw error }
                }
                // exponential backoff: 1s, 2s, 4s, 8s
                try await Task.sleep(nanoseconds: UInt64(1 << (attempt - 1)) * 1_000_000_000)
            }
            completed += file.size
            meter.finishFile()
        }

        guard
            FileManager.default.fileExists(atPath: destination.appendingPathComponent("config.json").path),
            files.contains(where: { $0.path.hasSuffix(".safetensors") })
        else { throw Error.incomplete(destination.path) }
        // Record what we installed so later launches can inspect/verify offline.
        try? Manifest(source: source, files: files).write(to: destination)
        return destination
    }

    /// True when the on-disk file matches the expected size (and sha256 when known).
    static func isCached(_ url: URL, _ file: RemoteFile) -> Bool {
        guard let existing = fileSize(url), existing == file.size else { return false }
        guard let expected = file.sha256, let actual = sha256Hex(url) else { return true }
        return actual == expected
    }

    static func downloadFile(
        _ source: Source,
        file: RemoteFile,
        to target: URL,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        let url = source.fileURL(file.path)
        try HostPolicy.validate(url)
        let observer = ProgressRedirectObserver(onProgress: onProgress)
        let (tmp, response) = try await URLSession.shared.download(
            for: source.request(for: url), delegate: observer)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            if code == 401 || code == 403 { throw Error.authenticationRequired(source.repo) }
            throw Error.downloadFailed(file.path, code)
        }
        let got = fileSize(tmp) ?? 0
        guard got == file.size else {
            try? FileManager.default.removeItem(at: tmp)
            throw Error.sizeMismatch(file.path, expected: file.size, got: got)
        }
        if let expected = file.sha256, file.size > 0, let actual = sha256Hex(tmp), actual != expected {
            try? FileManager.default.removeItem(at: tmp)
            throw Error.checksumMismatch(file.path)
        }
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: tmp, to: target)
    }

    /// Incremental SHA-256, streamed in 1 MiB chunks.
    static func sha256Hex(_ url: URL) -> String? {
        guard let stream = InputStream(url: url) else { return nil }
        defer { stream.close() }
        stream.open()
        var engine = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while case let n = stream.read(&buffer, maxLength: buffer.count), n > 0 {
            _ = engine.update(data: buffer[0..<n])
        }
        guard stream.streamStatus == .atEnd else { return nil }
        return engine.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Listing

    struct HFTreeItem: Codable {
        struct LFS: Codable { let oid: String? }
        let type: String
        let path: String
        let size: Int64?
        let lfs: LFS?
    }

    struct ModelScopeTree: Codable {
        struct Data: Codable {
            struct Entry: Codable {
                enum CodingKeys: String, CodingKey {
                    case type = "Type", path = "Path", size = "Size"
                }
                let type: String
                let path: String
                let size: Int64?
            }
            enum CodingKeys: String, CodingKey { case files = "Files" }
            let files: [Entry]?
        }
        enum CodingKeys: String, CodingKey { case data = "Data" }
        let data: Data?
    }

    static func listFiles(_ source: Source) async throws -> [RemoteFile] {
        let url = source.listingURL()
        try HostPolicy.validate(url)
        let (data, response) = try await URLSession.shared.data(for: source.request(for: url))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            if code == 401 || code == 403 { throw Error.authenticationRequired(source.repo) }
            throw Error.listingFailed(source.repo, code)
        }
        switch source.api {
        case .huggingFace:
            let items = try JSONDecoder().decode([HFTreeItem].self, from: data)
            return items.filter { $0.type == "file" }.map {
                // HF LFS oids are "sha256:<hex>"; plain (non-LFS) files have no oid
                RemoteFile(path: $0.path, size: $0.size ?? 0,
                           sha256: $0.lfs?.oid.flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : $0 })
            }
        case .modelScope:
            let tree = try JSONDecoder().decode(ModelScopeTree.self, from: data)
            return (tree.data?.files ?? []).filter { $0.type == "blob" }
                .map { RemoteFile(path: $0.path, size: $0.size ?? 0, sha256: nil) }
        }
    }

    // MARK: - File filter

    static let modelExtensions: Set<String> = [
        "safetensors", "json", "jinja", "txt", "model", "tiktoken",
    ]

    /// Model payload allowlist — drops READMEs, images, dotfiles, notebooks.
    public static func isModelFile(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty, !name.hasPrefix(".") else { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        return modelExtensions.contains(ext)
    }

    static func fileSize(_ url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize.map(Int64.init)
    }

    // MARK: - Manifest (installed-model metadata)

    /// Written to `.minerukit-manifest.json` at the root of a completed
    /// download. Lets an app inspect, verify, list, and compare installed
    /// models without going back to the network.
    public struct Manifest: Codable, Sendable, Equatable {
        public struct Entry: Codable, Sendable, Equatable {
            public let path: String
            public let size: Int64
            public let sha256: String?
        }

        /// Repo id the files came from (e.g. `owner/name`).
        public let repo: String
        /// Revision/branch/tag that was resolved at download time.
        public let revision: String
        /// Download host (e.g. `https://huggingface.co`).
        public let base: String
        /// Expected files with the sizes (and sha256 when known) at download time.
        public let files: [Entry]
        /// When the download completed (ISO-8601, informational).
        public let downloadedAt: String

        public static let filename = ".minerukit-manifest.json"

        init(source: Source, files: [RemoteFile]) {
            self.repo = source.repo
            self.revision = source.revision
            self.base = source.base.absoluteString
            self.files = files.map { Entry(path: $0.path, size: $0.size, sha256: $0.sha256) }
            self.downloadedAt = ISO8601DateFormatter().string(from: Date())
        }

        func write(to directory: URL) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(self)
            try data.write(to: directory.appendingPathComponent(Self.filename), options: .atomic)
        }

        /// Reads the manifest at the root of `directory`, or nil when absent/unreadable.
        public static func read(at directory: URL) -> Manifest? {
            let url = directory.appendingPathComponent(filename)
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(Manifest.self, from: data)
        }
    }

    // MARK: - Installed-model management

    /// Whether a directory holds a complete, partial, or absent install.
    public enum InstallState: Sendable, Equatable {
        /// No model directory, or it is empty.
        case notInstalled
        /// Some expected files are missing or the wrong size.
        case partial
        /// Every expected file is present with the right size.
        case complete
    }

    /// Minimal, structural check used when no manifest is present: a model
    /// directory needs `config.json` plus at least one `*.safetensors`.
    static func hasModelPayload(in directory: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.appendingPathComponent("config.json").path) else {
            return false
        }
        guard let items = try? fm.contentsOfDirectory(atPath: directory.path) else { return false }
        return items.contains { $0.hasSuffix(".safetensors") }
    }

    /// Install state of a model directory, size-checked. Uses the download
    /// manifest when present (authoritative file list); otherwise falls back
    /// to a structural `config.json` + weights check. Does not hit the network.
    public static func installState(at directory: URL) -> InstallState {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return .notInstalled }

        if let manifest = Manifest.read(at: directory) {
            guard !manifest.files.isEmpty else { return .notInstalled }
            for entry in manifest.files {
                let fileURL = directory.appendingPathComponent(entry.path)
                guard let size = fileSize(fileURL), size == entry.size else { return .partial }
            }
            return .complete
        }

        // No manifest (older install or sideloaded dir): structural check.
        // A model is recognized only by `config.json`; without it the
        // directory is not a model at all (notInstalled). With it but no
        // weights, it is a partial install.
        let hasConfig = fm.fileExists(atPath: directory.appendingPathComponent("config.json").path)
        guard hasConfig else { return .notInstalled }
        return hasModelPayload(in: directory) ? .complete : .partial
    }

    /// Convenience: true only when `installState(at:) == .complete`.
    public static func isInstalled(at directory: URL) -> Bool {
        installState(at: directory) == .complete
    }

    /// Total bytes used by a model directory (recursive). Zero when missing.
    public static func diskUsage(at directory: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: []) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true, let size = values?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// An installed model found under a root directory.
    public struct InstalledModel: Sendable, Equatable {
        public let directory: URL
        public let manifest: Manifest?
        public let state: InstallState
        public let diskUsage: Int64
    }

    /// Scans the immediate children of `root` for model directories (those
    /// with a manifest or a `config.json` + weights). The `root` itself is
    /// also considered when it directly contains a model. Network-free.
    public static func installedModels(in root: URL) -> [InstalledModel] {
        let fm = FileManager.default
        func describe(_ dir: URL) -> InstalledModel? {
            let state = installState(at: dir)
            guard state != .notInstalled else { return nil }
            return InstalledModel(
                directory: dir, manifest: Manifest.read(at: dir),
                state: state, diskUsage: diskUsage(at: dir))
        }

        var results: [InstalledModel] = []
        if let direct = describe(root) { results.append(direct) }

        let children = (try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        for child in children {
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            if let model = describe(child) { results.append(model) }
        }
        return results
    }

    /// Verifies an installed model against its manifest: every file present
    /// with the right size, and matching sha256 when the manifest recorded one
    /// (LFS-backed weights on Hugging Face). Throws the first problem it finds.
    /// Network-free. Requires a manifest (download writes one).
    public static func verify(at directory: URL) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw Error.modelNotFound(directory.path)
        }
        guard let manifest = Manifest.read(at: directory) else {
            throw Error.manifestMissing(directory.path)
        }
        for entry in manifest.files {
            let fileURL = directory.appendingPathComponent(entry.path)
            guard let size = fileSize(fileURL) else {
                throw Error.incomplete(entry.path)
            }
            guard size == entry.size else {
                throw Error.sizeMismatch(entry.path, expected: entry.size, got: size)
            }
            if let expected = entry.sha256, entry.size > 0 {
                guard let actual = sha256Hex(fileURL), actual == expected else {
                    throw Error.checksumMismatch(entry.path)
                }
            }
        }
    }

    /// Deletes an installed model directory and everything under it.
    /// No-ops when the directory does not exist.
    public static func remove(at directory: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return }
        try fm.removeItem(at: directory)
    }
}

// MARK: - Session convenience

extension MinerUKit.Session {
    /// Downloads (or reuses an already-complete download of) the model into
    /// `directory`, then loads it. The natural entry point for apps.
    ///
    /// When `directory` already holds a complete install (per
    /// ``ModelStore/installState(at:)``), the network listing is skipped and
    /// the model loads straight from disk — so apps launch offline after the
    /// first successful download. Set `allowOfflineReuse` to `false` to always
    /// re-check the remote (still resumable).
    @discardableResult
    public static func load(
        source: ModelStore.Source,
        in directory: URL,
        allowOfflineReuse: Bool = true,
        progress: (@Sendable (ModelStore.Progress) -> Void)? = nil
    ) async throws -> MinerUKit.Session {
        if allowOfflineReuse, ModelStore.isInstalled(at: directory) {
            return try await MinerUKit.Session(modelDir: directory)
        }
        let dir = try await ModelStore.download(source, to: directory, progress: progress)
        return try await MinerUKit.Session(modelDir: dir)
    }
}

// MARK: - Download rate meter

/// Thread-safe average-throughput meter shared across the download's
/// `@Sendable` progress closures. Averages over bytes actually transferred
/// (cached files do not count), so the rate reflects real network speed.
final class RateMeter: @unchecked Sendable {
    private let lock = NSLock()
    private let start = Date()
    private var transferred: Int64 = 0   // completed earlier files
    private var currentFile: Int64 = 0   // latest byte count for the in-flight file

    /// Records the in-flight file's cumulative bytes and returns the current rate.
    func observe(fileBytes: Int64) -> Double {
        lock.lock(); defer { lock.unlock() }
        currentFile = fileBytes
        return rateLocked()
    }

    /// Rolls the in-flight file's bytes into the transferred total.
    func finishFile() {
        lock.lock(); defer { lock.unlock() }
        transferred += currentFile
        currentFile = 0
    }

    /// Current average rate without recording new bytes.
    func rate() -> Double {
        lock.lock(); defer { lock.unlock() }
        return rateLocked()
    }

    private func rateLocked() -> Double {
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed > 0.25 else { return 0 }  // ignore the first noisy quarter-second
        return Double(transferred + currentFile) / elapsed
    }
}

// MARK: - Host policy (SSRF hygiene)

/// Guards every outbound request: http/https only, and never to localhost,
/// loopback, link-local, private, or reserved addresses. Applies to the
/// initial URL and to every redirect hop.
enum HostPolicy {

    static func validate(_ url: URL) throws {
        guard isAllowed(url) else {
            throw ModelStore.Error.disallowedHost(url.absoluteString)
        }
    }

    static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        guard let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else {
            return false
        }
        if host == "localhost" || host.hasSuffix(".localhost")
            || host.hasSuffix(".local") || host.hasSuffix(".internal") {
            return false
        }
        if let v4 = ipv4Literal(host) {
            return !isReservedIPv4(v4)
        }
        if host.contains(":") {  // IPv6 literal (with or without brackets)
            let literal = host.hasPrefix("[") ? String(host.dropFirst().dropLast()) : host
            var addr = in6_addr()
            guard inet_pton(AF_INET6, literal, &addr) == 1 else { return false }
            return !isReservedIPv6(addr)
        }
        return true
    }

    static func ipv4Literal(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        for part in parts {
            guard let v = Int(part), (0...255).contains(v) else { return nil }
            octets.append(v)
        }
        return octets
    }

    /// 0/8, 10/8, 100.64/10 (CGNAT), 127/8, 169.254/16, 172.16/12, 192.0.0/24,
    /// 192.0.2/24, 192.168/16, 198.18/15, 198.51.100/24, 203.0.113/24,
    /// 224/4 (multicast), 240/4 + broadcast.
    static func isReservedIPv4(_ o: [Int]) -> Bool {
        let a = o[0], b = o[1]
        if a == 0 || a == 10 || a == 127 { return true }
        if a == 100 && (64...127).contains(b) { return true }
        if a == 169 && b == 254 { return true }
        if a == 172 && (16...31).contains(b) { return true }
        if a == 192 && (b == 0 || b == 2 || b == 168) { return true }
        if a == 198 && ((18...19).contains(b) || b == 51) { return true }
        if a == 203 && b == 0 && o[2] == 113 { return true }
        if a >= 224 { return true }
        return false
    }

    /// ::, ::1, fc00::/7, fe80::/10, ff00::/8, and IPv4-mapped addresses.
    static func isReservedIPv6(_ addr: in6_addr) -> Bool {
        withUnsafeBytes(of: addr) { raw in
            let b = Array(raw)
            if b.allSatisfy({ $0 == 0 }) { return true }                       // ::
            if b.prefix(15).allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }  // ::1
            if b[0] == 0xff { return true }                                     // ff00::/8
            if (b[0] & 0xfe) == 0xfc { return true }                            // fc00::/7
            if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 { return true }            // fe80::/10
            if b.prefix(10).allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff {
                return isReservedIPv4([Int(b[12]), Int(b[13]), Int(b[14]), Int(b[15])])
            }
            return false
        }
    }
}

/// Per-call URLSession delegate: surfaces download progress and re-validates
/// redirect targets against the host policy.
final class ProgressRedirectObserver: NSObject, URLSessionTaskDelegate, @unchecked Sendable {

    let onProgress: @Sendable (Int64, Int64) -> Void

    init(onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if let url = request.url, HostPolicy.isAllowed(url) {
            var next = request
            // Signed CDN URLs must not receive the user's token.
            if url.host(percentEncoded: false) != response.url?.host(percentEncoded: false) {
                next.setValue(nil, forHTTPHeaderField: "Authorization")
            }
            completionHandler(next)
        } else {
            completionHandler(nil)  // blocks redirects to disallowed hosts
        }
    }
}
