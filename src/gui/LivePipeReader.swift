import Foundation
import Darwin

/// One blocking POSIX read: return immediately when any pipe data is available.
/// Foundation's read(upToCount:) can accumulate a full buffer on macOS, which
/// deadlocks an interactive child waiting for an answer to a short prompt.
enum LivePipeReader {
    static let maximumChunkSize = 4096

    /// Call on a background queue. The caller owns the handle and must keep it
    /// open while reading. nil means EOF; errors must be handled by the caller.
    static func readChunk(from handle: FileHandle) throws -> Data? {
        var bytes = [UInt8](repeating: 0, count: maximumChunkSize)
        while true {
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(handle.fileDescriptor, buffer.baseAddress, buffer.count)
            }
            if count > 0 { return Data(bytes.prefix(count)) }
            if count == 0 { return nil }
            let readError = errno
            if readError == EINTR { continue }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(readError))
        }
    }
}
