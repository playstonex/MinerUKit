import Testing
import Foundation
@testable import MinerUKit

@Suite("HostPolicy")
struct HostPolicyTests {

    @Test("public https hosts are allowed")
    func allowed() {
        #expect(HostPolicy.isAllowed(URL(string: "https://huggingface.co/OpenGryd/x/resolve/main/model.safetensors")!))
        #expect(HostPolicy.isAllowed(URL(string: "https://modelscope.cn/api/v1/models/x/repo")!))
        #expect(HostPolicy.isAllowed(URL(string: "https://hf-mirror.com/x")!))
        #expect(HostPolicy.isAllowed(URL(string: "https://cdn-lfs.huggingface.co/x")!))
        #expect(HostPolicy.isAllowed(URL(string: "http://example.com")!))  // http itself is a legal scheme
        #expect(HostPolicy.isAllowed(URL(string: "https://8.8.8.8/")!))
        #expect(HostPolicy.isAllowed(URL(string: "https://172.32.0.1/")!))  // just outside 172.16/12
    }

    @Test("non-http schemes and hostless URLs are rejected")
    func schemes() {
        #expect(!HostPolicy.isAllowed(URL(string: "ftp://huggingface.co/x")!))
        #expect(!HostPolicy.isAllowed(URL(string: "file:///etc/passwd")!))
        #expect(!HostPolicy.isAllowed(URL(string: "https:///path-only")!))
        #expect(!HostPolicy.isAllowed(URL(string: "javascript:alert(1)")!))
    }

    @Test("localhost and local names are rejected")
    func localhostNames() {
        #expect(!HostPolicy.isAllowed(URL(string: "https://localhost/")!))
        #expect(!HostPolicy.isAllowed(URL(string: "https://api.localhost/")!))
        #expect(!HostPolicy.isAllowed(URL(string: "https://printer.local/")!))
        #expect(!HostPolicy.isAllowed(URL(string: "https://host.internal/")!))
    }

    @Test("loopback, private and reserved IPv4 are rejected")
    func privateV4() {
        let bad = [
            "https://0.0.0.0/", "https://10.0.0.1/", "https://10.255.1.1/",
            "https://100.64.0.1/", "https://127.0.0.1/", "https://127.8.8.8/",
            "https://169.254.169.254/",           // cloud metadata endpoint
            "https://172.16.0.1/", "https://172.31.255.1/",
            "https://192.0.0.1/", "https://192.0.2.1/", "https://192.168.1.1/",
            "https://198.18.0.1/", "https://198.51.100.7/",
            "https://203.0.113.9/", "https://224.0.0.1/", "https://240.0.0.1/",
            "https://255.255.255.255/",
        ]
        for u in bad {
            #expect(!HostPolicy.isAllowed(URL(string: u)!), "should reject \(u)")
        }
    }

    @Test("reserved IPv6 literals are rejected")
    func reservedV6() {
        let bad = [
            "https://[::]/", "https://[::1]/", "https://[::ffff:127.0.0.1]/",
            "https://[::ffff:192.168.0.1]/", "https://[fc00::1]/", "https://[fd12::1]/",
            "https://[fe80::1]/", "https://[ff02::1]/",
        ]
        for u in bad {
            #expect(!HostPolicy.isAllowed(URL(string: u)!), "should reject \(u)")
        }
        #expect(HostPolicy.isAllowed(URL(string: "https://[2606:4700::1111]/")!))
    }

    @Test("ipv4 literal parsing")
    func parsing() {
        #expect(HostPolicy.ipv4Literal("1.2.3.4") == [1, 2, 3, 4])
        #expect(HostPolicy.ipv4Literal("1.2.3") == nil)
        #expect(HostPolicy.ipv4Literal("1.2.3.999") == nil)
        #expect(HostPolicy.ipv4Literal("huggingface.co") == nil)
        #expect(HostPolicy.ipv4Literal("1.2.3.4.5") == nil)
    }
}

@Suite("Model file filter")
struct ModelFileFilterTests {

    @Test("keeps model payload files")
    func keeps() {
        for f in ["model.safetensors", "config.json", "tokenizer.json",
                  "tokenizer_config.json", "chat_template.jinja", "vocab.txt",
                  "preprocessor_config.json", "merges.txt", "sub/weights.safetensors"] {
            #expect(ModelStore.isModelFile(f), "should keep \(f)")
        }
    }

    @Test("drops docs, media and dotfiles")
    func drops() {
        for f in ["README.md", ".gitattributes", "banner.png", "paper.pdf",
                  "notes.txt.bak", ".DS_Store", "image.jpg"] {
            #expect(!ModelStore.isModelFile(f), "should drop \(f)")
        }
    }
}

@Suite("Source URL building")
struct SourceURLTests {

    @Test("huggingFace layout")
    func hf() {
        let s = ModelStore.Source.huggingFace("OpenGryd/x", revision: "v2")
        let list = s.listingURL()
        #expect(list.absoluteString.contains("huggingface.co/api/models/OpenGryd/x/tree/v2"))
        #expect(list.absoluteString.contains("recursive=true"))
        let file = s.fileURL("model.safetensors")
        #expect(file.absoluteString == "https://huggingface.co/OpenGryd/x/resolve/v2/model.safetensors")
        #expect(HostPolicy.isAllowed(file))
    }

    @Test("hfMirror reuses the HF layout on another base")
    func mirror() {
        let s = ModelStore.Source.hfMirror("a/b")
        #expect(s.fileURL("config.json").absoluteString
            == "https://hf-mirror.com/a/b/resolve/main/config.json")
    }

    @Test("modelScope layout")
    func ms() {
        let s = ModelStore.Source.modelScope("OpenDataLab/y")
        let list = s.listingURL()
        #expect(list.absoluteString.contains("modelscope.cn/api/v1/models/OpenDataLab/y/repo/files"))
        #expect(list.absoluteString.contains("Revision=master"))
        let file = s.fileURL("model.safetensors")
        #expect(file.absoluteString.contains("FilePath=model.safetensors"))
        #expect(HostPolicy.isAllowed(file))
    }

    @Test("custom base goes through host policy on download")
    func customBlocked() {
        let s = ModelStore.Source.custom("a/b", base: URL(string: "http://127.0.0.1:8080")!)
        #expect(throws: (any Error).self) { try HostPolicy.validate(s.base) }
        #expect(!HostPolicy.isAllowed(s.base))
    }
}

@Suite("Download progress math")
struct ProgressTests {

    @Test("fraction computes across files")
    func fraction() {
        let p = ModelStore.Progress(
            file: "b.bin", fileIndex: 2, fileCount: 3,
            fileBytes: 500, fileTotal: 1000,
            totalBytes: 1500, grandTotal: 3000)
        #expect(abs(p.fraction - 0.5) < 1e-9)
    }

    @Test("zero total is not a divide-by-zero")
    func zeroTotal() {
        let p = ModelStore.Progress(
            file: "", fileIndex: 0, fileCount: 0, fileBytes: 0,
            fileTotal: 0, totalBytes: 0, grandTotal: 0)
        #expect(p.fraction == 0)
    }
}

@Suite("Source parsing")
struct SourceParseTests {

    @Test("default is the 4bit repository")
    func recommended() {
        #expect(ModelStore.recommended.repo == "playstonex/MinerU2.5-Pro-2605-1.2B-mlx-4bit")
        #expect(ModelStore.recommended.base.host == "huggingface.co")
    }

    @Test("bare owner/name means Hugging Face")
    func bare() throws {
        let s = try ModelStore.Source.parse("  owner/name ")
        #expect(s.repo == "owner/name")
        #expect(s.base.host == "huggingface.co")
        #expect(s.revision == "main")
    }

    @Test("model page URL, with and without revision")
    func urls() throws {
        let page = try ModelStore.Source.parse("https://huggingface.co/playstonex/MinerU2.5-Pro-2605-1.2B-mlx-4bit")
        #expect(page.repo == "playstonex/MinerU2.5-Pro-2605-1.2B-mlx-4bit")
        let tree = try ModelStore.Source.parse("https://huggingface.co/a/b/tree/v2")
        #expect(tree.revision == "v2")
        let file = try ModelStore.Source.parse("https://huggingface.co/a/b/resolve/dev/model.safetensors")
        #expect(file.repo == "a/b" && file.revision == "dev")
    }

    @Test("other hosts are treated as HF-compatible, modelscope as itself")
    func hosts() throws {
        let mirror = try ModelStore.Source.parse("https://hf-mirror.com/a/b")
        #expect(mirror.base.absoluteString == "https://hf-mirror.com")
        #expect(mirror.api == .huggingFace)
        let custom = try ModelStore.Source.parse("https://models.example.com:8443/a/b")
        #expect(custom.base.absoluteString == "https://models.example.com:8443")
        let ms = try ModelStore.Source.parse("https://modelscope.cn/models/OpenDataLab/y")
        #expect(ms.api == .modelScope && ms.repo == "OpenDataLab/y" && ms.revision == "master")
    }

    @Test("garbage is rejected")
    func invalid() {
        for bad in ["", "   ", "justaname", "a/b/c", "a/../b", "ftp://x.com/a/b", "https://huggingface.co/onlyone", "a b/c"] {
            #expect(throws: (any Error).self, "should reject '\(bad)'") {
                try ModelStore.Source.parse(bad)
            }
        }
    }

    @Test("a private-network address parses but is refused at download time")
    func privateHost() throws {
        let s = try ModelStore.Source.parse("http://192.168.1.5/a/b")
        #expect(!HostPolicy.isAllowed(s.base))
    }
}

@Suite("Authorization")
struct AuthTests {

    @Test("token is attached only to the source host over https")
    func scope() {
        let s = ModelStore.Source.huggingFace("a/b", token: "hf_secret")
        let own = s.request(for: URL(string: "https://huggingface.co/a/b/resolve/main/x")!)
        #expect(own.value(forHTTPHeaderField: "Authorization") == "Bearer hf_secret")
        let cdn = s.request(for: URL(string: "https://cdn-lfs.huggingface.co/x")!)
        #expect(cdn.value(forHTTPHeaderField: "Authorization") == nil)
        let plain = s.request(for: URL(string: "http://huggingface.co/a/b")!)
        #expect(plain.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("blank tokens are ignored; mirrors never read the environment token")
    func blank() {
        #expect(ModelStore.Source.huggingFace("a/b").with(token: "  ").token == nil)
        let mirror = ModelStore.Source.hfMirror("a/b")
        #expect(mirror.effectiveToken == nil)
    }
}

// MARK: - Model management

/// Builds throwaway model directories under the system temp dir.
private struct TempModel {
    let dir: URL
    private let fm = FileManager.default

    init() throws {
        dir = fm.temporaryDirectory.appendingPathComponent("minerukit-test-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func write(_ path: String, bytes: Int) throws {
        let url = dir.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    func manifest(_ source: ModelStore.Source, _ files: [ModelStore.RemoteFile]) throws {
        try ModelStore.Manifest(source: source, files: files).write(to: dir)
    }

    func cleanup() { try? fm.removeItem(at: dir) }
}

@Suite("Installed-model state")
struct InstallStateTests {

    @Test("missing directory is notInstalled")
    func missing() {
        let gone = FileManager.default.temporaryDirectory
            .appendingPathComponent("minerukit-absent-\(UUID().uuidString)")
        #expect(ModelStore.installState(at: gone) == .notInstalled)
        #expect(!ModelStore.isInstalled(at: gone))
    }

    @Test("empty directory is notInstalled")
    func empty() throws {
        let m = try TempModel(); defer { m.cleanup() }
        #expect(ModelStore.installState(at: m.dir) == .notInstalled)
    }

    @Test("manifest with every file present and sized is complete")
    func completeViaManifest() throws {
        let m = try TempModel(); defer { m.cleanup() }
        try m.write("config.json", bytes: 10)
        try m.write("model.safetensors", bytes: 100)
        try m.manifest(.huggingFace("a/b"), [
            .init(path: "config.json", size: 10, sha256: nil),
            .init(path: "model.safetensors", size: 100, sha256: nil),
        ])
        #expect(ModelStore.installState(at: m.dir) == .complete)
        #expect(ModelStore.isInstalled(at: m.dir))
    }

    @Test("manifest with a wrong-sized file is partial")
    func partialSize() throws {
        let m = try TempModel(); defer { m.cleanup() }
        try m.write("config.json", bytes: 10)
        try m.write("model.safetensors", bytes: 50)   // manifest expects 100
        try m.manifest(.huggingFace("a/b"), [
            .init(path: "config.json", size: 10, sha256: nil),
            .init(path: "model.safetensors", size: 100, sha256: nil),
        ])
        #expect(ModelStore.installState(at: m.dir) == .partial)
    }

    @Test("manifest with a missing file is partial")
    func partialMissing() throws {
        let m = try TempModel(); defer { m.cleanup() }
        try m.write("config.json", bytes: 10)
        try m.manifest(.huggingFace("a/b"), [
            .init(path: "config.json", size: 10, sha256: nil),
            .init(path: "model.safetensors", size: 100, sha256: nil),
        ])
        #expect(ModelStore.installState(at: m.dir) == .partial)
    }

    @Test("no manifest falls back to config.json + weights structural check")
    func structuralFallback() throws {
        let m = try TempModel(); defer { m.cleanup() }
        try m.write("config.json", bytes: 10)
        #expect(ModelStore.installState(at: m.dir) == .partial)   // no weights yet
        try m.write("model.safetensors", bytes: 100)
        #expect(ModelStore.installState(at: m.dir) == .complete)
    }
}

@Suite("Model manifest")
struct ManifestTests {

    @Test("round-trips source and file metadata")
    func roundTrip() throws {
        let m = try TempModel(); defer { m.cleanup() }
        let src = ModelStore.Source.hfMirror("owner/name", revision: "v3")
        try m.manifest(src, [.init(path: "config.json", size: 5, sha256: "abc")])
        let read = try #require(ModelStore.Manifest.read(at: m.dir))
        #expect(read.repo == "owner/name")
        #expect(read.revision == "v3")
        #expect(read.base == "https://hf-mirror.com")
        #expect(read.files.first?.sha256 == "abc")
    }

    @Test("absent manifest reads as nil")
    func absent() throws {
        let m = try TempModel(); defer { m.cleanup() }
        #expect(ModelStore.Manifest.read(at: m.dir) == nil)
    }
}

@Suite("Verify, disk usage, remove, listing")
struct ManagementTests {

    @Test("verify passes on a sound install and fails on size drift")
    func verifySize() throws {
        let m = try TempModel(); defer { m.cleanup() }
        try m.write("config.json", bytes: 10)
        try m.write("model.safetensors", bytes: 100)
        try m.manifest(.huggingFace("a/b"), [
            .init(path: "config.json", size: 10, sha256: nil),
            .init(path: "model.safetensors", size: 100, sha256: nil),
        ])
        try ModelStore.verify(at: m.dir)   // no throw

        try m.write("model.safetensors", bytes: 99)
        #expect(throws: ModelStore.Error.self) { try ModelStore.verify(at: m.dir) }
    }

    @Test("verify checks sha256 when the manifest records one")
    func verifyChecksum() throws {
        let m = try TempModel(); defer { m.cleanup() }
        // "AAAA" (4 bytes of 0x41) sha256:
        let sha = "63c1dd951ffedf6f7fd968ad4efa39b8ed584f162f46e715114ee184f8de9201"
        try m.write("config.json", bytes: 4)
        try m.manifest(.huggingFace("a/b"), [.init(path: "config.json", size: 4, sha256: sha)])
        try ModelStore.verify(at: m.dir)   // matches

        let bad = try TempModel(); defer { bad.cleanup() }
        try bad.write("config.json", bytes: 4)
        try bad.manifest(.huggingFace("a/b"), [.init(path: "config.json", size: 4, sha256: "deadbeef")])
        #expect(throws: ModelStore.Error.self) { try ModelStore.verify(at: bad.dir) }
    }

    @Test("verify without a manifest throws manifestMissing")
    func verifyNoManifest() throws {
        let m = try TempModel(); defer { m.cleanup() }
        try m.write("config.json", bytes: 10)
        #expect(throws: ModelStore.Error.self) { try ModelStore.verify(at: m.dir) }
    }

    @Test("disk usage sums regular files recursively")
    func disk() throws {
        let m = try TempModel(); defer { m.cleanup() }
        try m.write("config.json", bytes: 10)
        try m.write("sub/weights.safetensors", bytes: 200)
        #expect(ModelStore.diskUsage(at: m.dir) >= 210)   // >= to allow the manifest later
    }

    @Test("remove deletes the directory and is a no-op when absent")
    func remove() throws {
        let m = try TempModel()
        try m.write("config.json", bytes: 1)
        #expect(FileManager.default.fileExists(atPath: m.dir.path))
        try ModelStore.remove(at: m.dir)
        #expect(!FileManager.default.fileExists(atPath: m.dir.path))
        try ModelStore.remove(at: m.dir)   // no throw on second call
    }

    @Test("installedModels finds model subdirectories and skips junk")
    func listing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("minerukit-root-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // A valid model (manifest + files)
        let good = root.appendingPathComponent("model-4bit")
        try FileManager.default.createDirectory(at: good, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 10).write(to: good.appendingPathComponent("config.json"))
        try Data(repeating: 0x41, count: 20).write(to: good.appendingPathComponent("model.safetensors"))
        try ModelStore.Manifest(source: .huggingFace("a/b"), files: [
            .init(path: "config.json", size: 10, sha256: nil),
            .init(path: "model.safetensors", size: 20, sha256: nil),
        ]).write(to: good)

        // Junk directory with no model payload
        let junk = root.appendingPathComponent("notamodel")
        try FileManager.default.createDirectory(at: junk, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 5).write(to: junk.appendingPathComponent("readme.txt"))

        let found = ModelStore.installedModels(in: root)
        #expect(found.count == 1)
        #expect(found.first?.directory.lastPathComponent == "model-4bit")
        #expect(found.first?.state == .complete)
        #expect(found.first?.manifest?.repo == "a/b")
    }
}

@Suite("Progress formatting")
struct ProgressFormatTests {

    @Test("ETA is nil without a rate and finite with one")
    func eta() {
        let noRate = ModelStore.Progress(
            file: "x", fileIndex: 1, fileCount: 1, fileBytes: 0, fileTotal: 100,
            totalBytes: 0, grandTotal: 100, bytesPerSecond: 0)
        #expect(noRate.estimatedTimeRemaining == nil)

        let withRate = ModelStore.Progress(
            file: "x", fileIndex: 1, fileCount: 1, fileBytes: 50, fileTotal: 100,
            totalBytes: 50, grandTotal: 100, bytesPerSecond: 10)
        #expect(withRate.estimatedTimeRemaining == 5)   // 50 bytes left at 10 B/s
    }

    @Test("ETA is nil once complete")
    func etaComplete() {
        let done = ModelStore.Progress(
            file: "x", fileIndex: 1, fileCount: 1, fileBytes: 100, fileTotal: 100,
            totalBytes: 100, grandTotal: 100, bytesPerSecond: 10)
        #expect(done.estimatedTimeRemaining == nil)
    }

    @Test("byte formatting and progress description render")
    func bytes() {
        #expect(!ModelStore.Progress.formatBytes(1_700_000_000).isEmpty)
        let p = ModelStore.Progress(
            file: "x", fileIndex: 1, fileCount: 1, fileBytes: 0, fileTotal: 0,
            totalBytes: 500_000, grandTotal: 1_000_000)
        #expect(p.progressDescription.contains("/"))
    }
}
