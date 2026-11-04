import Security
import SwiftUI
import UIKit

/// Microsoft account sign-in for online-mode servers, as docs/microsoft-account.md designs it for the desktop
/// launcher: the OAuth device-code flow, then Xbox Live, XSTS, the Minecraft services, the ownership check and
/// the profile. The Azure app is Horizon's own and is configuration (`HorizonMSAClientID` in GameInfo.plist,
/// which CI fills from the repository variable HORIZON_MSA_CLIENT_ID); never another launcher's. Secrets stay in
/// the keychain, and the game gets the session in memory (`launcher-session`), never in a file or a log.
@MainActor
final class MicrosoftAccount: ObservableObject {
    struct Profile: Codable, Equatable {
        let name: String
        let uuid: String
    }

    enum State: Equatable {
        case idle
        /// The player enters `code` at `link` in a browser.
        case code(String, URL)
        case working(String)
        case failed(String)
    }

    @Published private(set) var profile: Profile?
    @Published private(set) var state = State.idle
    /// True only after the current Minecraft session was acknowledged by the engine.
    @Published private(set) var sessionReady = false
    @Published private(set) var clientConfigured = false
    private var signing: Task<Void, Never>?
    private var handoverTask: Task<Bool, Never>?
    private var generation = UUID()

    /// The public application ID belongs to this launcher, not a secret or player credential.
    static var bundledClientID: String? {
        let bundled = (Bundle.main.object(forInfoDictionaryKey: "HorizonMSAClientID") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let bundled, !bundled.hasPrefix("$(") else { return nil }
        return normalizeClientID(bundled)
    }

    static var clientID: String? {
        bundledClientID ?? UserDefaults.standard.string(forKey: "horizonMicrosoftClientID")
            .flatMap(normalizeClientID)
    }

    static func normalizeClientID(_ value: String) -> String? {
        UUID(uuidString: value.trimmingCharacters(in: .whitespacesAndNewlines))?.uuidString.lowercased()
    }

    /// A developer can configure their own approved app without replacing the player's build.
    @discardableResult
    func configureClientID(_ value: String) -> Bool {
        guard profile == nil, Self.bundledClientID == nil, let id = Self.normalizeClientID(value) else {
            state = .failed("Enter the application (client) ID as a UUID, while signed out.")
            return false
        }
        UserDefaults.standard.set(id, forKey: "horizonMicrosoftClientID")
        clientConfigured = Self.clientID != nil
        state = .idle
        return clientConfigured
    }

    init() {
        clientConfigured = Self.clientID != nil
        if let data = UserDefaults.standard.data(forKey: "microsoftProfile") {
            profile = try? JSONDecoder().decode(Profile.self, from: data)
        }
    }

    // MARK: Signing in

    func signIn() {
        guard let client = Self.clientID else {
            state = .failed("Microsoft sign-in isn't set up in this build.")
            return
        }
        cancel()
        let attempt = generation
        signing = Task {
            defer { if generation == attempt { signing = nil } }
            do {
                let tokens = try await deviceCode(client)
                try await finish(microsoft: tokens, attempt: attempt)
                let ready = await handOver()
                guard generation == attempt, ready else { return }
                Haptics.done()
            } catch is CancellationError {
                if generation == attempt { state = .idle }
            } catch {
                guard generation == attempt else { return }
                state = .failed(error.localizedDescription)
                Haptics.failed()
            }
        }
    }

    func cancel() {
        generation = UUID()
        signing?.cancel()
        signing = nil
        handoverTask?.cancel()
        handoverTask = nil
        sessionReady = false
        state = .idle
    }

    func signOut() async {
        cancel()
        let answer = await Bridge.send("launcher-session off")
        guard answer.error == nil, answer["ok"] as? Bool == true else {
            state = .failed(answer.error ?? "Could not sign out of the game. Try again.")
            return
        }
        guard Vault.write(nil) else {
            state = .failed("Could not remove the saved sign-in. Try again.")
            return
        }
        UserDefaults.standard.removeObject(forKey: "microsoftProfile")
        profile = nil
    }

    /// Concurrent startup and Play requests share a single renewal and handover.
    @discardableResult
    func handOver() async -> Bool {
        guard profile != nil else { return true }
        if let handoverTask { return await handoverTask.value }
        let attempt = generation
        let task = Task { await handOverNow(attempt: attempt) }
        handoverTask = task
        let ready = await task.value
        if generation == attempt { handoverTask = nil }
        return ready
    }

    /// Do not launch with a stale cached profile or while sign-in is still in progress.
    func prepareForPlay() async -> Bool {
        if signing != nil { return false }
        return await handOver()
    }

    private func handOverNow(attempt: UUID) async -> Bool {
        sessionReady = false
        guard let client = Self.clientID, var secrets = Vault.read() else {
            _ = await Bridge.send("launcher-session off")
            guard generation == attempt else { return false }
            state = .failed("The saved account is unavailable. Sign in again.")
            return false
        }
        if secrets.expires.timeIntervalSinceNow < 3600 {
            do {
                state = .working("Renewing your sign-in…")
                let microsoft = try await refresh(client, secrets.refresh)
                try await finish(microsoft: microsoft, attempt: attempt)
                guard generation == attempt, let renewed = Vault.read() else { return false }
                secrets = renewed
            } catch {
                guard generation == attempt else { return false }
                _ = await Bridge.send("launcher-session off")
                guard generation == attempt else { return false }
                state = .failed("Sign in again: \(error.localizedDescription)")
                return false
            }
        }
        guard generation == attempt, let profile else { return false }
        let session: [String: String] = [
            "name": profile.name, "uuid": profile.uuid, "access_token": secrets.token, "user_type": "msa",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: session),
              let json = String(data: data, encoding: .utf8) else {
            state = .failed("Could not prepare the Minecraft session.")
            return false
        }
        let answer = await Bridge.send("launcher-session \(json)")
        guard generation == attempt else { return false }
        if let error = answer.error {
            state = .failed(error)
            return false
        }
        guard answer["ok"] as? Bool == true else {
            state = .failed("The game did not confirm the Minecraft session.")
            return false
        }
        sessionReady = true
        state = .idle
        return true
    }

    /// Steps 1 and 2: a code for the player to enter, then the wait for them to do it.
    private func deviceCode(_ client: String) async throws -> (access: String, refresh: String) {
        state = .working("Asking Microsoft for a code…")
        let start = try await Net.form("https://login.microsoftonline.com/consumers/oauth2/v2.0/devicecode",
                                       ["client_id": client, "scope": "XboxLive.signin offline_access"])
        guard let device = start["device_code"] as? String, let code = start["user_code"] as? String,
              let link = (start["verification_uri"] as? String).flatMap(URL.init(string:)),
              link.scheme == "https"
        else { throw AccountError("Microsoft didn't give a sign-in code.") }
        state = .code(code, link)
        var interval = UInt64(max(1, start["interval"] as? Int ?? 5))
        let deadline = Date().addingTimeInterval(TimeInterval(start["expires_in"] as? Int ?? 900))
        while Date() < deadline {
            try await Task.sleep(nanoseconds: interval * 1_000_000_000)
            let answer = try await Net.form(
                "https://login.microsoftonline.com/consumers/oauth2/v2.0/token",
                ["grant_type": "urn:ietf:params:oauth:grant-type:device_code", "client_id": client,
                 "device_code": device],
                allowErrors: true
            )
            switch answer["error"] as? String {
            case nil:
                guard let access = answer["access_token"] as? String,
                      let refresh = answer["refresh_token"] as? String
                else { throw AccountError("Microsoft's answer had no token.") }
                return (access, refresh)
            case "authorization_pending": continue
            case "slow_down": interval += 5
            case "authorization_declined": throw AccountError("The sign-in was declined.")
            case "expired_token": throw AccountError("The code expired. Try again.")
            default: throw AccountError("Microsoft refused the sign-in. Try again or check this build’s app configuration.")
            }
        }
        throw AccountError("The code expired. Try again.")
    }

    private func refresh(_ client: String, _ token: String) async throws -> (access: String, refresh: String) {
        let answer = try await Net.form(
            "https://login.microsoftonline.com/consumers/oauth2/v2.0/token",
            ["grant_type": "refresh_token", "client_id": client, "refresh_token": token,
             "scope": "XboxLive.signin offline_access"],
            allowErrors: true
        )
        guard let access = answer["access_token"] as? String else {
            throw AccountError("Microsoft wants you to sign in again.")
        }
        return (access, answer["refresh_token"] as? String ?? token)
    }

    /// Steps 3 to 7: Xbox Live, XSTS, Minecraft, ownership and the profile; then keep it all.
    private func finish(microsoft: (access: String, refresh: String), attempt: UUID) async throws {
        state = .working("Signing in to Xbox Live…")
        let xbl = try await Net.json("https://user.auth.xboxlive.com/user/authenticate", [
            "Properties": ["AuthMethod": "RPS", "SiteName": "user.auth.xboxlive.com",
                           "RpsTicket": "d=\(microsoft.access)"],
            "RelyingParty": "http://auth.xboxlive.com", "TokenType": "JWT",
        ])
        guard let xblToken = xbl["Token"] as? String,
              let uhs = (((xbl["DisplayClaims"] as? [String: Any])?["xui"] as? [[String: Any]])?.first)?["uhs"] as? String
        else { throw AccountError("Xbox Live didn't sign you in.") }
        let xsts = try await Net.json("https://xsts.auth.xboxlive.com/xsts/authorize", [
            "Properties": ["SandboxId": "RETAIL", "UserTokens": [xblToken]] as [String: Any],
            "RelyingParty": "rp://api.minecraftservices.com/", "TokenType": "JWT",
        ], allowErrors: true)
        if let code = xsts["XErr"] as? Int {
            throw AccountError(Self.xboxError(code))
        }
        guard let xstsToken = xsts["Token"] as? String else { throw AccountError("Xbox Live refused the sign-in.") }
        state = .working("Signing in to Minecraft…")
        let minecraft = try await Net.json("https://api.minecraftservices.com/authentication/login_with_xbox",
                                           ["identityToken": "XBL3.0 x=\(uhs);\(xstsToken)"], allowErrors: true)
        guard let token = minecraft["access_token"] as? String else {
            if minecraft["status"] as? Int == 403 || (minecraft["errorMessage"] as? String)?.contains("Invalid app") == true {
                throw AccountError("This app is not approved by Mojang yet.")
            }
            throw AccountError("Minecraft refused the sign-in.")
        }
        let lifetime = TimeInterval(minecraft["expires_in"] as? Int ?? 86400)
        let store = try await Net.get("https://api.minecraftservices.com/entitlements/mcstore", token: token)
        let owned = (store["items"] as? [[String: Any]] ?? []).contains {
            ["game_minecraft", "product_minecraft"].contains($0["name"] as? String ?? "")
        }
        guard owned else { throw AccountError("This account doesn't own Minecraft: Java Edition.") }
        let profile = try await Net.get("https://api.minecraftservices.com/minecraft/profile", token: token,
                                        allowErrors: true)
        guard let id = profile["id"] as? String, let name = profile["name"] as? String else {
            throw AccountError("Create your Minecraft profile on minecraft.net first.")
        }
        try Task.checkCancellation()
        guard generation == attempt else { throw CancellationError() }
        guard Vault.write(Vault.Secrets(refresh: microsoft.refresh, token: token,
                                       expires: Date().addingTimeInterval(lifetime))) else {
            throw AccountError("Sign-in could not be saved securely. Unlock this device and try again.")
        }
        let kept = Profile(name: name, uuid: id)
        UserDefaults.standard.set(try? JSONEncoder().encode(kept), forKey: "microsoftProfile")
        self.profile = kept
    }

    private static func xboxError(_ code: Int) -> String {
        switch code {
        case 2_148_916_233: return "This Microsoft account has no Xbox profile yet: create one at xbox.com."
        case 2_148_916_235: return "Xbox Live isn't available in your country."
        case 2_148_916_236, 2_148_916_237: return "This account needs adult verification on xbox.com."
        case 2_148_916_238: return "This is a child account: an adult has to add it to a Microsoft family."
        default: return "Xbox Live refused the sign-in (\(code))."
        }
    }
}

struct AccountError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// The requests the sign-in makes: HTTPS, JSON back. Tokens are never logged.
private enum Net {
    static func form(_ url: String, _ fields: [String: String], allowErrors: Bool = false) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = fields
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)
        return try await send(request, allowErrors: allowErrors)
    }

    static func json(_ url: String, _ body: [String: Any], allowErrors: Bool = false) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request, allowErrors: allowErrors)
    }

    static func get(_ url: String, token: String, allowErrors: Bool = false) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await send(request, allowErrors: allowErrors)
    }

    /// The JSON object answered, with `status` added for an error status when `allowErrors`.
    private static func send(_ request: URLRequest, allowErrors: Bool) async throws -> [String: Any] {
        try Task.checkCancellation()
        let (data, response) = try await URLSession.shared.data(for: request)
        try Task.checkCancellation()
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if !(200..<300).contains(status) {
            guard allowErrors else { throw AccountError("The sign-in service answered \(status).") }
            object["status"] = status
        }
        return object
    }
}

/// The account's secrets, in the keychain only.
private enum Vault {
    struct Secrets: Codable {
        let refresh: String
        let token: String
        let expires: Date
    }

    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "dev.horizon.launcher.microsoft",
        kSecAttrAccount as String: "account",
    ]

    static func read() -> Secrets? {
        var item: CFTypeRef?
        var search = query
        search[kSecReturnData as String] = true
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(Secrets.self, from: data)
    }

    @discardableResult
    static func write(_ secrets: Secrets?) -> Bool {
        guard let secrets else {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        guard let data = try? JSONEncoder().encode(secrets) else { return false }
        let changed = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if changed == errSecSuccess { return true }
        guard changed == errSecItemNotFound else { return false }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}

// MARK: - The card

/// The Microsoft account on the Play page: who is signed in, or the way to sign in.
struct AccountCard: View {
    @ObservedObject var account: MicrosoftAccount
    @State private var applicationID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "person.badge.key.fill").foregroundStyle(Theme.accentText)
                VStack(alignment: .leading, spacing: 2) {
                    Text("MICROSOFT ACCOUNT").font(Theme.mono(8)).foregroundStyle(Theme.textMuted)
                    Text(account.profile?.name ?? "Not signed in").font(Theme.sans(15, .semiBold))
                        .foregroundStyle(Theme.text)
                    if account.profile != nil && !account.sessionReady {
                        Text("Minecraft session not yet confirmed").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if account.profile != nil {
                    Button("Sign out") { Task { await account.signOut() } }
                        .font(Theme.sans(12, .semiBold)).foregroundStyle(Theme.textMuted)
                        .frame(minHeight: 44)
                }
            }
            switch account.state {
            case let .code(code, link):
                VStack(alignment: .leading, spacing: 8) {
                    Text("Enter this code at \(link.host ?? "microsoft.com/link"):")
                        .font(Theme.sans(12)).foregroundStyle(Theme.textMuted)
                    Text(code).font(Theme.pixel(30)).foregroundStyle(Theme.text).textSelection(.enabled)
                    PrimaryButton(title: "Copy code and open", icon: "safari") {
                        UIPasteboard.general.string = code
                        UIApplication.shared.open(link)
                    }
                    SecondaryButton(title: "Cancel") { account.cancel() }
                }
            case let .working(step):
                HStack(spacing: 8) {
                    ProgressView().tint(Theme.accentText)
                    Text(step).font(Theme.sans(12)).foregroundStyle(Theme.textMuted)
                }
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.sans(12)).foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            case .idle:
                EmptyView()
            }
            if account.profile != nil, case .failed = account.state, account.clientConfigured {
                SecondaryButton(title: "Sign in again", icon: "key.fill") { account.signIn() }
            }
            if account.profile == nil, !isSigning {
                if account.clientConfigured {
                    SecondaryButton(title: "Sign in with Microsoft / Xbox", icon: "key.fill") { account.signIn() }
                    Text("For servers that check accounts (online mode). Single player and LAN don't need it.")
                        .font(Theme.sans(11)).foregroundStyle(Theme.textFaint)
                } else {
                    Text("Microsoft sign-in needs an application ID approved for Minecraft Java. Single player and offline servers are available.")
                        .font(Theme.sans(11)).foregroundStyle(Theme.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if MicrosoftAccount.bundledClientID == nil {
                    DisclosureGroup("Developer setup") {
                        Text("Enter your launcher's public Microsoft application (client) ID. This is not a password or token.")
                            .font(.footnote).foregroundStyle(.secondary)
                        TextField("Application (client) ID", text: $applicationID)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("microsoft-client-id")
                        Button("Save application ID") {
                            if account.configureClientID(applicationID) { applicationID = "" }
                        }.accessibilityIdentifier("microsoft-client-id-save")
                    }
                }
            }
        }
        .padding(14)
        .card()
    }

    private var isSigning: Bool {
        switch account.state {
        case .code, .working: return true
        default: return false
        }
    }
}
