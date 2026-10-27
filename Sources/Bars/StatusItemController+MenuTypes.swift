import AppKit
import BarsCore
import SwiftUI

extension StatusItemController {
    var selectedMenuProvider: ProviderInstanceID? {
        get { self.settings.selectedMenuProvider }
        set { self.settings.selectedMenuProvider = newValue }
    }

    var fallbackProvider: UsageProvider? {
        self.store.enabledProviders().isEmpty && self.menuBarEligibleProviders().isEmpty ? .claude : nil
    }
}

extension ProviderSwitcherSelection {
    var provider: UsageProvider? {
        switch self {
        case .overview:
            nil
        case let .provider(instanceID):
            instanceID.firstPartyProvider
        }
    }

    var instanceID: ProviderInstanceID? {
        switch self {
        case .overview: nil
        case let .provider(instanceID): instanceID
        }
    }
}

struct OverviewMenuCardRowView: View {
    static let showsSectionDividers = false

    let model: UsageMenuCardView.Model
    let storageText: String?
    let width: CGFloat
    var layout: MergedOverviewLayout = .detailed
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if self.usesFullCard {
                UsageMenuCardView(model: self.model, width: self.width)
            } else {
                UsageMenuCardHeaderSectionView(
                    model: self.model,
                    showDivider: Self.showsSectionDividers && self.model.hasUsageContent,
                    width: self.width)
                if self.model.hasUsageContent {
                    UsageMenuCardUsageSectionView(
                        model: self.model,
                        layoutModel: self.model,
                        showBottomDivider: false,
                        bottomPadding: 6,
                        width: self.width,
                        showsSectionDividers: Self.showsSectionDividers,
                        compactMetrics: self.layout == .compact)
                }
            }
            if let storageText {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(L("Storage")):")
                        .font(.footnote)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    Text(storageText)
                        .font(.footnote)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, UsageMenuCardLayout.horizontalPadding)
                .padding(.top, self.model.hasUsageContent ? 0 : 8)
                .padding(.bottom, 6)
                .frame(width: self.width, alignment: .leading)
            }
        }
        .frame(width: self.width, alignment: .leading)
    }

    var usesFullCard: Bool {
        self.layout == .compact && self.model.metrics.isEmpty
    }
}

struct TokenAccountMenuDisplay: Equatable {
    let provider: UsageProvider
    let accounts: [ProviderTokenAccount]
    let snapshots: [TokenAccountUsageSnapshot]
    let activeIndex: Int
    let layout: MultiAccountMenuLayout

    var showAll: Bool {
        self.layout == .stacked
    }

    var showSwitcher: Bool {
        self.layout == .segmented
    }

    static func == (lhs: TokenAccountMenuDisplay, rhs: TokenAccountMenuDisplay) -> Bool {
        lhs.provider == rhs.provider &&
            lhs.accountIdentity == rhs.accountIdentity &&
            lhs.activeIndex == rhs.activeIndex &&
            lhs.layout == rhs.layout &&
            lhs.snapshotIdentity == rhs.snapshotIdentity
    }

    private var accountIdentity: [AccountIdentity] {
        self.accounts.map { account in
            AccountIdentity(
                id: account.id,
                label: account.label,
                externalIdentifier: account.externalIdentifier,
                usageScope: account.usageScope,
                organizationID: account.organizationID,
                workspaceID: account.workspaceID)
        }
    }

    private var snapshotIdentity: [SnapshotIdentity] {
        self.snapshots.map { snapshot in
            SnapshotIdentity(
                id: snapshot.id,
                hasSnapshot: snapshot.snapshot != nil,
                error: snapshot.error,
                sourceLabel: snapshot.sourceLabel)
        }
    }

    private struct AccountIdentity: Equatable {
        let id: UUID
        let label: String
        let externalIdentifier: String?
        let usageScope: String?
        let organizationID: String?
        let workspaceID: String?
    }

    private struct SnapshotIdentity: Equatable {
        let id: UUID
        let hasSnapshot: Bool
        let error: String?
        let sourceLabel: String?
    }
}
