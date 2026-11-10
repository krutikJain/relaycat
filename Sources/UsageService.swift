import Foundation
import CommonCrypto
import Security

// Live limits from Anthropic's usage endpoint, the same one the Claude app uses.
// Each profile's config.json stores its OAuth tokens encrypted with Electron safe storage
// (key from the "Claude Safe Storage" keychain item, PBKDF2-SHA1 "saltysalt" x1003, AES-128-CBC).
// Only the short-lived access token is read. The refresh token is never used: refreshing rotates it
// and would sign that Claude out. Tokens stay in memory and are only sent to api.anthropic.com.
struct LiveUsage: Codable, Hashable {
    var fiveHour: Double?
    var fiveHourReset: Date?
    var week: Double?
    var weekReset: Date?
    var fable: Double?
    var fableReset: Date?
    var plan: String?
    var fetchedAt: Date?
    var problem: String?
    var failures = 0
    var waitUntil: Date?
}

enum UsageService {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let backoff: [TimeInterval] = [60, 120, 300, 900, 1800]

    enum Problem: Error {
        case noKeychain(String)
        case noToken
        case expired
        case http(Int, TimeInterval?)
        case bad
        var text: String {
            switch self {
            case .noKeychain(let s): return s
            case .noToken: return "Not signed in, so there's nothing to ask Anthropic with."
            case .expired: return "Its login needs renewing. Open this profile once and Claude does that by itself."
            case .http(401, _), .http(403, _): return "Anthropic didn't accept the login. Open this profile once so Claude can renew it."
            case .http(429, _): return "Anthropic asked Relaycat to slow down. The last numbers stay on screen."
            case .http(let c, _): return "Anthropic's usage service answered \(c)."
            case .bad: return "Anthropic's usage service sent something unexpected."
            }
        }
    }

    // MARK: Store

    static func storeURL(_ settingsDir: URL) -> URL { settingsDir.appendingPathComponent("usage.json") }

    static func importFromGraftIfNeeded(graftDir: URL, settingsDir: URL, names: [String: String]) {
        guard !FileManager.default.fileExists(atPath: storeURL(settingsDir).path),
              let d = try? Data(contentsOf: graftDir.appendingPathComponent("usage-status.json")),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let list = j["profiles"] as? [[String: Any]] else { return }
        let byName = Dictionary(names.map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        var store: [String: LiveUsage] = [:]
        for p in list {
            guard let n = p["name"] as? String, let folder = byName[n] else { continue }
            var u = LiveUsage()
            u.fiveHour = (p["fiveHour"] as? NSNumber)?.doubleValue
            u.fiveHourReset = Scanner.iso(p["fiveHourReset"])
            u.week = (p["week"] as? NSNumber)?.doubleValue
            u.weekReset = Scanner.iso(p["weekReset"])
            u.fable = (p["fable"] as? NSNumber)?.doubleValue
            u.fableReset = Scanner.iso(p["fableReset"])
            u.fetchedAt = Scanner.iso(p["refreshedAt"])
            store[folder] = u
        }
        if !store.isEmpty { save(store, settingsDir) }
    }

    static func load(_ settingsDir: URL) -> [String: LiveUsage] {
        guard let d = try? Data(contentsOf: storeURL(settingsDir)) else { return [:] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([String: LiveUsage].self, from: d)) ?? [:]
    }

    static func save(_ s: [String: LiveUsage], _ settingsDir: URL) {
        try? FileManager.default.createDirectory(at: settingsDir, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(s) { try? d.write(to: storeURL(settingsDir), options: .atomic) }
    }

    // MARK: Keychain

    private static var cachedKey: Data?
    private static let keyLock = NSLock()
    // True when reading "Claude Safe Storage" needs the user to allow it in the macOS prompt first.
    nonisolated(unsafe) static var needsPermission = false

    static func safeStorageKey(allowPrompt: Bool) throws -> Data {
        keyLock.lock(); defer { keyLock.unlock() }
        if let k = cachedKey { return k }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Safe Storage",
            kSecAttrAccount as String: "Claude Key",
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        if !allowPrompt {
            query[kSecUseAuthenticationUI as String] = LAContextShim.noUI()
            SecKeychainSetUserInteractionAllowed(false)
        }
        defer { if !allowPrompt { SecKeychainSetUserInteractionAllowed(true) } }
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        needsPermission = status != errSecSuccess && status != errSecItemNotFound
        guard status == errSecSuccess, let pw = out as? Data else {
            if !allowPrompt && status != errSecItemNotFound {
                throw Problem.noKeychain("Live limits need your OK once. Press Allow in Relaycat, then choose Always Allow.")
            }
            switch status {
            case errSecUserCanceled, errSecAuthFailed:
                throw Problem.noKeychain("You chose not to let Relaycat read Claude's login, so live limits are off. Turn them on again in Settings.")
            case errSecInteractionNotAllowed:
                throw Problem.noKeychain("Live limits need one-time permission. Turn them on in Settings.")
            case errSecItemNotFound:
                throw Problem.noKeychain("Claude hasn't saved a login on this Mac yet.")
            default:
                throw Problem.noKeychain("The keychain said no (\(status)).")
            }
        }
        var key = Data(count: kCCKeySizeAES128)
        let salt = Data("saltysalt".utf8)
        let rc = key.withUnsafeMutableBytes { kp in
            salt.withUnsafeBytes { sp in
                pw.withUnsafeBytes { pp in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         pp.baseAddress?.assumingMemoryBound(to: Int8.self), pw.count,
                                         sp.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                         kp.baseAddress?.assumingMemoryBound(to: UInt8.self), kCCKeySizeAES128)
                }
            }
        }
        guard rc == kCCSuccess else { throw Problem.noKeychain("Couldn't unlock Claude's saved login.") }
        cachedKey = key
        return key
    }

    static func decrypt(_ b64: String, key: Data) -> Data? {
        guard let blob = Data(base64Encoded: b64), blob.count > 3, blob.prefix(3) == Data("v10".utf8) else { return nil }
        let ct = blob.dropFirst(3)
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var out = Data(count: ct.count + kCCBlockSizeAES128)
        var len = 0
        let outCount = out.count
        let rc = out.withUnsafeMutableBytes { op in
            ct.withUnsafeBytes { cp in
                iv.withUnsafeBytes { ip in
                    key.withUnsafeBytes { kp in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                kp.baseAddress, key.count, ip.baseAddress, cp.baseAddress, ct.count,
                                op.baseAddress, outCount, &len)
                    }
                }
            }
        }
        guard rc == kCCSuccess else { return nil }
        return out.prefix(len)
    }

    static func accessToken(profile: URL, key: Data) throws -> String {
        guard let d = try? Data(contentsOf: profile.appendingPathComponent("config.json")),
              let config = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { throw Problem.noToken }
        var best: (String, Double)?
        var sawExpired = false
        for k in ["oauth:tokenCacheV2", "oauth:tokenCache"] {
            guard let b64 = config[k] as? String, let plain = decrypt(b64, key: key),
                  let cache = try? JSONSerialization.jsonObject(with: plain) as? [String: Any] else { continue }
            for (scopeKey, value) in cache {
                guard let e = value as? [String: Any], let token = e["token"] as? String,
                      let expires = (e["expiresAt"] as? NSNumber)?.doubleValue else { continue }
                if !scopeKey.contains("user:profile") && cache.count > 1 { continue }
                if expires / 1000 < Date().timeIntervalSince1970 + 120 { sawExpired = true; continue }
                if best == nil || expires > best!.1 { best = (token, expires) }
            }
            if best != nil { break }
        }
        if let b = best { return b.0 }
        throw sawExpired ? Problem.expired : Problem.noToken
    }

    // MARK: Fetch

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static let noRedirectSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil
        cfg.urlCache = nil
        return URLSession(configuration: cfg, delegate: NoRedirect(), delegateQueue: nil)
    }()

    static func fetch(token: String) throws -> LiveUsage {
        var req = URLRequest(url: endpoint, timeoutInterval: 10)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        let sem = DispatchSemaphore(value: 0)
        var result: Result<(Data, HTTPURLResponse), Error> = .failure(Problem.bad)
        noRedirectSession.dataTask(with: req) { data, resp, err in
            if let data, let http = resp as? HTTPURLResponse { result = .success((data, http)) }
            else { result = .failure(err ?? Problem.bad) }
            sem.signal()
        }.resume()
        sem.wait()
        let (data, http) = try result.get()
        guard http.statusCode == 200 else {
            let retry = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
            throw Problem.http(http.statusCode, retry)
        }
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Problem.bad }
        func pct(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
        func when(_ v: Any?) -> Date? {
            if let n = v as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue) }
            return Scanner.iso(v)
        }
        var u = LiveUsage()
        if let f = j["five_hour"] as? [String: Any] { u.fiveHour = pct(f["utilization"]); u.fiveHourReset = when(f["resets_at"]) }
        if let w = j["seven_day"] as? [String: Any] { u.week = pct(w["utilization"]) ?? 0; u.weekReset = when(w["resets_at"]) }
        if let limits = j["limits"] as? [[String: Any]] {
            for l in limits where (l["kind"] as? String) == "weekly_scoped" {
                let name = (((l["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String) ?? ""
                if name.lowercased().contains("fable") {
                    u.fable = pct(l["percent"]) ?? pct(l["utilization"])
                    u.fableReset = when(l["resets_at"])
                }
            }
        }
        if let s = j["subscription_type"] as? String { u.plan = s.capitalized }
        u.fetchedAt = Date()
        return u
    }

    static func refresh(profiles: [Profile], settingsDir: URL, force: Bool, allowPrompt: Bool) -> [String: LiveUsage] {
        var store = load(settingsDir)
        let now = Date()
        let key: Data
        do { key = try safeStorageKey(allowPrompt: allowPrompt) } catch {
            let text = (error as? Problem)?.text ?? error.localizedDescription
            for p in profiles { store[p.folder, default: LiveUsage()].problem = text }
            save(store, settingsDir)
            return store
        }
        for p in profiles where p.accountUuid != nil {
            var u = store[p.folder] ?? LiveUsage()
            if let wait = u.waitUntil, wait > now, !(force && u.failures < 2) { continue }
            let interval: TimeInterval = p.running ? 120 : 300
            if !force, let f = u.fetchedAt, now.timeIntervalSince(f) < interval { continue }
            do {
                let token = try accessToken(profile: p.path, key: key)
                var fresh = try fetch(token: token)
                fresh.failures = 0
                u = fresh
            } catch let pr as Problem {
                u.problem = pr.text
                if case .http(_, let retry) = pr {
                    u.failures += 1
                    let step = backoff[min(u.failures - 1, backoff.count - 1)]
                    u.waitUntil = now.addingTimeInterval(max(retry ?? 0, step))
                } else {
                    u.waitUntil = now.addingTimeInterval(backoff[0])
                }
            } catch {
                u.problem = "Couldn't reach Anthropic: \(error.localizedDescription)"
                u.failures += 1
                u.waitUntil = now.addingTimeInterval(backoff[min(u.failures - 1, backoff.count - 1)])
            }
            store[p.folder] = u
        }
        save(store, settingsDir)
        return store
    }
}

enum LAContextShim {
    static func noUI() -> CFString { kSecUseAuthenticationUIFail }
}
