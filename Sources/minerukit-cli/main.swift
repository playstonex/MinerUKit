import Foundation
import MinerUKit

/// minerukit — command line for the MinerUKit package.
///
///   minerukit download [--repo R|URL | --recommended] [--mirror hf|hf-mirror|modelscope]
///                      [--to DIR] [--revision V] [--token T]
///   minerukit convert --pdf FILE --model DIR [--pages N] [--out FILE]
@main
struct CLI {

    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let sub = args.first else {
            usage()
            exit(64)
        }
        do {
            switch sub {
            case "download":
                try await download(args)
            case "convert":
                try await convert(args)
            default:
                usage()
                exit(64)
            }
        } catch is CancellationError {
            FileHandle.standardError.write("cancelled\n".data(using: .utf8)!)
            exit(130)
        } catch {
            FileHandle.standardError.write("error: \(error.localizedDescription)\n".data(using: .utf8)!)
            exit(1)
        }
    }

    static func flag(_ name: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    // MARK: download

    static func download(_ args: [String]) async throws {
        let repo = flag("--repo", in: args)
        let mirror = flag("--mirror", in: args)
        let token = flag("--token", in: args)
        let to = URL(fileURLWithPath: flag("--to", in: args) ?? "mineru-model")

        var source: ModelStore.Source
        if repo == nil || args.contains("--recommended") {
            source = ModelStore.recommended.with(token: token)
        } else {
            // `--repo` takes owner/name or a full model page URL.
            do {
                source = try ModelStore.Source.parse(repo!, token: token)
            } catch {
                FileHandle.standardError.write("error: \(error.localizedDescription)\n".data(using: .utf8)!)
                exit(64)
            }
            if let revision = flag("--revision", in: args) { source.revision = revision }
            // `--mirror` re-targets a bare owner/name; a full URL already names its host.
            if let mirror, !repo!.contains("://") {
                let revision = source.revision
                switch mirror {
                case "hf": break
                case "hf-mirror": source = .hfMirror(source.repo, revision: revision, token: token)
                case "modelscope": source = .modelScope(source.repo,
                                                        revision: flag("--revision", in: args) ?? "master")
                default:
                    usage()
                    exit(64)
                }
            }
        }

        let throttle = PercentThrottle()
        let dir = try await ModelStore.download(source, to: to) { p in
            throttle.print(p)
        }
        FileHandle.standardError.write("\ndownloaded to \(dir.path)\n".data(using: .utf8)!)
    }

    static func mb(_ bytes: Int64) -> String {
        String(format: "%.0f", Double(bytes) / 1_000_000)
    }

    /// Prints one progress line per whole percent (the callback arrives on a
    /// session delegate thread, hence the lock).
    final class PercentThrottle: @unchecked Sendable {
        private let lock = NSLock()
        private var last = -1

        func print(_ p: ModelStore.Progress) {
            lock.lock()
            defer { lock.unlock() }
            let percent = Int((p.fraction * 100).rounded())
            guard percent > last || p.fileIndex == p.fileCount else { return }
            last = percent
            FileHandle.standardError.write(
                "\r[\(percent)%] \(p.fileIndex)/\(p.fileCount) \(p.file)"
                    .data(using: .utf8)!)
        }
    }

    // MARK: convert

    static func convert(_ args: [String]) async throws {
        guard let pdf = flag("--pdf", in: args) else {
            usage()
            exit(64)
        }
        var options = MinerUKit.Options()
        options.maxPages = flag("--pages", in: args).flatMap(Int.init)
        if let tierName = flag("--tier", in: args) {
            guard let tier = Tier(rawValue: tierName) else {
                FileHandle.standardError.write("unknown tier '\(tierName)' (flash|basic|standard|advanced)\n".data(using: .utf8)!)
                exit(64)
            }
            options.tier = tier
        }
        if let out = flag("--out", in: args) {
            options.imageOutputDirectory = URL(fileURLWithPath: out)
                .deletingLastPathComponent().appendingPathComponent("images")
        }
        // modelDir is only consulted for model-backed tiers
        let modelDir = URL(fileURLWithPath: flag("--model", in: args) ?? "/nonexistent")
        let markdown = try await MinerUKit.convert(
            pdfURL: URL(fileURLWithPath: pdf),
            modelDir: modelDir,
            options: options
        ) { line in
            FileHandle.standardError.write((line + "\n").data(using: .utf8)!)
        }
        if let out = flag("--out", in: args) {
            try markdown.write(toFile: out, atomically: true, encoding: .utf8)
            FileHandle.standardError.write("wrote \(out)\n".data(using: .utf8)!)
        } else {
            print(markdown)
        }
    }

    static func usage() {
        print("""
        usage:
          minerukit download [--repo OWNER/NAME|MODEL_URL | --recommended]
                             [--mirror hf|hf-mirror|modelscope] [--to DIR] [--revision V]
                             [--token HF_TOKEN]      (default repo is gated; else $HF_TOKEN)
          minerukit convert --pdf FILE [--model DIR] [--pages N] [--out FILE]
                             [--tier flash|basic|standard|advanced]
        """)
    }
}
