import XCTest
import SwiftUI
@testable import OpenUsage

@MainActor
final class XPassPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_872_000)
    private var reset: Date { now.addingTimeInterval(86_400) }

    private func snapshots(unified: Bool = true, cursorUsed: Double = 24, grokUsed: Double = 24, grokResetOffset: Double = 0) -> [String: ProviderSnapshot] {
        [
            "cursor": ProviderSnapshot(
                providerID: "cursor", displayName: "Cursor", plan: "Super",
                lines: [.progress(label: "Total usage", used: cursorUsed, limit: 100, format: .percent,
                                  resetsAt: reset, periodDurationMs: MetricPeriod.weekMs)],
                refreshedAt: now, isUnifiedSubscription: unified
            ),
            "grok": ProviderSnapshot(
                providerID: "grok", displayName: "Grok",
                lines: [.progress(label: "Weekly limit", used: grokUsed, limit: 100, format: .percent,
                                  resetsAt: reset.addingTimeInterval(grokResetOffset), periodDurationMs: MetricPeriod.weekMs)],
                refreshedAt: now
            )
        ]
    }

    private func groups() -> [ProviderGroup] {
        [
            ProviderGroup(provider: CursorProvider().provider,
                          alwaysShownWidgets: ["cursor.usage", "cursor.auto", "cursor.api"].map { PlacedWidget(descriptorID: $0) },
                          expandedWidgets: ["cursor.grokBot", "cursor.today"].map { PlacedWidget(descriptorID: $0) }),
            ProviderGroup(provider: GrokProvider().provider,
                          alwaysShownWidgets: [PlacedWidget(descriptorID: "grok.weekly")],
                          expandedWidgets: ["grok.payAsYouGo", "grok.today"].map { PlacedWidget(descriptorID: $0) })
        ]
    }

    func testUnifiedMatchingPoolShowsOneBrandedCardAndKeepsSourceSpendPlacement() {
        let source = groups()
        let presentation = XPassPresentation(snapshots: snapshots(), now: now)
        let result = presentation.groups(source)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].provider.displayName, "XPass")
        XCTAssertEqual(result[0].provider.icon, .providerMark("xai"))
        XCTAssertEqual(result[0].alwaysShownWidgets.map(\.descriptorID), ["cursor.usage"])
        XCTAssertEqual(result[0].expandedWidgets.map(\.descriptorID), ["cursor.today", "grok.today"])
        XCTAssertEqual(result[0].expandedWidgets.map(\.id), [source[0].expandedWidgets[1].id, source[1].expandedWidgets[1].id])
        XCTAssertEqual(source[0].widgets.count, 5, "Presentation must not mutate persisted choices")
    }

    func testWholePercentGrokReadingMatchesCursorsFractionalWeeklyBucket() {
        let presentation = XPassPresentation(snapshots: snapshots(cursorUsed: 24.62, grokUsed: 24), now: now)
        XCTAssertEqual(presentation.groups(groups()).count, 1)
        let differentBucket = XPassPresentation(snapshots: snapshots(cursorUsed: 24.62, grokUsed: 23), now: now)
        XCTAssertEqual(differentBucket.groups(groups()).count, 2)
    }

    func testLegacyAndUnmatchedPoolsKeepSeparateQuotas() {
        for input in [snapshots(unified: false), snapshots(grokUsed: 50), snapshots(grokResetOffset: 3_600)] {
            let result = XPassPresentation(snapshots: input, now: now).groups(groups())
            XCTAssertEqual(result.count, 2)
            XCTAssertTrue(result[1].widgets.contains { $0.descriptorID == "grok.weekly" })
        }
        let legacy = XPassPresentation(snapshots: snapshots(unified: false), now: now).groups(groups())
        XCTAssertEqual(legacy[0].provider.displayName, "Cursor")
        XCTAssertTrue(legacy[0].widgets.contains { $0.descriptorID == "cursor.auto" })
    }

    func testDisabledCursorStaleReadingAndSourceFailureDoNotHideGrok() {
        let input = snapshots()
        XCTAssertEqual(XPassPresentation(snapshots: input, now: now).groups([groups()[1]]).first?.provider.id, "grok")
        for presentation in [
            XPassPresentation(snapshots: input, now: now.addingTimeInterval(WidgetDataStore.stalenessThreshold + 1)),
            XPassPresentation(snapshots: input, errors: ["grok": "Session expired"], now: now)
        ] {
            XCTAssertEqual(presentation.groups(groups()).count, 2)
        }
    }

    func testSourceSpendLabelsAndExportKeepIndependentReadings() async throws {
        let cursor = CursorProvider()
        let grok = GrokProvider()
        var input = snapshots()
        input["cursor"]?.lines.append(.values(label: "Today", values: [
            MetricValue(number: 1.2, kind: .dollars), MetricValue(number: 80_000, kind: .count, label: "tokens")
        ]))
        input["grok"]?.lines.append(.values(label: "Today", values: [
            MetricValue(number: 2.3, kind: .dollars, estimated: true), MetricValue(number: 160_000, kind: .count, label: "tokens")
        ]))
        let registry = WidgetRegistry.from([cursor, grok])
        let suite = "OpenUsageTests.XPass.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sources: [ProviderRuntime] = [cursor, grok]
        let runtimes = sources.map { runtime in
            TestProviderRuntime(provider: runtime.provider, descriptors: runtime.widgetDescriptors,
                                snapshot: input[runtime.provider.id]!)
        }
        let store = WidgetDataStore(registry: registry, providers: runtimes,
                                   cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots"), defaults: defaults)
        await store.refreshAll()
        let group = try XCTUnwrap(XPassPresentation(snapshots: store.snapshots, now: now).groups(groups()).first)
        let rows = try group.widgets.map { widget in
            store.data(for: try XCTUnwrap(registry.descriptor(id: widget.descriptorID)), in: group.provider)
        }
        XCTAssertEqual(rows.map(\.title), ["Weekly", "Cursor Today", "Grok Today"])
        XCTAssertEqual(rows[1].values.first?.number, 1.2)
        XCTAssertEqual(rows[2].values.first?.number, 2.3)
        XCTAssertNotNil(ProviderMarks.mark(for: "xai"), "The XPass mark must render from the bundled SVG")

        // Optional, reproducible UI artifact using synthetic values and the actual shared card view.
        if let directory = ProcessInfo.processInfo.environment["OPENUSAGE_XPASS_PREVIEW_DIR"] {
            for (name, appearance) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
                let view = ShareCardView(provider: group.provider, plan: store.plan(for: "cursor"), rows: rows,
                                         appearance: appearance, expandBoundaryIndex: group.alwaysShownWidgets.count)
                let image = try XCTUnwrap(ShareCardRenderer.image(for: view))
                let png = try XCTUnwrap(ShareCardRenderer.pngData(from: image))
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("xpass-\(name).png"))
                for source in groups() {
                    let originalRows = try source.widgets.map { widget in
                        store.data(for: try XCTUnwrap(registry.descriptor(id: widget.descriptorID)))
                    }
                    let originalView = ShareCardView(provider: source.provider, plan: store.plan(for: source.provider.id),
                                                     rows: originalRows, appearance: appearance,
                                                     expandBoundaryIndex: source.alwaysShownWidgets.count)
                    let originalImage = try XCTUnwrap(ShareCardRenderer.image(for: originalView))
                    let originalPNG = try XCTUnwrap(ShareCardRenderer.pngData(from: originalImage))
                    let filename = "xpass-before-\(source.provider.id)-\(name).png"
                    try originalPNG.write(to: URL(fileURLWithPath: directory).appendingPathComponent(filename))
                }
            }
        }
    }

    func testObsoleteCursorPinsResolveToOneWeeklyPinWithoutChangingSavedPins() throws {
        let cursor = CursorProvider()
        let pins = cursor.widgetDescriptors.filter { ["cursor.auto", "cursor.api"].contains($0.id) }
        let input = [ProviderMetrics(provider: cursor.provider, metrics: pins)]
        let registry = WidgetRegistry.from([cursor])
        let result = XPassPresentation(snapshots: snapshots(), now: now).pinnedGroups(input, registry: registry)

        XCTAssertEqual(result.first?.provider.displayName, "XPass")
        XCTAssertEqual(result.first?.metrics.map(\.id), ["cursor.usage"])
        XCTAssertEqual(input[0].metrics.map(\.id), ["cursor.auto", "cursor.api"])
    }
}
