import BarsCore
import Foundation

extension UsageStore {
    /// Rolls every published window whose reset time has passed over to fresh usage, then waits for the next reset.
    /// The menu, icon, and widgets stop showing an ended window's percentages at the reset itself, before a refresh
    /// answers, and still do when that refresh fails or is held back.
    func rollOverResetWindows(now: Date = Date()) {
        var changed = false
        for (id, snapshot) in self.snapshots {
            guard let reset = snapshot.earliestRolloverReset, reset <= now else { continue }
            self.snapshots[id] = snapshot.rollingOverResetWindows(at: now)
            changed = true
        }
        if changed {
            self.persistWidgetSnapshot(reason: "reset-rollover")
        }
        self.scheduleResetRollover()
    }

    /// Wakes at the earliest reset among the published snapshots; a reset that has already passed, such as one in a
    /// restored snapshot, rolls over right away. Runs whenever `snapshots` changes.
    func scheduleResetRollover() {
        let nextReset = self.snapshots.values.compactMap(\.earliestRolloverReset).min()
        guard nextReset != self.scheduledResetRolloverAt else { return }
        self.resetRolloverTask?.cancel()
        self.resetRolloverTask = nil
        self.scheduledResetRolloverAt = nextReset
        guard let nextReset else { return }
        self.resetRolloverTask = Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, nextReset.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            await self?.runResetRollover()
        }
    }

    private func runResetRollover() {
        // Checked again on the main actor: a newer schedule may have cancelled this wake after its sleep ended.
        guard !Task.isCancelled else { return }
        self.resetRolloverTask = nil
        self.scheduledResetRolloverAt = nil
        self.rollOverResetWindows()
    }
}
