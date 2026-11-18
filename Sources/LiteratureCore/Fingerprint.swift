import Foundation
import CryptoKit

/// SHA-256 over file bytes, streamed in chunks (no whole-file load).
/// The fingerprint binds every stored page to the exact file content it came
/// from; references whose fingerprint no longer matches are stale by definition.
public enum Fingerprint {
    public static func sha256Hex(ofFileAt url: URL) throws -> String {
        // A copied or replaced file can have the same size and modification time.
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunkSize = 1 << 20 // 1 MiB
        while true {
            let data = try handle.read(upToCount: chunkSize)
            guard let data, !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Computes the same fingerprint without blocking the UI. Returns nil if unreadable.
    public static func sha256HexOffMain(ofFileAt url: URL) async -> String? {
        await Task.detached(priority: .userInitiated) {
            try? sha256Hex(ofFileAt: url)
        }.value
    }
}
