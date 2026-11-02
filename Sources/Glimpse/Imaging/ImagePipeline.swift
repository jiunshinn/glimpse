import AppKit

/// Decodes images in the background and keeps recent results in memory.
///
/// Full images use a small queue with request de-duplication and prefetching.
/// Thumbnails use a wider queue, and a cancelled request is removed before it starts.
final class ImagePipeline: @unchecked Sendable {
    static let shared = ImagePipeline()

    private let fullCache = NSCache<NSURL, DecodedImage>()
    private let thumbnailCache = NSCache<NSURL, Thumbnail>()
    private let fullQueue = OperationQueue()
    private let thumbnailQueue = OperationQueue()
    private let lock = NSLock()
    private var fullRequests: [URL: FullRequest] = [:]

    private final class FullRequest {
        let operation: DecodeOperation<DecodedImage>
        var waiters: [CheckedContinuation<DecodedImage?, Never>]

        init(operation: DecodeOperation<DecodedImage>, waiters: [CheckedContinuation<DecodedImage?, Never>]) {
            self.operation = operation
            self.waiters = waiters
        }
    }

    private init() {
        let memory = ProcessInfo.processInfo.physicalMemory
        fullCache.totalCostLimit = Int(min(memory / 8, 1_536 * 1_024 * 1_024))
        fullCache.countLimit = 16
        thumbnailCache.totalCostLimit = 320 * 1_024 * 1_024
        thumbnailCache.countLimit = 4_000

        fullQueue.name = "Glimpse.full"
        fullQueue.maxConcurrentOperationCount = 2
        fullQueue.qualityOfService = .userInitiated

        thumbnailQueue.name = "Glimpse.thumbnails"
        thumbnailQueue.maxConcurrentOperationCount = max(2, min(6, ProcessInfo.processInfo.activeProcessorCount - 2))
        thumbnailQueue.qualityOfService = .userInitiated
    }

    // MARK: - Cache

    func cachedImage(for url: URL) -> DecodedImage? {
        fullCache.object(forKey: url as NSURL)
    }

    func cachedThumbnail(for url: URL) -> Thumbnail? {
        thumbnailCache.object(forKey: url as NSURL)
    }

    /// Removes the cached data for a file that changed or was deleted.
    func invalidate(_ url: URL) {
        fullCache.removeObject(forKey: url as NSURL)
        thumbnailCache.removeObject(forKey: url as NSURL)
    }

    // MARK: - Full images

    func image(for url: URL) async -> DecodedImage? {
        if let cached = cachedImage(for: url) { return cached }
        return await withCheckedContinuation { continuation in
            enqueueFull(url, priority: .veryHigh, waiter: continuation)
        }
    }

    func prefetch(_ url: URL) {
        guard cachedImage(for: url) == nil else { return }
        enqueueFull(url, priority: .low, waiter: nil)
    }

    /// Cancels full-image requests that have not started, except for the given files.
    func cancelFullRequests(except keep: Set<URL>) {
        lock.lock()
        let stale = fullRequests
            .filter { !keep.contains($0.key) && !$0.value.operation.isExecuting }
            .map(\.value.operation)
        lock.unlock()
        // Cancel outside the lock: a cancelled operation can finish at once, and its completion takes the lock.
        stale.forEach { $0.cancel() }
    }

    private func enqueueFull(_ url: URL, priority: Operation.QueuePriority,
                             waiter: CheckedContinuation<DecodedImage?, Never>?) {
        lock.lock()
        if let request = fullRequests[url], !request.operation.isCancelled {
            if let waiter { request.waiters.append(waiter) }
            if priority.rawValue > request.operation.queuePriority.rawValue {
                request.operation.queuePriority = priority
            }
            lock.unlock()
            return
        }
        // A cancelled request can still have waiters. Move them to the new request.
        var waiters = fullRequests[url]?.waiters ?? []
        if let waiter { waiters.append(waiter) }
        let operation = DecodeOperation(url: url, work: ImageDecoder.decodeFull)
        operation.queuePriority = priority
        fullRequests[url] = FullRequest(operation: operation, waiters: waiters)
        lock.unlock()

        operation.completionBlock = { [weak self, unowned operation] in
            self?.completeFull(operation)
        }
        fullQueue.addOperation(operation)
    }

    private func completeFull(_ operation: DecodeOperation<DecodedImage>) {
        let result = operation.output
        if let result {
            fullCache.setObject(result, forKey: operation.url as NSURL, cost: result.cost)
        }
        lock.lock()
        guard let request = fullRequests[operation.url], request.operation === operation else {
            // A newer request replaced this one and took its waiters.
            lock.unlock()
            return
        }
        fullRequests[operation.url] = nil
        let waiters = request.waiters
        lock.unlock()
        waiters.forEach { $0.resume(returning: result) }
    }

    // MARK: - Thumbnails

    func thumbnail(for url: URL) async -> Thumbnail? {
        if let cached = cachedThumbnail(for: url) { return cached }
        let operation = DecodeOperation(url: url) { [self] url in
            cachedThumbnail(for: url) ?? ImageDecoder.decodeThumbnail(url)
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // The completion block also runs for a cancelled operation, so the continuation always resumes.
                operation.completionBlock = { [self, unowned operation] in
                    if let output = operation.output {
                        thumbnailCache.setObject(output, forKey: url as NSURL, cost: output.cost)
                    }
                    continuation.resume(returning: operation.output)
                }
                thumbnailQueue.addOperation(operation)
            }
        } onCancel: {
            operation.cancel()
        }
    }
}

private final class DecodeOperation<Output>: Operation, @unchecked Sendable {
    let url: URL
    private let work: (URL) -> Output?
    private(set) var output: Output?

    init(url: URL, work: @escaping (URL) -> Output?) {
        self.url = url
        self.work = work
    }

    override func main() {
        guard !isCancelled else { return }
        output = autoreleasepool { work(url) }
    }
}
