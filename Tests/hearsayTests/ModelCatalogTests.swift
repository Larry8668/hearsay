import XCTest
@testable import hearsay

final class ModelCatalogTests: XCTestCase {
    private let best = ModelCatalog.speech[0], small = ModelCatalog.speech[1]

    func testChooserShowsOnlyWhenSomethingWantedIsMissing() {
        // Fresh install: nothing on disk.
        XCTAssertTrue(ModelCatalog.needsChooser(speechOnDisk: false, speakersWanted: true, speakerOnDisk: false, firstRun: true, chosen: false))
        // Reinstall or upgrade with both models on disk: skipped, nothing to download.
        XCTAssertFalse(ModelCatalog.needsChooser(speechOnDisk: true, speakersWanted: true, speakerOnDisk: true, firstRun: true, chosen: false))
        // Existing user (welcome already shown) with the speech model: no change, even without the speaker model.
        XCTAssertFalse(ModelCatalog.needsChooser(speechOnDisk: true, speakersWanted: true, speakerOnDisk: false, firstRun: false, chosen: false))
        // First run with the speech model on disk but speakers wanted and missing: ask about the speaker model.
        XCTAssertTrue(ModelCatalog.needsChooser(speechOnDisk: true, speakersWanted: true, speakerOnDisk: false, firstRun: true, chosen: false))
        XCTAssertFalse(ModelCatalog.needsChooser(speechOnDisk: true, speakersWanted: false, speakerOnDisk: false, firstRun: true, chosen: false))
        // Already chosen (download under way, or relaunched mid-download): resume, don't ask again.
        XCTAssertFalse(ModelCatalog.needsChooser(speechOnDisk: false, speakersWanted: true, speakerOnDisk: false, firstRun: true, chosen: true))
        // Existing user whose speech model is gone gets the choice back.
        XCTAssertTrue(ModelCatalog.needsChooser(speechOnDisk: false, speakersWanted: false, speakerOnDisk: false, firstRun: false, chosen: false))
    }

    func testTotalSize() {
        let all = ModelCatalog.bytesToDownload(speech: best, speaker: .sortformer, speechOnDisk: false, speakerOnDisk: false)
        XCTAssertEqual(all, 814_000_000)
        XCTAssertEqual(ModelCatalog.totalText(bytes: all), "Downloads about 814 MB, stays on this Mac")
        XCTAssertEqual(ModelCatalog.bytesToDownload(speech: small, speaker: .lseend, speechOnDisk: false, speakerOnDisk: false), 257_000_000)
        XCTAssertEqual(ModelCatalog.bytesToDownload(speech: best, speaker: .off, speechOnDisk: false, speakerOnDisk: false), 580_000_000)
        // Present models are never counted, and so never fetched.
        XCTAssertEqual(ModelCatalog.bytesToDownload(speech: best, speaker: .sortformer, speechOnDisk: true, speakerOnDisk: false), 234_000_000)
        XCTAssertEqual(ModelCatalog.bytesToDownload(speech: best, speaker: .sortformer, speechOnDisk: true, speakerOnDisk: true), 0)
        XCTAssertEqual(ModelCatalog.totalText(bytes: 0), "Everything you picked is already on this Mac")
        XCTAssertEqual(ModelCatalog.sizeText(1_200_000_000), "1.2 GB")
    }

    func testDefaultsMatchEngineAndRawValues() {
        XCTAssertEqual(best.variant, ParakeetEngine.defaultVariant)
        XCTAssertEqual(small.variant.rawValue, "parakeet-eou-320ms")
        XCTAssertEqual(ModelCatalog.Speaker.models.compactMap { ModelCatalog.kind($0) }, [.sortformer, .lseend])
        XCTAssertNil(ModelCatalog.kind(.off))
    }

    func testModelsListStatus() {
        XCTAssertEqual(ModelCatalog.statusText(downloaded: true, bytes: 580_400_000, state: .ready), "Downloaded · 580 MB")
        XCTAssertEqual(ModelCatalog.statusText(downloaded: false, bytes: 0, state: nil), "Not downloaded")
        XCTAssertEqual(ModelCatalog.statusText(downloaded: false, bytes: 0, state: .downloading(fraction: 0.43)), "Downloading 43%")
        XCTAssertEqual(ModelCatalog.statusText(downloaded: false, bytes: 0, state: .paused(fraction: 0.2)), "Paused at 20%")
        XCTAssertEqual(ModelCatalog.statusText(downloaded: false, bytes: 0, state: .failed("x")), "Couldn't download")
    }

    func testModelsListButtons() {
        typealias A = ModelCatalog.RowAction
        XCTAssertEqual(ModelCatalog.rowActions(downloaded: false, busy: false, selected: false, active: false), [A.download])
        XCTAssertEqual(ModelCatalog.rowActions(downloaded: false, busy: true, selected: true, active: false), [A.cancel])
        XCTAssertEqual(ModelCatalog.rowActions(downloaded: true, busy: false, selected: false, active: false), [A.use, A.delete])
        // The model in use cannot be deleted; a selected one with speakers off can.
        XCTAssertEqual(ModelCatalog.rowActions(downloaded: true, busy: false, selected: true, active: true), [])
        XCTAssertEqual(ModelCatalog.rowActions(downloaded: true, busy: false, selected: true, active: false), [A.delete])
    }

    func testDevModelsDirectoryOverride() {
        let support = URL(fileURLWithPath: "/Users/x/Library/Application Support")
        let env = ["HEARSAY_MODELS_DIR": "/tmp/m"]
        XCTAssertEqual(ModelStore.resolveDirectory(dev: true, environment: env, appSupport: support).path, "/tmp/m")
        XCTAssertEqual(ModelStore.resolveDirectory(dev: false, environment: env, appSupport: support).path,
                       "/Users/x/Library/Application Support/hearsay/models")
        XCTAssertEqual(ModelStore.resolveDirectory(dev: true, environment: [:], appSupport: support).lastPathComponent, "models")
    }
}
