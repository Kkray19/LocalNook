import Foundation
import OSLog

/// An unreadable store is preserved in place, never silently replaced by defaults.
final class JSONFileStore<Value: Codable> {
    let url: URL
    private(set) var failureMessage: String?
    private var writeBlocked = false
    private let logger = Logger(subsystem: "com.localnook.app", category: "persistence")

    init(url: URL) { self.url = url }

    func load() -> Value? {
        do {
            return try JSONDecoder().decode(Value.self, from: Data(contentsOf: url))
        } catch {
            if (error as NSError).domain == NSCocoaErrorDomain,
               (error as NSError).code == NSFileReadNoSuchFileError { return nil }
            writeBlocked = true
            failureMessage = "Saved data could not be read. The original file is preserved; changes cannot be saved until it is recovered."
            logger.error("Unreadable store preserved; saving disabled")
            return nil
        }
    }

    @discardableResult func save(_ value: Value) -> Bool {
        guard !writeBlocked else { return false }
        do {
            let data = try JSONEncoder().encode(value)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            failureMessage = nil
            return true
        } catch {
            failureMessage = "Changes could not be saved. Check available storage and folder permissions."
            logger.error("Atomic save failed")
            return false
        }
    }
}
