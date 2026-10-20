import Foundation

/// JSON files the app and the CLI both read and write (settings, run history, the patch registry).
enum StateFile {
    /// The decoded file, or nil when there is none or it can't be decoded. An undecodable file is
    /// copied aside first (see `keepCopy`), so writing a fresh one can't erase what was in it.
    static func read<T: Decodable>(_ type: T.Type, from url: URL, decoder: JSONDecoder = JSONDecoder()) -> T? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            keepCopy(of: url)
            return nil
        }
    }

    /// Writes atomically, so a reader in another process sees the old file or the new one, never half.
    static func write<T: Encodable>(_ value: T, to url: URL, encoder: JSONEncoder = JSONEncoder()) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(value).write(to: url, options: .atomic)
    }

    /// Saves the file as `<name>.corrupt` (replacing an older copy) before it is overwritten with
    /// what could be read of it, e.g. one written by a newer version.
    static func keepCopy(of url: URL) {
        let copy = url.appendingPathExtension("corrupt")
        try? FileManager.default.removeItem(at: copy)
        try? FileManager.default.copyItem(at: url, to: copy)
    }
}

/// Decodes to nil instead of failing, so one unreadable element doesn't cost the whole array.
struct Lenient<Wrapped: Decodable>: Decodable {
    var value: Wrapped?

    init(from decoder: Decoder) throws {
        value = try? Wrapped(from: decoder)
    }
}
