import Foundation
import RappCore

enum DownloadResult { case bytes([UInt8]), file(URL) }
enum UploadData { case bytes([UInt8]), file(URL) }

/// A's `error` text, or "连接断开" / "已取消".
struct TransferFailure: Error { let reason: String }

/// Runs downloads and uploads one at a time, each on its own side connection
/// (spec §2.4, §4.1, §4.2). One per client process; everything on the main queue.
final class TransferQueue {
    /// "下载 app.log 45%", "上传 2/3 · app.log 45%", an error text; nil = idle.
    var onStatus: ((String?) -> Void)?
    var log: ((String) -> Void)?

    private let address: RemoteAddress
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

    init(address: RemoteAddress) {
        self.address = address
    }

    // MARK: Public

    func download(clip: UInt32, file: UInt16, name: String, total: UInt64, toDisk: Bool,
                  done: @escaping (Result<DownloadResult, TransferFailure>) -> Void) {
        let job = Job(label: name, work: .download(Download(clip: clip, file: file, name: name, total: total, toDisk: toDisk)),
                      finish: { done($0.map { $0 ?? .bytes([]) }) })
        enqueue(job)
    }

    func upload(item: UInt32, kind: ClipKind, uti: String, name: String, data: UploadData, label: String,
                done: @escaping (Result<Void, TransferFailure>) -> Void) {
        let total: UInt64
        switch data {
        case let .bytes(bytes):
            total = UInt64(bytes.count)
        case let .file(url):
            guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64 else {
                return done(.failure(TransferFailure(reason: "无法读取文件")))
            }
            total = size
        }
        let job = Job(label: label, work: .upload(Upload(item: item, kind: kind, uti: uti, name: name, data: data, total: total)),
                      finish: { result in done(result.map { _ in () }) })
        enqueue(job)
    }

    /// Stops the current transfer and drops the queued ones; what was received or sent stays.
    func cancel() {
        generation += 1
        connection?.cancel()
        connection = nil
        let all = queue
        queue = []
        running = nil
        for job in all { job.close() }
        setStatus(nil)
        for job in all { job.finish(.failure(TransferFailure(reason: "已取消"))) }
    }

    // MARK: Queue

    private final class Job {
        let label: String
        var work: Work
        let finish: (Result<DownloadResult?, TransferFailure>) -> Void
        /// Failed connection attempts since the last progress.
        var attempt = 0
        var handle: FileHandle?

        init(label: String, work: Work, finish: @escaping (Result<DownloadResult?, TransferFailure>) -> Void) {
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
        var buffer: [UInt8] = []
        var part: URL?
        var finalName = ""
    }

    private struct Upload {
        let item: UInt32, kind: ClipKind, uti: String, name: String, data: UploadData
        let total: UInt64
        var sent: UInt64 = 0
    }

    private func enqueue(_ job: Job) {
        queue.append(job)
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
                return complete(job, .failure(TransferFailure(reason: "无法写入 \(Self.downloadsDirectory().path)")))
            }
        } else {
            d.received = resumeOffset(partSize: UInt64(d.buffer.count), total: d.total)
            if d.received == 0 { d.buffer = [] }
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
            d.buffer = []
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
        if d.toDisk {
            do {
                try job.handle?.write(contentsOf: bytes)
            } catch {
                return complete(job, .failure(TransferFailure(reason: "无法写入 \(Self.downloadsDirectory().path)")))
            }
        } else {
            d.buffer.append(contentsOf: bytes)
        }
        d.received += UInt64(bytes.count)
        job.work = .download(d)
        job.attempt = 0
        progress(job, done: d.received, total: d.total)
        if d.received >= d.total { finishDownload(job) }
    }

    private func finishDownload(_ job: Job) {
        guard case let .download(d) = job.work else { return }
        guard d.toDisk, let part = d.part else { return complete(job, .success(.bytes(d.buffer))) }
        job.close()
        let directory = Self.downloadsDirectory()
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
        let directory = Self.downloadsDirectory()
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

    private static func downloadsDirectory() -> URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("rapp")
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
