import Darwin
import Foundation

/// Disk operations run under the scanner's process lock and this store's file lock.
/// Value semantics let a cancelled scan roll back the remembered disk signature.
struct LocalUsageCacheStore {
    let cacheFileURL: URL?
    private var persistentCacheSignature: LocalUsageCacheFileSignature?
    private(set) var needsPersistence = false
    private var persistenceError: String?

    var persistence: UsageCachePersistence {
        UsageCachePersistence(status: cacheFileURL == nil ? .disabled : needsPersistence ? .pending : .saved,
                              error: persistenceError)
    }

    init(fileURL: URL?) { cacheFileURL = fileURL }

    mutating func load(into cache: inout LocalUsageScanCache?) {
        guard let cacheFileURL else { return }
        guard let signature = cacheFileSignature(for: cacheFileURL) else {
            // A removed cache or an obstructed destination must not discard
            // valid in-memory observations, even when no logs have changed.
            if cache != nil { needsPersistence = true }
            return
        }
        guard signature != persistentCacheSignature else { return }

        guard let data = try? Data(contentsOf: cacheFileURL) else { return }

        do {
            let document = try JSONDecoder().decode(LocalUsageCacheDocument.self, from: data)
            if document.version == LocalUsageCacheDocument.currentVersion {
                var incoming = document.cache
                if needsPersistence, let pending = cache {
                    incoming.retainPendingHistory(from: pending)
                }
                cache = incoming
            } else {
                needsPersistence = true
            }
        } catch {
            needsPersistence = true
            appendSharedLog("local usage cache ignored: \(errorMessage(error))")
        }
        persistentCacheSignature = signature
    }

    private func cacheFileSignature(for url: URL) -> LocalUsageCacheFileSignature? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              let modifiedAt = attributes[.modificationDate] as? Date
        else { return nil }
        return LocalUsageCacheFileSignature(
            fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
            size: size.uint64Value,
            modifiedAt: modifiedAt
        )
    }

    func acquireLock() throws -> Int32? {
        guard let cacheFileURL else { return nil }
        do {
            try FileManager.default.createDirectory(
                at: cacheFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw RuntimeError("Local usage lock directory failed: \(errorMessage(error))")
        }

        let lockURL = cacheFileURL.appendingPathExtension("lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw RuntimeError("Local usage lock open failed: errno=\(errno)")
        }
        do {
            let deadline = Date().addingTimeInterval(15)
            while Darwin.lockf(descriptor, F_TLOCK, 0) != 0 {
                guard errno == EACCES || errno == EAGAIN || errno == EINTR else { throw RuntimeError("Local usage lock failed: errno=\(errno)") }
                try RefreshWork.check()
                guard Date() < deadline else { throw RuntimeError("Timed out waiting for the local usage cache lock.") }
                Thread.sleep(forTimeInterval: 0.02)
            }
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        return descriptor
    }

    func releaseLock(_ descriptor: Int32?) {
        guard let descriptor else { return }
        _ = Darwin.lockf(descriptor, F_ULOCK, 0)
        Darwin.close(descriptor)
    }

    mutating func persist(_ cache: LocalUsageScanCache) {
        guard let cacheFileURL else { return }
        needsPersistence = true
        do {
            try FileManager.default.createDirectory(
                at: cacheFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let document = LocalUsageCacheDocument(cache: cache)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(document).write(to: cacheFileURL, options: .atomic)
            persistentCacheSignature = cacheFileSignature(for: cacheFileURL)
            needsPersistence = false
            persistenceError = nil
        } catch {
            let message = errorMessage(error)
            if persistenceError != message { appendSharedLog("local usage cache write failed: \(message)") }
            persistenceError = message
        }
    }

}

private struct LocalUsageCacheFileSignature: Equatable {
    let fileNumber: UInt64
    let size: UInt64
    let modifiedAt: Date
}
