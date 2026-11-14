import CZlib

/// Thrown when encoded data cannot be decoded.
public struct CodecError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

private let zlibBufferSize = 64 * 1024

private func makeStream() -> UnsafeMutablePointer<z_stream> {
    // zlib keeps a back-pointer to the z_stream, so it needs a stable address.
    let p = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
    p.initialize(to: z_stream())
    return p
}

/// A zlib deflate stream that lives for a whole connection. Every `compress`
/// call ends with a sync flush, so its output can be decompressed on its own,
/// while the dictionary built from earlier calls is kept for later ones.
public final class DeflateStream {
    private var strm = makeStream()

    public init(level: Int32 = 6) {
        let rc = deflateInit_(strm, level, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        precondition(rc == Z_OK, "deflateInit failed: \(rc)")
    }

    deinit {
        deflateEnd(strm)
        strm.deallocate()
    }

    public func compress(_ input: [UInt8]) -> [UInt8] {
        DeflateStream.run(strm, input)
    }

    /// Compresses `input` like `compress` when the output is at most `limit`
    /// bytes. Otherwise the stream is left as it was and `fits` is false; `data`
    /// is then the output that would have been sent (only its size matters).
    public func compress(_ input: [UInt8], ifAtMost limit: Int) -> (fits: Bool, data: [UInt8]) {
        let trial = makeStream()
        let rc = deflateCopy(trial, strm)
        precondition(rc == Z_OK, "deflateCopy failed: \(rc)")
        let data = DeflateStream.run(trial, input)
        if data.count > limit {
            deflateEnd(trial)
            trial.deallocate()
            return (false, data)
        }
        deflateEnd(strm)
        strm.deallocate()
        strm = trial
        return (true, data)
    }

    private static func run(_ strm: UnsafeMutablePointer<z_stream>, _ input: [UInt8]) -> [UInt8] {
        var output = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: zlibBufferSize)
        input.withUnsafeBufferPointer { inPtr in
            strm.pointee.next_in = UnsafeMutablePointer(mutating: inPtr.baseAddress)
            strm.pointee.avail_in = uInt(inPtr.count)
            var filled: Bool
            repeat {
                let produced: Int = buffer.withUnsafeMutableBufferPointer { outPtr in
                    strm.pointee.next_out = outPtr.baseAddress
                    strm.pointee.avail_out = uInt(outPtr.count)
                    _ = deflate(strm, Z_SYNC_FLUSH)
                    return outPtr.count - Int(strm.pointee.avail_out)
                }
                output.append(contentsOf: buffer[0..<produced])
                filled = produced == buffer.count
            } while filled
            strm.pointee.next_in = nil
        }
        return output
    }

    /// Drops the dictionary. The peer's `InflateStream` must be reset at the same point.
    public func reset() {
        deflateReset(strm)
    }
}

/// The receiving side of `DeflateStream`.
public final class InflateStream {
    private let strm = makeStream()

    public init() {
        let rc = inflateInit_(strm, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        precondition(rc == Z_OK, "inflateInit failed: \(rc)")
    }

    deinit {
        inflateEnd(strm)
        strm.deallocate()
    }

    /// Throws once the output would grow past `limit` bytes, so a small
    /// compressed input cannot make the receiver allocate without bound.
    public func decompress(_ input: [UInt8], limit: Int = .max) throws -> [UInt8] {
        var output = [UInt8]()
        var tooLarge = false
        var buffer = [UInt8](repeating: 0, count: zlibBufferSize)
        var failure: Int32 = Z_OK
        input.withUnsafeBufferPointer { inPtr in
            strm.pointee.next_in = UnsafeMutablePointer(mutating: inPtr.baseAddress)
            strm.pointee.avail_in = uInt(inPtr.count)
            var filled: Bool
            repeat {
                var rc: Int32 = Z_OK
                let produced: Int = buffer.withUnsafeMutableBufferPointer { outPtr in
                    strm.pointee.next_out = outPtr.baseAddress
                    strm.pointee.avail_out = uInt(outPtr.count)
                    rc = inflate(strm, Z_SYNC_FLUSH)
                    return outPtr.count - Int(strm.pointee.avail_out)
                }
                if produced > limit - output.count {
                    tooLarge = true
                    break
                }
                output.append(contentsOf: buffer[0..<produced])
                filled = produced == buffer.count
                // Z_BUF_ERROR only means "nothing more to do with this input".
                if rc != Z_OK && rc != Z_BUF_ERROR && rc != Z_STREAM_END {
                    failure = rc
                    break
                }
            } while filled
            strm.pointee.next_in = nil
        }
        if tooLarge {
            throw CodecError("decompressed data is larger than the frame allows")
        }
        if failure != Z_OK {
            throw CodecError("inflate failed (zlib error \(failure))")
        }
        return output
    }

    public func reset() {
        inflateReset(strm)
    }
}
