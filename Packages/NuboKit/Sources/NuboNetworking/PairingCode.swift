import Foundation

public enum PairingCode {
    public static func qrPayload(for code: String) -> String? {
        guard matches(code, expected: code) else { return nil }
        return "nubo-pair:v1:\(code)"
    }

    public static func code(fromQR payload: String) -> String? {
        let prefix = "nubo-pair:v1:"
        guard payload.hasPrefix(prefix) else { return nil }
        let code = String(payload.dropFirst(prefix.count))
        return matches(code, expected: code) ? code : nil
    }
    /// The six digits confirm the ephemeral key agreement; they are never the encryption key.
    public static func matches(_ input: String, expected: String) -> Bool {
        let digits = Array(input.utf8)
        let reference = Array(expected.utf8)
        guard digits.count == 6, reference.count == 6,
              digits.allSatisfy({ (48...57).contains($0) }) else { return false }
        return zip(digits, reference).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
