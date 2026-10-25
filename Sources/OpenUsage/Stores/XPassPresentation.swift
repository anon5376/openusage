import Foundation

/// Combines unified-billing display when the source quota readings match. Source runtimes, histories, API IDs and saved
/// customization remain independent; this projection never adds the two allowance readings together.
@MainActor
struct XPassPresentation {
    let snapshots: [String: ProviderSnapshot]
    var errors: [String: String] = [:]
    var now: Date = Date()

    private let obsoleteCursorIDs: Set<String> = ["cursor.auto", "cursor.api", "cursor.grokBot"]
    private let obsoleteGrokIDs: Set<String> = ["grok.weekly", "grok.payAsYouGo"]

    private var isUnifiedCursor: Bool { snapshots["cursor"]?.isUnifiedSubscription == true }

    /// Matching current readings are required before hiding Grok's quota. A stale cache, failed
    /// source, different reset or different percentage keeps its own card. This does not link accounts.
    var combinesGrok: Bool {
        guard isUnifiedCursor, errors["cursor"] == nil, errors["grok"] == nil,
              let cursor = snapshots["cursor"], let grok = snapshots["grok"],
              abs(now.timeIntervalSince(cursor.refreshedAt)) < WidgetDataStore.stalenessThreshold,
              abs(now.timeIntervalSince(grok.refreshedAt)) < WidgetDataStore.stalenessThreshold,
              let left = pool(cursor, label: "Total usage"), let right = pool(grok, label: "Weekly limit")
        else { return false }
        // Grok's billing response can truncate to a whole percent while Cursor keeps fractions.
        let sameUsage = abs(left.used - right.used) < 0.01
            || (right.used.rounded(.towardZero) == right.used && left.used.rounded(.towardZero) == right.used)
        return sameUsage && abs(left.reset.timeIntervalSince(right.reset)) < 1
    }

    private func pool(_ snapshot: ProviderSnapshot, label: String) -> (used: Double, reset: Date)? {
        guard snapshot.errorCategory == nil,
              case .progress(_, let used, let limit, .percent, let reset?, let period, _) = snapshot.line(label: label),
              used.isFinite, limit == 100, period == MetricPeriod.weekMs, reset > now
        else { return nil }
        return (used, reset)
    }

    func provider(_ source: Provider) -> Provider {
        guard source.id == "cursor", isUnifiedCursor else { return source }
        return xPassProvider(source)
    }

    private func xPassProvider(_ source: Provider) -> Provider {
        Provider(id: source.id, displayName: "XPass", icon: .providerMark("xai"), links: [
            .init(label: "Usage", url: "https://grok.com/dashboard"),
            .init(label: "Cursor Dashboard", url: "https://www.cursor.com/dashboard")
        ])
    }

    func groups(_ source: [ProviderGroup]) -> [ProviderGroup] {
        guard isUnifiedCursor, let cursor = source.first(where: { $0.provider.id == "cursor" }) else { return source }
        let grok = combinesGrok ? source.first(where: { $0.provider.id == "grok" }) : nil
        let hasWeekly = cursor.widgets.contains { $0.descriptorID == "cursor.usage" }
        var included = Set<String>()
        func cursorWidgets(_ widgets: [PlacedWidget]) -> [PlacedWidget] {
            widgets.compactMap { widget in
                let obsolete = obsoleteCursorIDs.contains(widget.descriptorID)
                if obsolete && hasWeekly { return nil }
                let id = obsolete ? "cursor.usage" : widget.descriptorID
                guard included.insert(id).inserted else { return nil }
                return PlacedWidget(id: widget.id, descriptorID: id)
            }
        }
        var always = cursorWidgets(cursor.alwaysShownWidgets)
        var expanded = cursorWidgets(cursor.expandedWidgets)
        if let grok {
            always += grok.alwaysShownWidgets.filter { !obsoleteGrokIDs.contains($0.descriptorID) }
            expanded += grok.expandedWidgets.filter { !obsoleteGrokIDs.contains($0.descriptorID) }
        }
        if always.isEmpty { always = expanded; expanded = [] }
        let combined = ProviderGroup(provider: provider(cursor.provider), alwaysShownWidgets: always, expandedWidgets: expanded)
        return source.compactMap { group in
            if group.provider.id == "cursor" { return combined }
            if group.provider.id == "grok", grok != nil { return nil }
            return group
        }
    }

    /// Remap the old split-pool pins in memory so an upgraded unified account has one real weekly
    /// value instead of two dead pins. Stored pins are untouched, including for a later legacy login.
    func pinnedGroups(_ source: [ProviderMetrics], registry: WidgetRegistry) -> [ProviderMetrics] {
        guard isUnifiedCursor else { return source }
        let cursor = source.first { $0.provider.id == "cursor" }
        let grok = combinesGrok ? source.first { $0.provider.id == "grok" } : nil
        var seen = Set<String>()
        func metrics(_ descriptors: [WidgetDescriptor]) -> [WidgetDescriptor] {
            descriptors.compactMap { descriptor in
                let resolved = obsoleteCursorIDs.contains(descriptor.id)
                    ? registry.descriptor(id: "cursor.usage") : descriptor
                guard let resolved, seen.insert(resolved.id).inserted else { return nil }
                return resolved
            }
        }
        var combined = cursor.map { metrics($0.metrics) } ?? []
        if let grok, cursor != nil {
            combined += metrics(grok.metrics.filter { !obsoleteGrokIDs.contains($0.id) })
        }
        return source.compactMap { group in
            if group.provider.id == "cursor" {
                return ProviderMetrics(provider: provider(group.provider), metrics: Array(combined.prefix(LayoutStore.maxPinsPerProvider)))
            }
            if group.provider.id == "grok", grok != nil {
                if cursor != nil { return nil }
                return ProviderMetrics(provider: xPassProvider(group.provider), metrics: group.metrics.filter { $0.id != "grok.payAsYouGo" })
            }
            return group
        }
    }

    func sourceIDs(for group: ProviderGroup) -> [String] {
        group.provider.id == "cursor" && combinesGrok ? ["cursor", "grok"] : [group.provider.id]
    }
}

extension WidgetDataStore {
    var xPassPresentation: XPassPresentation { XPassPresentation(snapshots: snapshots, errors: providerErrors) }
}
