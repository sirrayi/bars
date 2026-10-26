import CodexBarCore

extension UsageStore {
    func limitResetAccountIdentifier(
        provider: UsageProvider,
        account: ProviderTokenAccount?,
        snapshot: UsageSnapshot,
        accountKey: String?) -> String?
    {
        let identity = snapshot.identity(for: provider.instanceID)
        return account?.id.uuidString.lowercased()
            ?? accountKey
            ?? identity?.accountEmail
            ?? identity?.accountOrganization
            ?? provider.rawValue
    }

    func limitResetAccountLabel(
        provider: UsageProvider,
        account: ProviderTokenAccount?,
        snapshot: UsageSnapshot) -> String?
    {
        let identity = snapshot.identity(for: provider.instanceID)
        return account?.label
            ?? identity?.accountEmail
            ?? identity?.accountOrganization
    }
}
