import Foundation

/// A whole file written so a crash or a full disk never leaves half of it: a new file beside `url` with `mode` from the
/// start, synced to disk, then renamed over `url`. `url` is the real file; a link to it stays as it was.
enum AtomicFile {
    /// Why the write failed, in the words a caller shows.
    struct Failure: Error, Equatable, Sendable, CustomStringConvertible {
        let why: String
        var description: String { why }
    }

    static func write(_ data: Data, to url: URL, mode: mode_t) throws(AtomicFile.Failure) {
        let path = url.path(percentEncoded: false)
        let temp = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).pilot-\(UUID().uuidString.prefix(8))").path(percentEncoded: false)
        let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL, mode)
        guard fd >= 0 else { throw Failure(why: "Could not write beside \(url.lastPathComponent): \(String(cString: strerror(errno)))") }
        // The umask may have narrowed `mode`: set it exactly before the first byte.
        var written = fchmod(fd, mode) == 0
        if written {
            written = data.withUnsafeBytes { bytes in
                var done = 0
                while done < bytes.count {
                    let n = Darwin.write(fd, bytes.baseAddress! + done, bytes.count - done)
                    if n <= 0 { return false }
                    done += n
                }
                return true
            }
        }
        written = written && fsync(fd) == 0
        // Each failure's own errno, read before the next call can change it.
        var why = written ? "" : String(cString: strerror(errno))
        close(fd)
        if written, rename(temp, path) != 0 { written = false; why = String(cString: strerror(errno)) }
        guard written else {
            unlink(temp)
            throw Failure(why: "Could not write \(url.lastPathComponent): \(why)")
        }
    }
}
