import Foundation

/// Trims provider account identifiers so equivalent IDs and emails compare equal.
public enum ProviderIdentityNormalizer {
    public static func normalizeEmail(_ email: String?) -> String? {
        guard let email = email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty else {
            return nil
        }
        return email.lowercased()
    }

    public static func normalizeAccountID(_ accountId: String?) -> String? {
        guard let accountId = accountId?.trimmingCharacters(in: .whitespacesAndNewlines), !accountId.isEmpty else {
            return nil
        }
        return accountId
    }
}
