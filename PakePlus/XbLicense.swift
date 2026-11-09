import Foundation
import CryptoKit
import Security

// MARK: - 小白网络验证（卡密登录）

enum XbConfig {
    static let soft = "A5oK9TdIScwJ7YVhKa"
    static let softKey = "spsDHBCg8SeoPuOcCMpiWX6hJ9WQ3atN"
    // 必须与小白后台的通信密钥、签名算法一致；下方是同账号其他端已使用的配置。
    static let rc4Key = "f58I8xTfTgaq0wuYrnUUn741ttawInxw0er0m3nmgSqMUC6c"
    static let signTemplate = "123[data]456[key]789"
    static let host = "api4.xbzhan.com"
    static let version = "1.0.0"
    static let offlineGraceDays = 3
    static let minRevalidateInterval: TimeInterval = 120
}

enum XbCrypto {
    static func rc4(key: [UInt8], data: [UInt8]) -> [UInt8] {
        guard !key.isEmpty, !data.isEmpty else { return data }
        var s = Array(0...255).map { UInt8($0) }
        var j = 0
        for i in 0..<256 { j = (j + Int(s[i]) + Int(key[i % key.count])) & 255; s.swapAt(i, j) }
        var i = 0; j = 0
        return data.map { byte in
            i = (i + 1) & 255; j = (j + Int(s[i])) & 255; s.swapAt(i, j)
            return byte ^ s[(Int(s[i]) + Int(s[j])) & 255]
        }
    }
    static func rc4Hex(key: String, text: String) -> String {
        rc4(key: Array(key.utf8), data: Array(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func decrypt(key: String, hex: String) -> String? {
        let c = Array(hex)
        guard c.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8](); bytes.reserveCapacity(c.count / 2)
        for i in stride(from: 0, to: c.count, by: 2) {
            guard let b = UInt8(String(c[i...i + 1]), radix: 16) else { return nil }
            bytes.append(b)
        }
        return String(bytes: rc4(key: Array(key.utf8), data: bytes), encoding: .utf8)
    }
    static func md5(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum XbDevice {
    private static let service = "com.pakeplus.xb.device"
    private static var cached: String?
    static func id() -> String {
        if let cached { return cached }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "id",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty {
            cached = value; return value
        }
        let value = UUID().uuidString
        SecItemDelete(query as CFDictionary)
        var add = [kSecClass as String: kSecClassGenericPassword,
                   kSecAttrService as String: service, kSecAttrAccount as String: "id",
                   kSecValueData as String: Data(value.utf8),
                   kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as [String: Any]
        SecItemAdd(add as CFDictionary, nil)
        cached = value
        return value
    }
    static var feature: String { XbCrypto.md5(id()) }
    static var mac: String { String(XbCrypto.md5(id() + "-mac").prefix(12)).uppercased() }
    static var clientId: String { "PAKE" + String(XbCrypto.md5(id() + "-cid").prefix(20)).uppercased() }
}

struct XbLicenseState: Codable {
    var cardKey: String
    var firstActivatedAt: Date
    var lastVerifiedAt: Date
    var expireAt: Date?
    var disabled: Bool
    var boundDeviceId: String
    var cookie: String?
}

enum XbVault {
    private static let blobKey = "pake.xb.license.blob"
    private static let aesKey = "pake.xb.license.key"
    private static func key() -> SymmetricKey {
        if let data = UserDefaults.standard.data(forKey: aesKey), data.count == 32 { return SymmetricKey(data: data) }
        let value = SymmetricKey(size: .bits256)
        UserDefaults.standard.set(value.withUnsafeBytes { Data($0) }, forKey: aesKey)
        return value
    }
    static func load() -> XbLicenseState? {
        guard let blob = UserDefaults.standard.data(forKey: blobKey),
              let box = try? AES.GCM.SealedBox(combined: blob),
              let plain = try? AES.GCM.open(box, using: key()) else { return nil }
        return try? JSONDecoder().decode(XbLicenseState.self, from: plain)
    }
    static func save(_ state: XbLicenseState) {
        guard let plain = try? JSONEncoder().encode(state),
              let box = try? AES.GCM.seal(plain, using: key()), let blob = box.combined else { return }
        UserDefaults.standard.set(blob, forKey: blobKey)
    }
    static func clear() { UserDefaults.standard.removeObject(forKey: blobKey) }
}

enum XbLicense {
    static var active: Bool {
        guard let s = XbVault.load(), !s.disabled, s.boundDeviceId == XbDevice.id() else { return false }
        return s.expireAt.map { $0 > Date() } ?? true
    }
    static var needsRevalidation: Bool {
        guard let s = XbVault.load() else { return false }
        let age = Date().timeIntervalSince(s.lastVerifiedAt)
        return age > Double(XbConfig.offlineGraceDays) * 86_400 && age > XbConfig.minRevalidateInterval
    }
    static func remainingText() -> String {
        guard let exp = XbVault.load()?.expireAt else { return "授权有效" }
        let days = Calendar.current.dateComponents([.day], from: Date(), to: exp).day ?? 0
        return days >= 0 ? "卡密剩余\(days)天" : "卡密已过期"
    }
}

enum XbService {
    private struct PacketResult { var code: Int; var message: String; var networkError: Bool; var cookie: String?; var expireAt: Date? }

    static func verify(_ raw: String) async -> (Bool, String) {
        let card = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !card.isEmpty else { return (false, "请输入卡密") }
        let initResult = await call("/api/init", extra: [:])
        guard !initResult.networkError else { return (false, initResult.message) }
        guard initResult.code == 200 else { return (false, initResult.message.isEmpty ? "初始化失败" : initResult.message) }
        let login = await call("/api/login", extra: ["account": card])
        guard !login.networkError else { return (false, login.message) }
        guard login.code == 200 else { return (false, login.message.isEmpty ? "卡密验证失败" : login.message) }
        guard let cookie = login.cookie, !cookie.isEmpty else { return (false, "登录成功但未获取到凭证") }
        let info = await call("/api/login_info", extra: ["account": card, "cookie": cookie])
        guard !info.networkError else { return (false, info.message) }
        guard info.code == 200 else {
            return (false, info.message.isEmpty ? "授权信息获取失败" : info.message)
        }
        let previous = XbVault.load()
        XbVault.save(XbLicenseState(cardKey: card, firstActivatedAt: previous?.firstActivatedAt ?? Date(),
            lastVerifiedAt: Date(), expireAt: info.expireAt ?? login.expireAt, disabled: false,
            boundDeviceId: XbDevice.id(), cookie: cookie))
        return (true, login.message.isEmpty ? "验证成功" : login.message)
    }

    static func heartbeat() async {
        guard var state = XbVault.load(), let cookie = state.cookie else { return }
        let result = await call("/api/login_info", extra: ["account": state.cardKey, "cookie": cookie])
        if result.code == 200 {
            state.lastVerifiedAt = Date(); if let expiry = result.expireAt { state.expireAt = expiry }
            XbVault.save(state)
        } else if !result.networkError && result.code != -1 {
            XbVault.clear()
        }
    }

    private static func call(_ path: String, extra: [String: String]) async -> PacketResult {
        let uuid = randomToken(16), token = randomToken(16)
        var data: [String: String] = ["param": "", "uuid": uuid, "token": token,
            "clientid": XbDevice.clientId, "version": XbConfig.version, "mac": XbDevice.mac,
            "md5": "", "clientos": "iOS " + ProcessInfo.processInfo.operatingSystemVersionString,
            "feature": XbDevice.feature]
        extra.forEach { data[$0.key] = $0.value }
        guard let plain = try? JSONSerialization.data(withJSONObject: data),
              let text = String(data: plain, encoding: .utf8) else {
            return PacketResult(code: -1, message: "请求构造失败", networkError: true, cookie: nil, expireAt: nil)
        }
        let encrypted = XbCrypto.rc4Hex(key: XbConfig.rc4Key, text: text)
        let signature = XbCrypto.md5(XbConfig.signTemplate.replacingOccurrences(of: "[data]", with: encrypted)
            .replacingOccurrences(of: "[key]", with: XbConfig.softKey))
        let body: [String: String] = ["soft": XbConfig.soft, "data": encrypted, "sign": signature]
        guard let url = URL(string: "https://\(XbConfig.host)\(path)") else {
            return PacketResult(code: -1, message: "服务地址无效", networkError: true, cookie: nil, expireAt: nil)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (bytes, _) = try await URLSession.shared.data(for: request)
            guard let outer = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw URLError(.cannotParseResponse) }
            if let status = outer["status"] as? String, status.hasPrefix("error.") {
                return PacketResult(code: -2, message: outer["msg"] as? String ?? status, networkError: false, cookie: nil, expireAt: nil)
            }
            var inner: [String: Any]?
            if let encryptedResponse = outer["data"] as? String,
               let decoded = XbCrypto.decrypt(key: XbConfig.rc4Key, hex: encryptedResponse),
               let bytes = decoded.data(using: .utf8) { inner = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] }
            else { inner = outer["data"] as? [String: Any] }
            guard let result = inner else { throw URLError(.cannotParseResponse) }
            let code = int(result["code"]) ?? -1
            let message = result["msg"] as? String ?? ""
            let payload = result["result"] as? [String: Any] ?? result
            let cookie = find(in: payload, contains: "cookie") as? String ?? find(in: result, contains: "cookie") as? String
            let expiry = parseExpiry(payload) ?? parseExpiry(result)
            return PacketResult(code: code, message: message, networkError: false, cookie: cookie, expireAt: expiry)
        } catch {
            return PacketResult(code: -1, message: "网络错误：\(error.localizedDescription)", networkError: true, cookie: nil, expireAt: nil)
        }
    }

    private static func find(in dict: [String: Any], contains key: String) -> Any? {
        dict.first { $0.key.lowercased().contains(key) && !($0.value is NSNull) }?.value
    }
    private static func int(_ raw: Any?) -> Int? {
        if let n = raw as? NSNumber { return n.intValue }
        if let s = raw as? String { return Int(s) }
        return nil
    }
    private static func parseExpiry(_ dict: [String: Any]) -> Date? {
        let names = ["endTime", "endtime", "end_time", "expire_time", "expire_at", "expire", "expires", "vip_time", "vip_end", "over_time", "time_end", "expiration", "due_time", "expiry"]
        for name in names where dict[name] != nil {
            let value = dict[name]!
            if let number = value as? NSNumber { return Date(timeIntervalSince1970: number.doubleValue > 1e12 ? number.doubleValue / 1000 : number.doubleValue) }
            if let string = value as? String {
                if let number = Double(string) { return Date(timeIntervalSince1970: number > 1e12 ? number / 1000 : number) }
                let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
                for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy/MM/dd HH:mm:ss"] {
                    formatter.dateFormat = format
                    if let date = formatter.date(from: string) { return date }
                }
                if let date = ISO8601DateFormatter().date(from: string) { return date }
            }
        }
        return nil
    }
    private static func randomToken(_ length: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<length).map { _ in chars.randomElement()! })
    }
}
