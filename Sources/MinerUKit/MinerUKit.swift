import Foundation
import CoreGraphics
import MLX
import Tokenizers
import MLXLMCommon
import MLXVLM
import MLXHuggingFace

/// Document parsing pipeline backed by MinerU2.5-Pro (Qwen2-VL 1.2B, MLX quantized).
///
/// Implements MinerU's two-stage protocol in pure Swift on mlx-swift-lm:
/// page render → 1036² layout detection → per-region recognition → Markdown.
///
/// ```swift
/// // One-shot (loads the model on every call):
/// let markdown = try await MinerUKit.convert(
///     pdfURL: pdfUrl, modelDir: modelDirectory
/// ) { line in print(line) }
///
/// // Or reuse the loaded model across documents:
/// let session = try await MinerUKit.Session(modelDir: modelDirectory)
/// let md1 = try await session.convert(pdfURL: firstPdf)
/// let md2 = try await session.convert(pdfURL: secondPdf)
/// ```
public enum MinerUKit {

    // MARK: - Options

    /// Pipeline configuration. All classifier tables live here (value type,
    /// Sendable) so concurrent conversions cannot interfere through globals.
    public struct Options: Sendable {
        /// Maximum number of pages to process (default: all).
        public var maxPages: Int?
        /// PDF raster scale (3.0 ≈ 216 dpi, matching the reference pipeline).
        public var renderScale: CGFloat
        /// Layout stage input size; pages are stretched to this square.
        public var layoutSize: Int
        /// Vision token budget override (matches the model's preprocessor config;
        /// mlx-swift-lm clamps to 1280×28×28 by default which would shrink the page
        /// and degrade layout detection — do not lower this blindly).
        public var minPixels: Int
        public var maxPixels: Int
        /// When set, per-page layout PNG + raw layout output are copied here (debugging).
        public var dumpDirectory: URL?
        /// Destination directory for cropped figure images. When set, images are
        /// written there and referenced by relative filename; when nil they go to a
        /// unique subdirectory of the system temp dir (purged by the OS eventually).
        public var imageOutputDirectory: URL?
        /// Per-type recognition prompts (MinerU protocol).
        public var prompts: [String: String]
        /// Block types that carry images (cropped and referenced as `![](file.png)`).
        public var imageTypes: Set<String>
        /// Block types dropped as noise.
        public var skipTypes: Set<String>
        /// Parsing tier (default `.standard`). `.flash` needs no model at all;
        /// `.basic` only touches the model for pages without a text layer.
        public var tier: Tier
        /// Delimiters for display equations (default `$$ … $$`).
        public var displayMath: DisplayMathStyle

        public init(
            maxPages: Int? = nil,
            renderScale: CGFloat = 3.0,
            layoutSize: Int = 1036,
            minPixels: Int = 50_176,
            maxPixels: Int = 1_605_632,
            dumpDirectory: URL? = nil,
            imageOutputDirectory: URL? = nil,
            prompts: [String: String] = Options.standardPrompts,
            imageTypes: Set<String> = ["figure", "image", "chart", "image_block"],
            skipTypes: Set<String> = [
                "abandon", "seal", "page_number", "footer", "header", "aside_text",
            ],
            tier: Tier = .standard,
            displayMath: DisplayMathStyle = .dollars
        ) {
            self.maxPages = maxPages
            self.renderScale = renderScale
            self.layoutSize = layoutSize
            self.minPixels = minPixels
            self.maxPixels = maxPixels
            self.dumpDirectory = dumpDirectory
            self.imageOutputDirectory = imageOutputDirectory
            self.prompts = prompts
            self.imageTypes = imageTypes
            self.skipTypes = skipTypes
            self.tier = tier
            self.displayMath = displayMath
        }

        public static let standardPrompts: [String: String] = [
            "text": "\nText Recognition:",
            "title": "\nText Recognition:",
            "list": "\nText Recognition:",
            "page_footnote": "\nText Recognition:",
            "ref_text": "\nText Recognition:",
            "table": "\nTable Recognition:",
            "equation": "\nFormula Recognition:",
        ]

        public static let standard = Options()
    }

    public enum Error: Swift.Error, LocalizedError {
        case cannotOpenPDF(String)
        case emptyPDF
        case cannotWriteImage(String)
        case modelNotFound(String)
        public var errorDescription: String? {
            switch self {
            case .cannotOpenPDF(let p): return "Cannot open PDF: \(p)"
            case .emptyPDF: return "PDF has no pages"
            case .cannotWriteImage(let p): return "Cannot write image: \(p)"
            case .modelNotFound(let p): return "Model directory not found: \(p)"
            }
        }
    }

    /// Layout-stage prompt (MinerU protocol).
    public static let layoutPrompt = "\nLayout Detection:"

    // MARK: - One-shot entry point

    /// Converts a PDF to Markdown, loading the model for this call only.
    /// Prefer ``Session`` when converting more than one document.
    /// With `tier == .flash` no model is needed and `modelDir` is ignored
    /// (pass any URL).
    /// Throws `CancellationError` promptly between pages/blocks when the
    /// surrounding task is cancelled.
    public static func convert(
        pdfURL: URL,
        modelDir: URL,
        options: Options = .standard,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        guard options.tier.usesModel else {
            return try flashConvert(pdfURL: pdfURL, options: options, progress: progress)
        }
        let session = try await Session(modelDir: modelDir)
        return try await session.convert(pdfURL: pdfURL, options: options, progress: progress)
    }

    /// Flash tier: native text layer only, zero model involvement.
    static func flashConvert(
        pdfURL: URL,
        options: Options,
        progress: (@Sendable (String) -> Void)? = nil
    ) throws -> String {
        let report = progress ?? { _ in }
        report(options.tier.describe)
        let texts = TextLayer.pageTexts(of: pdfURL)
        let pageCount = min(texts.count, options.maxPages ?? texts.count)
        var blocks: [String] = []
        for index in 0..<pageCount {
            try Task.checkCancellation()
            let raw = texts[index]
            guard TextLayer.isTextDense(raw) else {
                blocks.append("*（第 \(index + 1) 页无文本层，请使用 basic 及以上档位）*")
                report("page \(index + 1): no text layer")
                continue
            }
            blocks.append(TextLayer.markdownBlocks(raw))
            report("page \(index + 1): text layer")
        }
        return blocks.joined(separator: "\n\n")
    }

    // MARK: - Reusable session

    /// A loaded model plus per-conversion pipeline state. Holds the ~1.6 GB
    /// model in memory; create once and reuse for many documents.
    ///
    /// `Session` is `Sendable`: concurrent `convert` calls on the same instance
    /// are safe (each gets unique temp files), though they share GPU throughput.
    public final class Session: Sendable {

        public let modelDir: URL
        private let container: ModelContainer

        public init(modelDir: URL) async throws {
            guard FileManager.default.fileExists(atPath: modelDir.path) else {
                throw Error.modelNotFound(modelDir.path)
            }
            self.modelDir = modelDir
            self.container = try await loadModelContainer(
                from: modelDir, using: #huggingFaceTokenizerLoader()
            )
        }

        public func convert(
            pdfURL: URL,
            options: Options = .standard,
            progress: (@Sendable (String) -> Void)? = nil
        ) async throws -> String {
            let pdf = try CGPDFDocument.open(pdfURL)
            let pageCount = min(pdf.numberOfPages, options.maxPages ?? pdf.numberOfPages)
            guard pageCount > 0 else { throw Error.emptyPDF }
            let report = progress ?? { _ in }

            // Flash never touches the model, even on a Session.
            guard options.tier.usesModel else {
                return try MinerUKit.flashConvert(pdfURL: pdfURL, options: options, progress: progress)
            }
            report(options.tier.describe)

            let runID = UUID().uuidString.prefix(8)
            // Fresh ngram-ban state per generation (the factory contract),
            // shared across this conversion's generations.
            let antiLoop = GenerationComponents(
                logitProcessorFactory: { NoRepeatNGramProcessor(ngramSize: 100) }
            )
            let processing = UserInput.Processing(
                resize: nil, minPixels: options.minPixels, maxPixels: options.maxPixels
            )
            // basic extracts text-layer pages natively; advanced renders finer.
            let pageTexts: [String]
            if options.tier == .basic {
                pageTexts = TextLayer.pageTexts(of: pdfURL)
            } else {
                pageTexts = []
            }

            var pieces: [Piece] = []
            let pdfStem = pdfURL.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression)
            for pageIndex in 0..<pageCount {
                try Task.checkCancellation()
                if pageIndex < pageTexts.count, TextLayer.isTextDense(pageTexts[pageIndex]) {
                    pieces.append(Piece(kind: .body, text: TextLayer.markdownBlocks(pageTexts[pageIndex]) + "\n\n"))
                    report("page \(pageIndex + 1): text layer (fast path)")
                    continue
                }
                guard let page = pdf.page(at: pageIndex + 1) else {
                    report("page \(pageIndex + 1): cannot open page, skipped")
                    continue
                }
                try await Self.processPage(
                    page: page,
                    pageIndex: pageIndex,
                    pdfStem: pdfStem,
                    container: container,
                    options: options,
                    antiLoop: antiLoop,
                    processing: processing,
                    runID: String(runID),
                    report: report,
                    pieces: &pieces
                )
            }
            return Self.assemble(pieces)
        }

        // MARK: - Internals

        /// One assembled content block before heading levels are assigned.
        struct Piece {
            enum Kind {
                case title(heightPercent: Double)
                case body
                case table
                case equation
            }
            var kind: Kind
            var text: String
            /// Plain prose (`text` / `list_item`): a later `mergePrev` piece may append to it.
            var isText = false
            /// Continues the previous prose piece (paragraph split by a column or page break).
            var mergePrev = false
        }

        static func processPage(
            page: CGPDFPage,
            pageIndex: Int,
            pdfStem: String,
            container: ModelContainer,
            options: Options,
            antiLoop: GenerationComponents,
            processing: UserInput.Processing,
            runID: String,
            report: (@Sendable (String) -> Void),
            pieces: inout [Piece]
        ) async throws {
            let t0 = Date()
            // tier.renderScale keeps an explicit user override (e.g. a lower
            // scale for speed) while letting .advanced default to 288 dpi.
            let scale = max(options.renderScale, options.tier.renderScale)
            guard let rendered = renderPage(page, scale: scale),
                  let layoutImage = resizedLayout(rendered, size: options.layoutSize) else {
                report("page \(pageIndex + 1): render failed, skipped")
                return
            }

            let layoutURL = try writePNG(layoutImage, name: "minerukit_\(runID)_layout.png")
            defer { try? FileManager.default.removeItem(at: layoutURL) }

            let session = ChatSession(
                container,
                generateParameters: GenerateParameters(maxTokens: 2000, temperature: 0.0),
                components: antiLoop,
                processing: processing
            )
            let raw = try await session.respond(to: layoutPrompt, image: .url(layoutURL))
            dump(pageIndex: pageIndex + 1, raw: raw, url: layoutURL, options: options)
            let blocks = LayoutParser.parse(raw, grid: LayoutParser.standardGrid)
            report("page \(pageIndex + 1): \(blocks.count) blocks (layout \(elapsed(t0))s)")

            var recognized: [RecognizedBlock] = []
            for (bi, block) in blocks.enumerated() {
                try Task.checkCancellation()
                let t1 = Date()
                let type = block.type
                if options.imageTypes.contains(type) {
                    if let crop = renderCrop(rendered, box: block.box, pad: 0.005) {
                        let name = try saveFigureImage(
                            crop, pageIndex: pageIndex + 1, index: bi,
                            pdfStem: pdfStem, options: options, runID: runID
                        )
                        recognized.append(RecognizedBlock(type: type, box: block.box, content: "", imageName: name))
                    }
                    continue
                }
                if options.skipTypes.contains(type) { continue }
                // Containers are never read themselves: their children are
                // recognized individually (equation_block is merged later).
                if type == "equation_block" {
                    recognized.append(RecognizedBlock(type: type, box: block.box, content: ""))
                    continue
                }
                if type == "list", LayoutParser.hasChildren(block, in: blocks) { continue }
                guard let prompt = options.prompts[type] ?? options.prompts["text"],
                      let crop = renderCrop(rendered, box: block.box) else { continue }

                let oriented = block.rotation == .up ? crop : try crop.rotated(by: block.rotation.angle)
                let url = try writePNG(prepareRegion(oriented), name: "minerukit_\(runID)_region.png")
                defer { try? FileManager.default.removeItem(at: url) }
                let recSession = ChatSession(
                    container,
                    generateParameters: samplingParameters(
                        for: type, maxTokens: options.tier.recognitionMaxTokens
                    ),
                    components: antiLoop,
                    processing: processing
                )
                let text = try await recSession.respond(to: prompt, image: .url(url))
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                recognized.append(RecognizedBlock(
                    type: type, box: block.box, content: trimmed, mergePrev: block.mergePrev
                ))
                report("  \(bi + 1). \(type) \(elapsed(t1))s \(trimmed.prefix(50).replacingOccurrences(of: "\n", with: " "))")
            }
            pieces += PostProcess.pieces(from: recognized, style: options.displayMath)
        }

        /// MinerU's per-type sampling: presence 1.0 everywhere, frequency
        /// 0.005 for tables (long repetitive rows are legitimate) and 0.05
        /// for everything else.
        static func samplingParameters(for type: String, maxTokens: Int) -> GenerateParameters {
            GenerateParameters(
                maxTokens: maxTokens, temperature: 0.0,
                presencePenalty: 1.0, presenceContextSize: 64,
                frequencyPenalty: type == "table" ? 0.005 : 0.05, frequencyContextSize: 64
            )
        }

        static func elapsed(_ since: Date) -> String {
            String(format: "%.1f", -since.timeIntervalSinceNow)
        }

        /// Figures go to `options.imageOutputDirectory` when set (named after
        /// the PDF so successive documents do not collide), otherwise to the
        /// system temp dir under a per-run prefix.
        static func saveFigureImage(
            _ image: CGImage, pageIndex: Int, index: Int,
            pdfStem: String, options: Options, runID: String
        ) throws -> String {
            if let dir = options.imageOutputDirectory {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = try writePNG(image, to: dir, name: "\(pdfStem)_p\(pageIndex)_i\(index).png")
                return url.lastPathComponent
            }
            let url = try writePNG(image, name: "minerukit_\(runID)_p\(pageIndex)_i\(index).png")
            return url.lastPathComponent
        }

        /// Headings: distinct title heights map to levels 1…4 (taller → higher).
        /// Consecutive bodies starting with the same 50 chars are collapsed
        /// (overlapping layout boxes get recognized twice). Prose flagged
        /// `mergePrev` is appended to the previous prose block, even across
        /// pages (upstream `json2md`).
        static func assemble(_ pieces: [Piece]) -> String {
            let heights = Set(
                pieces.compactMap { if case .title(let h) = $0.kind { return h } else { return nil } }
            ).sorted(by: >)
            var lines: [String] = []
            var lastKey: String?
            var lastTextLine: Int?
            for piece in pieces {
                let trimmed = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if piece.mergePrev, let idx = lastTextLine, !trimmed.isEmpty {
                    lines[idx] = PostProcess.joinContinuation(lines[idx], trimmed) + "\n"
                    lastKey = nil
                    continue
                }
                if trimmed.count > 60 {
                    let key = String(trimmed.prefix(50))
                    if key == lastKey { continue }
                    lastKey = key
                } else {
                    lastKey = nil
                }
                switch piece.kind {
                case .title(let h):
                    let level = heights.firstIndex(of: h).map { min($0 + 1, 4) } ?? 2
                    lines.append(String(repeating: "#", count: level) + " " + trimmed.replacingOccurrences(of: "\n", with: " "))
                default:
                    lines.append(piece.text)
                }
                if piece.isText { lastTextLine = lines.count - 1 }
            }
            return lines.joined(separator: "\n")
        }

        static func dump(pageIndex: Int, raw: String, url: URL, options: Options) {
            guard let dir = options.dumpDirectory else { return }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? raw.write(to: dir.appendingPathComponent("layout_raw_p\(pageIndex).txt"), atomically: true, encoding: .utf8)
            let png = dir.appendingPathComponent("layout_p\(pageIndex).png")
            try? FileManager.default.removeItem(at: png)
            try? FileManager.default.copyItem(at: url, to: png)
        }
    }
}
