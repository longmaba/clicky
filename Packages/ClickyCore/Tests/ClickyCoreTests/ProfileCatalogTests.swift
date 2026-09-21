import XCTest
@testable import ClickyCore

final class ProfileCatalogTests: XCTestCase {
    private func profile(_ id: String, _ name: String, brand: String? = nil) -> SoundProfileManifest {
        SoundProfileManifest(id: id, name: name, brand: brand, samples: ["\(id).wav"])
    }

    func testBrandGroupsFollowTheUnbrandedProfilesAlphabetically() {
        let catalog = [
            profile("thocky", "Thocky"),
            profile("gateron-ink-red", "Gateron Ink Red", brand: "Gateron"),
            profile("alps-skcm-blue", "Alps SKCM Blue", brand: "Alps"),
            profile("gateron-ink-black", "Gateron Ink Black", brand: "Gateron"),
            profile("office", "Office"),
            profile("ibm-buckling-spring", "IBM Buckling Spring", brand: " IBM "),
            profile("topre-unknown", "Topre Unknown", brand: "")
        ]
        let groups = catalog.groupedByBrand()
        XCTAssertEqual(groups.map(\.title), ["Signature", "Alps", "Gateron", "IBM"])
        XCTAssertEqual(groups.map(\.isBrand), [false, true, true, true])
        // A blank brand is not a brand; catalog order survives inside a group.
        XCTAssertEqual(groups[0].profiles.map(\.id), ["thocky", "office", "topre-unknown"])
        XCTAssertEqual(groups[2].profiles.map(\.id), ["gateron-ink-red", "gateron-ink-black"])
        XCTAssertEqual(groups.flatMap(\.profiles).count, catalog.count)
    }

    func testModelNameDropsOnlyItsOwnBrandPrefix() {
        XCTAssertEqual(profile("a", "Gateron Ink Black", brand: "Gateron").modelName, "Ink Black")
        XCTAssertEqual(profile("b", "Cream", brand: "NovelKeys").modelName, "Cream")
        XCTAssertEqual(profile("c", "Thocky").modelName, "Thocky")
    }

    func testBundledCatalogNamesABrandForEveryRecordedSwitch() throws {
        let assets = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Assets")
        let profiles = try JSONDecoder().decode([SoundProfileManifest].self,
                                                from: Data(contentsOf: assets.appendingPathComponent("profiles.json")))
        let lock = try JSONSerialization.jsonObject(with: Data(contentsOf: assets.appendingPathComponent("thock-sources.json")))
        let entries = ((lock as? [String: Any])?["profiles"] as? [[String: Any]]) ?? []
        XCTAssertFalse(entries.isEmpty)
        for entry in entries {
            let id = entry["id"] as? String
            let brand = (entry["metadata"] as? [String: Any])?["brand"] as? String
            XCTAssertEqual(profiles.first { $0.id == id }?.brand, brand, "Brand missing or stale for \(id ?? "?")")
        }
        let recorded = Set(entries.compactMap { $0["id"] as? String })
        for profile in profiles where !recorded.contains(profile.id) {
            XCTAssertNil(profile.brand, "Unexpected brand on original profile \(profile.id)")
        }
    }
}
