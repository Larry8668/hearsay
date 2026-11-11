import CoreML
import FluidAudio
import Foundation

/// Downloads the speech models once and hands loaded FluidAudio managers to engines.
///
/// Both engine instances (me + them) go through `shared`, so the first download is done exactly
/// once even when both call `prepare` at the same moment. Each engine still gets its OWN manager:
/// the streaming managers keep per-stream encoder caches and decoder state inside the actor, and
/// FluidAudio has no API to share `MLModel` objects between managers. The second load is cheap
/// (CoreML's compiled-model cache is warm and weights are memory-mapped from the same files).
///
/// Network policy: once a variant's files are on disk we flip `ModelHub.offlineMode` on before
/// loading, so a later load can never touch the network (no revision check, no silent
/// re-download of a "corrupt" cache). It is only turned off while a missing variant downloads.
actor ModelStore {
    static let shared = ModelStore()

    /// `~/Library/Application Support/hearsay/models/`. FluidAudio's loaders accept a root
    /// directory and append the repo's folder (e.g. `parakeet-eou-streaming/160ms`).
    nonisolated static var modelDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("hearsay/models", isDirectory: true)
    }

    nonisolated static func directory(for variant: StreamingModelVariant) -> URL {
        modelDirectory.appendingPathComponent(variant.repo.folderName, isDirectory: true)
    }

    /// True when every file the variant needs is on disk (no `.partial` leftovers).
    nonisolated static func isDownloaded(_ variant: StreamingModelVariant) -> Bool {
        let dir = directory(for: variant)
        let fm = FileManager.default
        return requiredFiles(variant).allSatisfy { name in
            let url = dir.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else { return false }
            // A compiled model is a directory; its root coremldata.bin is written last.
            return !name.hasSuffix(".mlmodelc")
                || fm.fileExists(atPath: url.appendingPathComponent("coremldata.bin").path)
        }
    }

    /// Bytes on disk for the files one variant loads, or for the whole model folder when `variant`
    /// is nil. Per-variant counts only its required files: the Unified tiers share one repo folder
    /// that holds every downloaded tier's encoder.
    nonisolated static func diskSize(_ variant: StreamingModelVariant? = nil) -> Int64 {
        guard let variant else { return allocatedSize(modelDirectory) }
        let dir = directory(for: variant)
        return requiredFiles(variant).reduce(0) { $0 + allocatedSize(dir.appendingPathComponent($1)) }
    }

    nonisolated static func allocatedSize(_ url: URL) -> Int64 {
        let key = URLResourceKey.totalFileAllocatedSizeKey
        var total = Int64((try? url.resourceValues(forKeys: [key]))?.totalFileAllocatedSize ?? 0)
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [key]) else { return total }
        for case let f as URL in e { total += Int64((try? f.resourceValues(forKeys: [key]))?.totalFileAllocatedSize ?? 0) }
        return total
    }

    /// Files FluidAudio's loaders require, mirrored from each manager's `loadModels(to:)`.
    nonisolated static func requiredFiles(_ variant: StreamingModelVariant) -> [String] {
        switch variant.engineFamily {
        case .parakeetEou:
            return Array(ModelNames.ParakeetEOU.requiredModels)
        case .nemotron:
            // NemotronEncoder.fileName is internal to FluidAudio; mirrored here.
            return ["encoder/encoder_int8.mlmodelc", ModelNames.NemotronStreaming.decoderFile,
                    ModelNames.NemotronStreaming.jointFile, ModelNames.NemotronStreaming.tokenizer]
        case .parakeetUnified:
            let f = UnifiedConfig().family
            let suffix = variant.unifiedConfig?.contextSuffix
            let encoder = suffix.map { f.streamingEncoderFile(precision: .int8, contextSuffix: $0) }
                ?? f.offlineEncoderFile(precision: .int8)
            return [encoder, f.decoderFile, f.jointDecisionFile, f.vocab]
        }
    }

    private var downloads: [StreamingModelVariant: Task<Void, Error>] = [:]

    /// Stops an in-flight download, keeping its `.partial` files: FluidAudio downloads with
    /// byte-range resume, so the next `ensureDownloaded` continues from where this one stopped.
    /// Every caller awaiting the download gets a `CancellationError`.
    func pauseDownload(_ variant: StreamingModelVariant) {
        guard let task = downloads[variant] else { return }
        Log.info(.model, "models: pausing download of \(variant.rawValue)")
        task.cancel()
    }

    /// Stops the download and deletes what it fetched so far (nothing of the variant stays on disk).
    func cancelDownload(_ variant: StreamingModelVariant) async {
        if let task = downloads[variant] {
            Log.info(.model, "models: cancelling download of \(variant.rawValue)")
            task.cancel()
            _ = try? await task.value
        }
        let dir = Self.directory(for: variant)
        if FileManager.default.fileExists(atPath: dir.path) {
            do { try FileManager.default.removeItem(at: dir) } catch { Log.warn(.model, "models: could not remove \(dir.path): \(error)") }
        }
    }
    private var spare: [StreamingModelVariant: [any StreamingAsrManager]] = [:]
    /// Diarizer downloads in flight (see Diarization/DiarizerModels.swift).
    var diarizerLoads: [DiarizerKind: Task<DiarizerWeights, Error>] = [:]

    /// Makes sure the variant is on disk, downloading it once if needed. Concurrent callers share
    /// the same download and all receive its progress.
    func ensureDownloaded(_ variant: StreamingModelVariant, progress: @escaping @Sendable (ModelState) -> Void) async throws {
        if Self.isDownloaded(variant) { progress(.ready); return }
        if let task = downloads[variant] {
            progress(.downloading(fraction: -1))
            return try await Self.awaitDownload(task)
        }
        let task = Task {
            let started = Date()
            Log.info(.model, "models: downloading \(variant.rawValue) to \(Self.modelDirectory.path)")
            ModelHub.offlineMode = false
            // Loading through the manager is the only public path that knows each family's file
            // set; the warmed-up manager is kept for the first engine that asks.
            let manager = Self.makeRawManager(variant)
            try await Self.load(manager, progress: { p in progress(.downloading(fraction: p.fractionCompleted)) })
            self.keepSpare(manager, for: variant)
            let mb = Double(Self.diskSize(variant)) / 1_048_576
            Log.info(.model, "models: \(variant.rawValue) ready, \(String(format: "%.0f", mb)) MB in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        }
        downloads[variant] = task
        defer { downloads[variant] = nil }
        try await Self.awaitDownload(task)
        progress(.ready)
    }

    /// A paused/cancelled download surfaces as `CancellationError` whatever FluidAudio threw on
    /// the way out (URLError.cancelled, a wrapped retry error), so callers can tell it from a failure.
    private static func awaitDownload(_ task: Task<Void, Error>) async throws {
        do { try await task.value } catch {
            if task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    /// A loaded, reset manager for one engine. Call `ensureDownloaded` first; this never downloads.
    func makeManager(_ variant: StreamingModelVariant) async throws -> any StreamingAsrManager {
        if var pool = spare[variant], !pool.isEmpty {
            let m = pool.removeLast()
            spare[variant] = pool
            return m
        }
        guard Self.isDownloaded(variant) else {
            throw EngineError.modelUnavailable("\(variant.rawValue) is not downloaded")
        }
        ModelHub.offlineMode = true
        let manager = Self.makeRawManager(variant)
        let t0 = Date()
        try await Self.load(manager, progress: nil)
        Log.info(.model, "models: loaded \(variant.rawValue) in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        return manager
    }

    private func keepSpare(_ m: any StreamingAsrManager, for v: StreamingModelVariant) {
        spare[v, default: []].append(m)
    }

    /// `createManager` hands Nemotron/Unified a bare `MLModelConfiguration()` (compute units
    /// `.all`), which routes their int8 encoders to the GPU at ~10x the cost. Pin CPU + ANE.
    private static func makeRawManager(_ v: StreamingModelVariant) -> any StreamingAsrManager {
        v.createManager(configuration: MLModelConfigurationUtils.defaultConfiguration(computeUnits: .cpuAndNeuralEngine))
    }

    private static func load(_ m: any StreamingAsrManager, progress: ProgressHandler?) async throws {
        let root = modelDirectory
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        switch m {
        case let m as StreamingEouAsrManager: try await m.loadModels(to: root, progressHandler: progress)
        case let m as StreamingNemotronAsrManager: try await m.loadModels(to: root, progressHandler: progress)
        case let m as StreamingUnifiedAsrManager: try await m.loadModels(to: root, progressHandler: progress)
        default: throw EngineError.modelUnavailable("unsupported manager \(type(of: m))")
        }
    }
}
