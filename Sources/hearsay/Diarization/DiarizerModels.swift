import CoreML
import FluidAudio
import Foundation

/// Loaded diarizer weights. One set serves every instance of a session: `MLModel` predictions
/// are thread-safe, Sortformer keeps its streaming state in the diarizer object, and LS-EEND's
/// recurrent state lives in each diarizer's input tensors.
enum DiarizerWeights: @unchecked Sendable {
    case sortformer(SortformerModels)
    case lseend(LSEENDModel)
}

/// Diarizer models live next to the speech models (`~/Library/Application Support/hearsay/
/// models/<repo folder>`) and follow the same offline policy: once on disk, loads never touch
/// the network. The download is one cancellable `Task` shared by concurrent callers.
extension ModelStore {
    nonisolated static func directory(for kind: DiarizerKind) -> URL {
        modelDirectory.appendingPathComponent(repo(for: kind).folderName, isDirectory: true)
    }

    private nonisolated static func repo(for kind: DiarizerKind) -> Repo {
        kind == .sortformer ? .sortformer : kind.lseendVariant.repo
    }

    /// Compiled-model bundle paths inside the repo folder, as FluidAudio's loaders name them.
    nonisolated static func requiredFiles(_ kind: DiarizerKind) -> [String] {
        switch kind {
        case .sortformer:
            return [ModelNames.Sortformer.bundle(for: kind.sortformerConfig) ?? ModelNames.Sortformer.defaultBundle]
        case .lseend, .lseendAmi:
            // FluidAudio nests the HuggingFace subdirectory ("optimized/dih3") under the repo folder.
            let repo = kind.lseendVariant.repo
            return [(repo.subPath.map { "\($0)/" } ?? "") + kind.lseendVariant.fileName(forStep: kind.lseendStep)]
        }
    }

    nonisolated static func isDownloaded(_ kind: DiarizerKind) -> Bool {
        let dir = directory(for: kind)
        let fm = FileManager.default
        return requiredFiles(kind).allSatisfy { name in
            let url = dir.appendingPathComponent(name)
            // Weights are written before the root coremldata.bin; a leftover .partial means an
            // interrupted download that FluidAudio will resume.
            return fm.fileExists(atPath: url.appendingPathComponent("coremldata.bin").path)
                && !(fm.enumerator(at: url, includingPropertiesForKeys: nil)?
                    .contains { ($0 as? URL)?.pathExtension == "partial" } ?? false)
        }
    }

    nonisolated static func diskSize(_ kind: DiarizerKind) -> Int64 {
        let dir = directory(for: kind)
        return requiredFiles(kind).reduce(0) { $0 + allocatedSize(dir.appendingPathComponent($1)) }
    }

    /// Downloads the model once if needed and loads it. Concurrent callers share one task and
    /// all receive its progress; cancelling every caller cancels the download (FluidAudio keeps
    /// the partial files for a resume).
    func loadDiarizer(_ kind: DiarizerKind, progress: @escaping @Sendable (ModelState) -> Void) async throws -> DiarizerWeights {
        if let task = diarizerLoads[kind] {
            progress(.downloading(fraction: -1))
            let w = try await task.value
            progress(.ready)
            return w
        }
        let downloaded = Self.isDownloaded(kind)
        let task = Task {
            let started = Date()
            if downloaded {
                ModelHub.offlineMode = true
            } else {
                Log.info("diarizer: downloading \(kind.rawValue) to \(Self.directory(for: kind).path)")
                ModelHub.offlineMode = false
                progress(.downloading(fraction: 0))
            }
            let report: ProgressHandler = { p in
                if !downloaded { progress(.downloading(fraction: p.fractionCompleted)) }
            }
            let weights: DiarizerWeights
            switch kind {
            case .sortformer:
                // GPU routing is ~10x the cost for these int8/fp16 heads (see ModelStore); pin CPU + ANE.
                let m = try await SortformerModels.loadFromHuggingFace(
                    config: kind.sortformerConfig, cacheDirectory: Self.modelDirectory,
                    computeUnits: .cpuAndNeuralEngine, progressHandler: report)
                weights = .sortformer(m)
            case .lseend, .lseendAmi:
                // FluidAudio: LS-EEND is fastest on the CPU; its ANE build is slower.
                let m = try await LSEENDModel.loadFromHuggingFace(
                    variant: kind.lseendVariant, stepSize: kind.lseendStep, cacheDirectory: Self.modelDirectory,
                    computeUnits: .cpuOnly, progressHandler: report)
                weights = .lseend(m)
            }
            let mb = Double(Self.diskSize(kind)) / 1_048_576
            Log.info("diarizer: \(kind.rawValue) \(downloaded ? "loaded" : "ready") (\(String(format: "%.0f", mb)) MB) in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
            return weights
        }
        diarizerLoads[kind] = task
        defer { diarizerLoads[kind] = nil }
        do {
            let w = try await task.value
            progress(.ready)
            return w
        } catch {
            Log.error("diarizer: \(kind.rawValue) load failed: \(error.localizedDescription)")
            progress(.failed(error.localizedDescription))
            throw error
        }
    }

    /// A fresh diarizer instance (own streaming state and speaker slots) on shared weights.
    nonisolated static func makeDiarizer(_ kind: DiarizerKind, weights: DiarizerWeights) throws -> FluidDiarizer {
        switch weights {
        case .sortformer(let models):
            var timeline = DiarizerTimelineConfig.sortformerDefault
            timeline.maxStoredFrames = 4096   // we consume raw frames; the timeline's own history is unused
            let d = SortformerDiarizer(config: kind.sortformerConfig, timelineConfig: timeline)
            d.initialize(models: models)
            return FluidDiarizer(kind: kind, model: d)
        case .lseend(let model):
            let d = try LSEENDDiarizer(model: model)
            return FluidDiarizer(kind: kind, model: d)
        }
    }
}
