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
