import Foundation

/// A configured music account. The secret token lives in the Keychain under a
/// per-account key, never in this struct or in UserDefaults.
struct Account: Codable, Identifiable, Hashable {
    let id: String          // UUID
    var kind: ProviderKind
    var name: String        // user-facing label
}

/// Persists the list of accounts (UserDefaults) and their tokens (Keychain,
/// one key per account). Supports several accounts across provider kinds.
final class AccountStore {
    static let shared = AccountStore()

    private let listKey = "spectra.accounts.v1"
    private let activeKey = "spectra.activeAccount.v1"

    private(set) var accounts: [Account] = []

    private init() { load() }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: listKey),
           let decoded = try? JSONDecoder().decode([Account].self, from: data) {
            accounts = decoded
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: listKey)
        }
    }

    var activeID: String? {
        get { UserDefaults.standard.string(forKey: activeKey) }
        set { UserDefaults.standard.set(newValue, forKey: activeKey) }
    }

    var activeAccount: Account? {
        guard let id = activeID else { return accounts.first }
        return accounts.first { $0.id == id } ?? accounts.first
    }

    func add(_ account: Account, token: String) {
        accounts.removeAll { $0.id == account.id }
        accounts.append(account)
        Keychain.set(token, account: tokenKey(account.id))
        persist()
    }

    func remove(_ id: String) {
        accounts.removeAll { $0.id == id }
        Keychain.delete(account: tokenKey(id))
        if activeID == id { activeID = accounts.first?.id }
        persist()
    }

    func token(for id: String) -> String? { Keychain.get(account: tokenKey(id)) }

    private func tokenKey(_ id: String) -> String { "account.\(id)" }

    /// One-time migration of the pre-multi-account single Plex token into an
    /// account entry, so existing users keep their sign-in.
    func migrateLegacyIfNeeded(legacyAccount: String) {
        guard accounts.isEmpty, let token = Keychain.get(account: legacyAccount) else { return }
        let account = Account(id: UUID().uuidString, kind: .plex, name: "Plex")
        add(account, token: token)
        activeID = account.id
        Keychain.delete(account: legacyAccount)
    }
}
