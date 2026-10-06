import Foundation

/// Parsing tiers, mirroring MinerU 4.0's quality ladder.
///
/// | tier       | pages with a text layer          | pages without (scans)   | model |
/// |------------|----------------------------------|-------------------------|-------|
/// | flash      | native text extraction           | placeholder notice      | none  |
/// | basic      | native text extraction           | VLM two-stage fallback  | on demand |
/// | standard   | VLM two-stage (layout + region)  | same                    | all pages (default) |
/// | advanced   | same as standard, higher-fidelity| same                    | all pages, 288 dpi |
public enum Tier: String, Sendable, CaseIterable, Codable {
    case flash
    case basic
    case standard
    case advanced

    /// True when this tier ever needs the VLM (and thus a model directory).
    public var usesModel: Bool {
        switch self {
        case .flash: return false
        case .basic, .standard, .advanced: return true
        }
    }

    /// Raster scale for the VLM stages. `advanced` renders at 288 dpi.
    public var renderScale: CGFloat {
        switch self {
        case .advanced: return 4.0
        default: return 3.0
        }
    }

    /// Token budget for region recognition.
    public var recognitionMaxTokens: Int {
        switch self {
        case .advanced: return 2200
        default: return 1500
        }
    }

    public var describe: String {
        switch self {
        case .flash: return "flash: native text layer only, no model"
        case .basic: return "basic: native text first, VLM for scanned pages"
        case .standard: return "standard: VLM two-stage on every page"
        case .advanced: return "advanced: VLM two-stage at 288 dpi"
        }
    }
}
