import Foundation
import RappCore

public enum DownloadResult { case bytes([UInt8]), file(URL) }
public enum UploadData { case bytes([UInt8]), file(URL) }

/// A's `error` text, or "连接断开" / "已取消".
public struct TransferFailure: Error { public let reason: String }

public enum TransferDirection: String { case down, up }
public enum TransferState: String { case running, done, failed, cancelled }

/// One transfer's state, sent through `TransferQueue.onProgress`.
public struct TransferProgress: Equatable {
    public let id: UInt32
    public let dir: TransferDirection
    /// A download's file name; an upload's file name, empty when it is not a file.
    public let name: String
    /// Only on uploads: what is sent (only `.files` lands in A's downloads folder).
    public let kind: ClipKind?
    public let done: UInt64
    public let total: UInt64
    public let state: TransferState
    /// Only on a `done` download that went to disk.
    public let path: String?
    /// Only on `failed`: A's error text, "连接断开" or "无法写入 …".
    public let error: String?
}

/// Runs downloads and uploads one at a time, each on its own side connection
/// (spec §2.4, §4.1, §4.2). One per client process; everything on the main queue.
public final class TransferQueue {
    /// Main queue: called with the size of each downloaded chunk (side-connection traffic).
    public var onBytes: ((Int) -> Void)?
    /// "下载 app.log 45%", "上传 2/3 · app.log 45%", an error text; nil = idle.
    public var onStatus: ((String?) -> Void)?
    /// Main queue: a transfer started, moved by a whole percent, or ended.
    public var onProgress: ((TransferProgress) -> Void)?
    public var log: ((String) -> Void)?

    private let address: RemoteAddress
    /// Where disk downloads go.
    private let downloads: URL
    private var nextID: UInt32 = 1
    private var queue: [Job] = []
    private var running: Job?
    private var connection: SideConnection?
    /// Bumped whenever the running transfer ends, so a pending retry knows it is stale.
    private var generation = 0
    private var status: String?
    /// Names given to (clip, file) downloads in this session, so a resume finds its `.rapp-part`.
    private var diskNames: [String: String] = [:]

    private static let partSuffix = ".rapp-part"
    private static let errorShownFor: TimeInterval = 5

    /// `downloads`: nil means `DataPaths.transfers` (<data root>/files/transfers).
    public init(address: RemoteAddress, downloads: URL? = nil) {
        self.address = address
        self.downloads = downloads
            ?? DataPaths.currentTransfers()
    }

    // MARK: Public

    @discardableResult
    public func download(clip: UInt32, file: UInt16, name: String, total: UInt64, toDisk: Bool,
                  done: @escaping (Result<DownloadResult, TransferFailure>) -> Void) -> UInt32 {
        let job = Job(id: takeID(), label: name, work: .download(Download(clip: clip, file: file, name: name, total: total, toDisk: toDisk)),
                      finish: { done($0.map { $0 ?? .bytes([]) }) })
        enqueue(job)
        return job.id
    }

    @discardableResult
    public func upload(item: UInt32, kind: ClipKind, uti: String, name: String, data: UploadData, label: String,
                done: @escaping (Result<Void, TransferFailure>) -> Void) -> UInt32 {
        let total: UInt64
        switch data {
        case let .bytes(bytes):
            total = UInt64(bytes.count)
        case let .file(url):
            guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64 else {
                let id = takeID()
                emit(TransferProgress(id: id, dir: .up, name: name, kind: kind, done: 0, total: 0, state: .failed,
                                      path: nil, error: "无法读取文件"))
                done(.failure(TransferFailure(reason: "无法读取文件")))
                return id
            }
            total = size
        }
        let job = Job(id: takeID(), label: label, work: .upload(Upload(item: item, kind: kind, uti: uti, name: name, data: data, total: total)),
                      finish: { result in done(result.map { _ in () }) })
        enqueue(job)
        return job.id
    }

    /// Stops one transfer: the running one disconnects (its `.rapp-part` stays) and the next starts;
    /// a queued one is dropped. An unknown id does nothing.
    public func cancel(id: UInt32) {
        guard let job = queue.first(where: { $0.id == id }) else { return }
        if running === job {
            generation += 1
            connection?.cancel()
            connection = nil
            job.close()
            queue.removeFirst()
            running = nil
            if queue.isEmpty { setStatus(nil) }
        } else {
            queue.removeAll { $0 === job }
        }
        let failure = TransferFailure(reason: "已取消")
        emitEnd(job, .failure(failure))
        job.finish(.failure(failure))
        pump()
    }

    /// Stops the current transfer and drops the queued ones; what was received or sent stays.
    public func cancel() {
        generation += 1
        connection?.cancel()
        connection = nil
        let all = queue
        queue = []
        running = nil
        for job in all { job.close() }
        setStatus(nil)
        for job in all {
            emitEnd(job, .failure(TransferFailure(reason: "已取消")))
            job.finish(.failure(TransferFailure(reason: "已取消")))
        }
    }

    // MARK: Queue

    private final class Job {
        let id: UInt32
        let label: String
        var work: Work
        /// The last whole percent sent through `onProgress`.
        var lastPercent: Int?
        let finish: (Result<DownloadResult?, TransferFailure>) -> Void
        /// Failed connection attempts since the last progress.
        var attempt = 0
        var handle: FileHandle?
        /// An in-memory download's bytes; kept here so appending never copies them.
        var buffer: [UInt8] = []

        init(id: UInt32, label: String, work: Work, finish: @escaping (Result<DownloadResult?, TransferFailure>) -> Void) {
            self.id = id
            self.label = label
            self.work = work
            self.finish = finish
        }

        func close() {
            try? handle?.close()
            handle = nil
        }
    }

    private enum Work { case download(Download), upload(Upload) }

    private struct Download {
        let clip: UInt32, file: UInt16, name: String
        var total: UInt64
        let toDisk: Bool
        var received: UInt64 = 0
        var part: URL?
        var finalName = ""
    }

    private struct Upload {
        let item: UInt32, kind: ClipKind, uti: String, name: String, data: UploadData
        let total: UInt64
        var sent: UInt64 = 0
    }

    private func takeID() -> UInt32 {
        defer { nextID += 1 }
        return nextID
    }

    private func enqueue(_ job: Job) {
        queue.append(job)
        emitRunning(job, done: 0, total: totalBytes(job))
        pump()
    }

    private func pump() {
        guard running == nil, let job = queue.first else { return }
        running = job
        begin(job)
    }

    private func begin(_ job: Job) {
        switch job.work {
        case .download: beginDownload(job)
        case .upload: beginUpload(job)
        }
    }

    private func complete(_ job: Job, _ result: Result<DownloadResult?, TransferFailure>) {
        guard running === job else { return }
        generation += 1
        connection?.cancel()
        connection = nil
        job.close()
        queue.removeFirst()
        running = nil
        emitEnd(job, result)
        switch result {
        case .success:
            if queue.isEmpty { setStatus(nil) }
        case let .failure(failure):
            setStatus("\(statusPrefix(job)) 失败：\(failure.reason)")
            let shown = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.errorShownFor) { [weak self] in
                guard let self, self.generation == shown, self.running == nil else { return }
                self.setStatus(nil)
            }
        }
        job.finish(result)
        pump()
    }

    /// After a disconnect: wait, then continue from the progress made; give up after `retryDelays`.
    private func retry(_ job: Job) {
        connection?.cancel()
        connection = nil
        guard job.attempt < retryDelays.count else {
            return complete(job, .failure(TransferFailure(reason: "连接断开")))
        }
        let delay = retryDelays[job.attempt]
        job.attempt += 1
        generation += 1
        let wanted = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generation == wanted, self.running === job else { return }
            self.begin(job)
        }
    }

    private func handleEnd(_ end: SideConnection.End, job: Job) {
        switch end {
        case let .hostError(reason): complete(job, .failure(TransferFailure(reason: reason)))
        case .disconnected: retry(job)
        }
    }

    // MARK: Status

    private func statusPrefix(_ job: Job) -> String {
        switch job.work {
        case .download: return "下载 \(job.label)"
        case .upload: return "上传 \(job.label)"
        }
    }

    private func progress(_ job: Job, done: UInt64, total: UInt64) {
        let percent = total == 0 ? 100 : min(100, Int(done * 100 / total))
        setStatus("\(statusPrefix(job)) \(percent)%")
        emitRunning(job, done: done, total: total)
    }

    // MARK: Progress events

    private func totalBytes(_ job: Job) -> UInt64 {
        switch job.work {
        case let .download(d): return d.total
        case let .upload(u): return u.total
        }
    }

    private func emit(_ event: TransferProgress) { onProgress?(event) }

    private func emitRunning(_ job: Job, done: UInt64, total: UInt64) {
        let percent = total == 0 ? 100 : min(100, Int(done * 100 / total))
        guard percent != job.lastPercent else { return }
        job.lastPercent = percent
        send(job, done: done, total: total, state: .running)
    }

    private func emitEnd(_ job: Job, _ result: Result<DownloadResult?, TransferFailure>) {
        let total = totalBytes(job)
        switch result {
        case let .success(value):
            var path: String?
            if case let .file(url)? = value { path = url.path }
            send(job, done: total, total: total, state: .done, path: path)
        case let .failure(failure):
            var received: UInt64 = 0
            switch job.work {
            case let .download(d): received = d.received
            case let .upload(u): received = u.sent
            }
            if failure.reason == "已取消" {
                send(job, done: received, total: total, state: .cancelled)
            } else {
                send(job, done: received, total: total, state: .failed, error: failure.reason)
            }
        }
    }

    private func send(_ job: Job, done: UInt64, total: UInt64, state: TransferState, path: String? = nil, error: String? = nil) {
        // Not `job.label`: that is the strip's "2/3 · name" (Sender).
        switch job.work {
        case let .download(d):
            emit(TransferProgress(id: job.id, dir: .down, name: d.name, kind: nil, done: done, total: total, state: state,
                                  path: path, error: error))
        case let .upload(u):
            emit(TransferProgress(id: job.id, dir: .up, name: u.name, kind: u.kind, done: done, total: total, state: state,
                                  path: path, error: error))
        }
    }

    private func setStatus(_ text: String?) {
        guard text != status else { return }
        status = text
        onStatus?(text)
    }

    // MARK: Download

    private func beginDownload(_ job: Job) {
        guard case var .download(d) = job.work else { return }
        if d.toDisk {
            do {
                try prepareDiskFile(job, &d)
            } catch {
                job.work = .download(d)
                return complete(job, .failure(TransferFailure(reason: "无法写入 \(downloads.path)")))
            }
        } else {
            d.received = resumeOffset(partSize: UInt64(job.buffer.count), total: d.total)
            if d.received == 0 { job.buffer = [] }
        }
        job.work = .download(d)
        progress(job, done: d.received, total: d.total)
        let side = SideConnection(address: address,
                                  first: .fetch(token: address.token, clip: d.clip, file: d.file, offset: d.received))
        side.onStart = { [weak self, weak job] total in
            guard let self, let job else { return }
            self.downloadStarted(job, total: total)
        }
        side.onChunk = { [weak self, weak job] bytes in
            guard let self, let job else { return }
            self.downloadChunk(job, bytes)
        }
        side.onEnd = { [weak self, weak job] end in
            guard let self, let job else { return }
            self.handleEnd(end, job: job)
        }
        connection = side
        side.start()
    }

    private func downloadStarted(_ job: Job, total: UInt64) {
        guard case var .download(d) = job.work else { return }
        if total != d.total {
            // The file on A is not the one announced: start over with what A says now.
            d.total = total
            d.received = 0
            job.buffer = []
            try? job.handle?.truncate(atOffset: 0)
            job.work = .download(d)
            connection?.cancel()
            connection = nil
            return begin(job)
        }
        if d.received >= d.total { finishDownload(job) }
    }

    private func downloadChunk(_ job: Job, _ bytes: [UInt8]) {
        guard case var .download(d) = job.work, !bytes.isEmpty else { return }
        onBytes?(bytes.count)
        if d.toDisk {
            do {
                try job.handle?.write(contentsOf: bytes)
            } catch {
                return complete(job, .failure(TransferFailure(reason: "无法写入 \(downloads.path)")))
            }
        } else {
            job.buffer.append(contentsOf: bytes)
        }
        d.received += UInt64(bytes.count)
        job.work = .download(d)
        job.attempt = 0
        progress(job, done: d.received, total: d.total)
        if d.received >= d.total { finishDownload(job) }
    }

    private func finishDownload(_ job: Job) {
        guard case let .download(d) = job.work else { return }
        guard d.toDisk, let part = d.part else { return complete(job, .success(.bytes(job.buffer))) }
        job.close()
        let directory = downloads
        let final = uniqueName(d.finalName, existing: Self.existingNames(in: directory, except: part.lastPathComponent))
        let url = directory.appendingPathComponent(final)
        do {
            try FileManager.default.moveItem(at: part, to: url)
        } catch {
            return complete(job, .failure(TransferFailure(reason: "无法写入 \(directory.path)")))
        }
        log?("downloaded \(url.path)")
        complete(job, .success(.file(url)))
    }

    /// Names the file on first use, then opens its `.rapp-part` at the resume point.
    private func prepareDiskFile(_ job: Job, _ d: inout Download) throws {
        let fm = FileManager.default
        let directory = downloads
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let key = "\(d.clip)/\(d.file)"
        if diskNames[key] == nil {
            diskNames[key] = uniqueName(safeFileName(d.name), existing: Self.existingNames(in: directory, except: nil))
        }
        d.finalName = diskNames[key]!
        let part = directory.appendingPathComponent(d.finalName + Self.partSuffix)
        d.part = part
        if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: nil) }
        let size = (try fm.attributesOfItem(atPath: part.path))[.size] as? UInt64 ?? 0
        d.received = resumeOffset(partSize: size, total: d.total)
        job.close()
        let handle = try FileHandle(forWritingTo: part)
        try handle.truncate(atOffset: d.received)
        try handle.seek(toOffset: d.received)
        job.handle = handle
    }

    /// File names in `directory`, a `.rapp-part` counting as the name without it.
    private static func existingNames(in directory: URL, except skipped: String?) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var set = Set<String>()
        for name in names where name != skipped {
            set.insert(name.hasSuffix(partSuffix) ? String(name.dropLast(partSuffix.count)) : name)
        }
        return set
    }

    // MARK: Upload

    private func beginUpload(_ job: Job) {
        guard case let .upload(u) = job.work else { return }
        job.close()
        if case let .file(url) = u.data {
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                return complete(job, .failure(TransferFailure(reason: "无法读取文件")))
            }
            job.handle = handle
        }
        progress(job, done: u.sent, total: u.total)
        let side = SideConnection(address: address,
                                  first: .put(token: address.token, item: u.item, kind: u.kind, uti: u.uti, name: u.name, total: u.total))
        side.onStart = { [weak self, weak job] have in
            guard let self, let job, case var .upload(u) = job.work else { return }
            u.sent = min(have, u.total)
            job.work = .upload(u)
            self.progress(job, done: u.sent, total: u.total)
            self.sendNextChunk(job)
        }
        side.onChunk = { [weak self, weak job] bytes in
            // An empty chunk: everything has arrived on A.
            guard let self, let job, bytes.isEmpty else { return }
            self.complete(job, .success(nil))
        }
        side.onEnd = { [weak self, weak job] end in
            guard let self, let job else { return }
            self.handleEnd(end, job: job)
        }
        connection = side
        side.start()
    }

    /// Each chunk goes out after the previous one has left the socket.
    private func sendNextChunk(_ job: Job) {
        guard running === job, case let .upload(u) = job.work, u.sent < u.total else { return }
        let count = Int(min(UInt64(chunkSize), u.total - u.sent))
        let chunk: [UInt8]
        switch u.data {
        case let .bytes(bytes):
            chunk = Array(bytes[Int(u.sent)..<Int(u.sent) + count])
        case .file:
            do {
                try job.handle?.seek(toOffset: u.sent)
                guard let data = try job.handle?.read(upToCount: count), !data.isEmpty else { throw CocoaError(.fileReadUnknown) }
                chunk = [UInt8](data)
            } catch {
                return complete(job, .failure(TransferFailure(reason: "无法读取文件")))
            }
        }
        connection?.send(.chunk(chunk)) { [weak self, weak job] in
            guard let self, let job, self.running === job, case var .upload(u) = job.work else { return }
            u.sent += UInt64(chunk.count)
            job.work = .upload(u)
            job.attempt = 0
            self.progress(job, done: u.sent, total: u.total)
            self.sendNextChunk(job)
        }
    }
}
