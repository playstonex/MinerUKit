//
//  ObjCBridge.swift
//  MinerUKit
//
//  Thin @objc façade so a host app can load this framework at runtime via
//  `dlopen` + the ObjC runtime (NSClassFromString / NSSelectorFromString),
//  WITHOUT statically linking MinerUKit (and therefore MLX) into the app.
//
//  WHY THIS EXISTS
//    MinerUKit's native API is pure-Swift `async throws` over value types and
//    closures, which the ObjC runtime cannot call. The host app targets
//    macOS 13 while this package declares macOS 15, so the app must NOT link
//    MinerUKit directly; it dlopen's this framework only behind
//    `#available(macOS 15,*)`.
//    This bridge converts the async API into completion-handler methods over
//    ObjC-friendly types (NSString / NSURL / NSNumber / NSError), mirroring the
//    PetalASR loader pattern already used in the app.
//
//  All methods hop to a detached Task internally; completion handlers may be
//  invoked on an arbitrary thread — the caller is responsible for dispatching
//  UI work back to the main queue.
//

import Foundation

/// Carries a non-`Sendable` ObjC callback across the detached-`Task` boundary.
/// The host's completion/progress blocks are plain ObjC closures (not
/// `@Sendable`); they are only invoked, never mutated, and the host is told it
/// may be called on any thread, so this unchecked box is safe here.
private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
}

/// ObjC-callable entry point. Resolve with `NSClassFromString("MinerUKitBridge")`
/// and instantiate with `-init`; every method is exposed to the ObjC runtime.
@objc(MinerUKitBridge)
public final class MinerUKitBridge: NSObject {

    @objc public override init() { super.init() }

    /// Lightweight liveness probe. Returns the framework's build marker so the
    /// host can confirm the dlopen'd binary matches expectations.
    @objc public static func frameworkVersion() -> String { "MinerUKit-1" }

    // MARK: - Conversion

    /// Converts a PDF to Markdown.
    ///
    /// - Parameters:
    ///   - pdfURL: Source PDF.
    ///   - modelDir: Directory holding the installed MLX model (ignored for the
    ///     flash tier). See the model-management methods below.
    ///   - tier: Raw tier value (see `tierRawValue(for:)`). `nil`/unknown → standard.
    ///   - maxPages: `0` or negative means "all pages".
    ///   - imageOutputDir: Where cropped figure images are written. `nil` → temp dir.
    ///   - progress: Per-line progress strings (may fire on any thread).
    ///   - completion: `(markdown, error)` — exactly one is non-nil.
    /// - Returns: An opaque cancellation token (`NSObject` wrapping the `Task`);
    ///   call `-cancel` on it to stop the conversion.
    @discardableResult
    @objc public func convertPDF(
        _ pdfURL: NSURL,
        modelDir: NSURL,
        tier: NSString?,
        maxPages: Int,
        imageOutputDir: NSURL?,
        progress: ((NSString) -> Void)?,
        completion: @escaping (NSString?, NSError?) -> Void
    ) -> MinerUKitCancellationToken {
        let pdf = pdfURL as URL
        let dir = modelDir as URL
        let imageDir = imageOutputDir as URL?
        let resolvedTier = Self.tier(from: tier as String?)
        let maxPagesOpt: Int? = maxPages > 0 ? maxPages : nil

        let progressBox = UncheckedBox(value: progress)
        let completionBox = UncheckedBox(value: completion)
        let task = Task.detached {
            let completion = completionBox.value
            do {
                var options = MinerUKit.Options.standard
                options.tier = resolvedTier
                options.maxPages = maxPagesOpt
                options.imageOutputDirectory = imageDir
                let markdown = try await MinerUKit.convert(
                    pdfURL: pdf, modelDir: dir, options: options
                ) { line in progressBox.value?(line as NSString) }
                completion(markdown as NSString, nil)
            } catch is CancellationError {
                completion(nil, NSError(domain: "MinerUKit", code: -999,
                    userInfo: [NSLocalizedDescriptionKey: "cancelled"]))
            } catch {
                completion(nil, error as NSError)
            }
        }
        return MinerUKitCancellationToken(task)
    }

    private static func tier(from raw: String?) -> Tier {
        switch raw?.lowercased() {
        case "flash": return .flash
        case "basic": return .basic
        case "advanced": return .advanced
        case "standard", nil: return .standard
        default: return .standard
        }
    }

    // MARK: - Model management

    /// Downloads the recommended MinerU model into `directory`.
    ///
    /// - Parameters:
    ///   - repo: HF/ModelScope repo address. `nil` → the recommended default.
    ///   - token: HF access token (the default repo is gated). May be `nil`.
    ///   - progress: `(fileIndex, fileCount, totalBytes, grandTotal, bytesPerSecond)`.
    ///   - completion: `(installedURL, error)`.
    @discardableResult
    @objc public func downloadModel(
        toDirectory directory: NSURL,
        repo: NSString?,
        token: NSString?,
        progress: ((Int, Int, Int64, Int64, Double) -> Void)?,
        completion: @escaping (NSURL?, NSError?) -> Void
    ) -> MinerUKitCancellationToken {
        let dir = directory as URL
        let repoStr = repo as String?
        let tokenStr = token as String?

        let progressBox = UncheckedBox(value: progress)
        let completionBox = UncheckedBox(value: completion)
        let task = Task.detached {
            let completion = completionBox.value
            do {
                let source: ModelStore.Source
                if let repoStr, !repoStr.isEmpty {
                    source = try ModelStore.Source.parse(repoStr, token: tokenStr)
                } else {
                    source = ModelStore.recommended.with(token: tokenStr)
                }
                let url = try await ModelStore.download(source, to: dir) { p in
                    progressBox.value?(p.fileIndex, p.fileCount, p.totalBytes, p.grandTotal, p.bytesPerSecond)
                }
                completion(url as NSURL, nil)
            } catch is CancellationError {
                completion(nil, NSError(domain: "MinerUKit", code: -999,
                    userInfo: [NSLocalizedDescriptionKey: "cancelled"]))
            } catch {
                completion(nil, error as NSError)
            }
        }
        return MinerUKitCancellationToken(task)
    }

    /// Install state of a model directory: 0 = notInstalled, 1 = partial, 2 = complete.
    @objc public func installState(atDirectory directory: NSURL) -> Int {
        switch ModelStore.installState(at: directory as URL) {
        case .notInstalled: return 0
        case .partial: return 1
        case .complete: return 2
        }
    }

    /// Total bytes used by a model directory (recursive). `0` when missing.
    @objc public func diskUsage(atDirectory directory: NSURL) -> Int64 {
        ModelStore.diskUsage(at: directory as URL)
    }

    /// Scans `root` for installed models. Returns one dictionary per model with
    /// keys: `directory` (NSString path), `state` (NSNumber 0/1/2),
    /// `diskUsage` (NSNumber Int64), `repo` (NSString, optional),
    /// `revision` (NSString, optional).
    @objc public func installedModels(inRoot root: NSURL) -> [[String: Any]] {
        ModelStore.installedModels(in: root as URL).map { model in
            var dict: [String: Any] = [
                "directory": model.directory.path,
                "state": NSNumber(value: {
                    switch model.state {
                    case .notInstalled: return 0
                    case .partial: return 1
                    case .complete: return 2
                    }
                }() as Int),
                "diskUsage": NSNumber(value: model.diskUsage),
            ]
            if let manifest = model.manifest {
                dict["repo"] = manifest.repo
                dict["revision"] = manifest.revision
            }
            return dict
        }
    }

    /// Deletes an installed model directory and everything under it.
    /// Returns `nil` on success or an `NSError` describing the failure.
    @objc public func removeModel(atDirectory directory: NSURL) -> NSError? {
        do {
            try ModelStore.remove(at: directory as URL)
            return nil
        } catch {
            return error as NSError
        }
    }

    /// URL of the page where the gated default repo's access is requested.
    @objc public static func recommendedModelPage() -> NSURL {
        ModelStore.recommendedPage as NSURL
    }

    /// Repo id of the recommended default model.
    @objc public static func recommendedModelRepo() -> NSString {
        ModelStore.recommended.repo as NSString
    }

    /// Human-readable byte formatter matching the download progress units.
    @objc public static func formatBytes(_ bytes: Int64) -> NSString {
        ModelStore.Progress.formatBytes(bytes) as NSString
    }
}

/// Opaque cancellation handle returned by the long-running bridge methods.
@objc(MinerUKitCancellationToken)
public final class MinerUKitCancellationToken: NSObject {
    private let task: Task<Void, Never>
    init(_ task: Task<Void, Never>) { self.task = task }
    @objc public func cancel() { task.cancel() }
}
