import CryptoKit
import Darwin
import Foundation
import JavaScriptCore
import zlib

// Bytes under the prelude (spec raycast-extensions T26, Speedtest): the native half of Node's binary file descriptors,
// zlib and byte hashes. Bytes cross as Uint8Arrays (JavaScriptCore's typed arrays), copied once each way; the prelude
// makes each a Buffer. A failure comes back as `{"error": <Node's code>, "message": …}`, as Native.swift's do.
// - Files by descriptor (node.js's open, read, write, close and the f-calls): an open that may write (any of O_WRONLY,
//   O_RDWR, O_CREAT, O_TRUNC, O_APPEND) is judged by Measure.refusesWrite first, and under --measure opens O_NOFOLLOW,
//   so a link put at the name after the check is not followed; fchmod and futimes there act only on a descriptor this
//   run opened to write. Every descriptor call takes only a descriptor this run opened, so none reaches the host's own
//   stdin, stdout (Pilot's protocol) or stderr.
// - zlib (zlib.js): macOS's own libz, the library Node's zlib binds, one z_stream per id in Node's seven modes (deflate,
//   inflate, gzip, gunzip, raw and unzip), fed chunk by chunk with Node's flush flags; zlib.js adds Node's classes.
@MainActor enum Bytes {
    private static var streams: [Int: ZStream] = [:]
    private static var last = 0
    /// Descriptors this run opened, and of them the ones opened to write: the only ones write takes, and under
    /// --measure the only ones fchmod and futimes act on.
    private static var opened: Set<Int32> = [], writing: Set<Int32> = []
    private static func ours(_ fd: Int32) -> [String: Any]? { opened.contains(fd) ? nil : Host.failure(errno: EBADF, "fd \(fd)") }

    static func install(into native: JSValue) {
        func add(_ name: String, _ block: Any) { native.setObject(block, forKeyedSubscript: name as NSString) }
        // MARK: Files by descriptor
        add("fdOpen", { (path: String, flags: Int32, mode: Int) -> Any in
            let writes = flags & (O_WRONLY | O_RDWR | O_CREAT | O_TRUNC | O_APPEND) != 0
            if writes, let refused = Measure.refusesWrite("open", path) { return refused }
            let fd = open(path, flags | O_CLOEXEC | (writes && Measure.on ? O_NOFOLLOW : 0), mode_t(mode))
            guard fd >= 0 else { return Host.failure(errno: errno, path) }
            opened.insert(fd)
            if writes { writing.insert(fd) }
            return Int(fd)
        } as @convention(block) (String, Int32, Int) -> Any)
        add("fdRead", { (fd: Int32, length: Int, position: Double) -> Any in
            if let refused = ours(fd) { return refused }
            var buffer = [UInt8](repeating: 0, count: max(0, min(length, 16 << 20)))
            let count = buffer.withUnsafeMutableBytes { position < 0 ? read(fd, $0.baseAddress, $0.count) : pread(fd, $0.baseAddress, $0.count, off_t(position)) }
            guard count >= 0 else { return Host.failure(errno: errno, "fd \(fd)") }
            return array(buffer.prefix(count))
        } as @convention(block) (Int32, Int, Double) -> Any)
        add("fdWrite", { (fd: Int32, data: JSValue, position: Double) -> Any in
            guard writing.contains(fd) else { return Host.failure(errno: EBADF, "fd \(fd)") }
            guard let bytes = bytes(data) else { return ["error": "ERR_INVALID_ARG_TYPE", "message": "write takes bytes"] }
            let count = bytes.withUnsafeBytes { position < 0 ? write(fd, $0.baseAddress, $0.count) : pwrite(fd, $0.baseAddress, $0.count, off_t(position)) }
            return count >= 0 ? count : Host.failure(errno: errno, "fd \(fd)")
        } as @convention(block) (Int32, JSValue, Double) -> Any)
        add("fdClose", { (fd: Int32) -> Any in
            if let refused = ours(fd) { return refused }
            opened.remove(fd)
            writing.remove(fd)
            return close(fd) == 0 ? true : Host.failure(errno: errno, "fd \(fd)")
        } as @convention(block) (Int32) -> Any)
        add("fdStat", { (fd: Int32) -> Any in
            if let refused = ours(fd) { return refused }
            var info = stat()
            guard fstat(fd, &info) == 0 else { return Host.failure(errno: errno, "fd \(fd)") }
            return Host.stats(info)
        } as @convention(block) (Int32) -> Any)
        add("fdChmod", { (fd: Int32, mode: Int) -> Any in
            if let refused = ours(fd) { return refused }
            if Measure.on, !writing.contains(fd) { return Host.failure(errno: EPERM, "fd \(fd)") }
            return fchmod(fd, mode_t(mode)) == 0 ? true : Host.failure(errno: errno, "fd \(fd)")
        } as @convention(block) (Int32, Int) -> Any)
        add("fdTimes", { (fd: Int32, atime: Double, mtime: Double) -> Any in
            if let refused = ours(fd) { return refused }
            if Measure.on, !writing.contains(fd) { return Host.failure(errno: EPERM, "fd \(fd)") }
            var times = [timespec(atime), timespec(mtime)]
            return futimens(fd, &times) == 0 ? true : Host.failure(errno: errno, "fd \(fd)")
        } as @convention(block) (Int32, Double, Double) -> Any)
        // MARK: Files by path
        add("fsChmod", { (path: String, mode: Int) -> Any in
            if let refused = Measure.refusesWrite("chmod", path) { return refused }
            return chmod(path, mode_t(mode)) == 0 ? true : Host.failure(errno: errno, path)
        } as @convention(block) (String, Int) -> Any)
        add("fsTimes", { (path: String, atime: Double, mtime: Double, follow: Bool) -> Any in
            if let refused = Measure.refusesWrite("utimes", path) { return refused }
            var times = [timespec(atime), timespec(mtime)]
            return utimensat(AT_FDCWD, path, &times, follow ? 0 : AT_SYMLINK_NOFOLLOW) == 0 ? true : Host.failure(errno: errno, path)
        } as @convention(block) (String, Double, Double, Bool) -> Any)
        add("fsReadlink", { (path: String) -> Any in
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            let count = readlink(path, &buffer, buffer.count)
            guard count >= 0 else { return Host.failure(errno: errno, path) }
            return String(decoding: buffer.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        } as @convention(block) (String) -> Any)
        add("fsReadBytes", { (path: String) -> Any in
            do { return array(try Data(contentsOf: URL(filePath: path))) } catch { return Host.failure(error, path) }
        } as @convention(block) (String) -> Any)
        // MARK: Hashes, ids
        add("hashBytes", { (algorithm: String, data: JSValue) -> Any in
            guard let bytes = bytes(data) else { return ["error": "ERR_INVALID_ARG_TYPE", "message": "a hash takes bytes"] }
            return Host.digest(algorithm, bytes).map(Host.hex) ?? ["error": "ERR_CRYPTO_INVALID_DIGEST", "message": "Pilot has no digest \(algorithm)"]
        } as @convention(block) (String, JSValue) -> Any)
        // The process's uid, gid and umask (node-tar reads them to choose modes and owners).
        add("ids", { () -> Any in
            let mask = umask(0)
            umask(mask)
            return [Int(getuid()), Int(getgid()), Int(mask)]
        } as @convention(block) () -> Any)
        // MARK: zlib
        add("zlibOpen", { (mode: Int, options: [String: Any]) -> Any in
            func number(_ key: String, _ standard: Int32) -> Int32 { (options[key] as? NSNumber).map { Int32(truncating: $0) } ?? standard }
            guard let stream = ZStream(mode: mode, level: number("level", Z_DEFAULT_COMPRESSION), windowBits: number("windowBits", 15),
                                       memLevel: number("memLevel", 8), strategy: number("strategy", Z_DEFAULT_STRATEGY)) else {
                return ["error": "ERR_ZLIB_INITIALIZATION_FAILED", "message": "Initialization failed"]
            }
            last += 1
            streams[last] = stream
            return last
        } as @convention(block) (Int, [String: Any]) -> Any)
        add("zlibPush", { (id: Int, data: JSValue, flush: Int32) -> Any in
            guard let stream = streams[id] else { return ["error": "ERR_ZLIB_BINDING_CLOSED", "message": "zlib binding closed"] }
            guard let input = bytes(data) else { return ["error": "ERR_INVALID_ARG_TYPE", "message": "zlib takes bytes"] }
            let (out, failure) = stream.push(input, flush: flush)
            if let failure { return failure }
            guard let context = data.context, let answer = JSValue(newObjectIn: context) else { return NSNull() }
            answer.setObject(array(out), forKeyedSubscript: "out" as NSString)
            answer.setObject(stream.ended, forKeyedSubscript: "end" as NSString)
            return answer
        } as @convention(block) (Int, JSValue, Int32) -> Any)
        add("zlibReset", { (id: Int) in streams[id]?.reset() } as @convention(block) (Int) -> Void)
        add("zlibClose", { (id: Int) in streams[id] = nil } as @convention(block) (Int) -> Void)
        add("crc32", { (data: JSValue, value: Double) -> Any in
            guard let input = bytes(data) else { return ["error": "ERR_INVALID_ARG_TYPE", "message": "crc32 takes bytes"] }
            return Double(input.withUnsafeBytes { zlib.crc32(uLong(value), $0.baseAddress?.assumingMemoryBound(to: Bytef.self), uInt($0.count)) })
        } as @convention(block) (JSValue, Double) -> Any)
    }

    // MARK: Typed arrays

    /// The bytes of a typed array or an ArrayBuffer, copied; nil for any other value.
    static func bytes(_ value: JSValue) -> Data? {
        guard let context = value.context?.jsGlobalContextRef, let ref = value.jsValueRef, value.isObject,
              let object = JSValueToObject(context, ref, nil) else { return nil }
        let type = JSValueGetTypedArrayType(context, ref, nil)
        switch type {
        case kJSTypedArrayTypeNone: return nil
        case kJSTypedArrayTypeArrayBuffer:
            let count = JSObjectGetArrayBufferByteLength(context, object, nil)
            guard count > 0, let start = JSObjectGetArrayBufferBytesPtr(context, object, nil) else { return Data() }
            return Data(bytes: start, count: count)
        default:
            // The pointer is to the view's backing buffer's start; its own bytes begin at its offset.
            let count = JSObjectGetTypedArrayByteLength(context, object, nil), offset = JSObjectGetTypedArrayByteOffset(context, object, nil)
            guard count > 0, let start = JSObjectGetTypedArrayBytesPtr(context, object, nil) else { return Data() }
            return Data(bytes: start + offset, count: count)
        }
    }

    /// `data` as a new Uint8Array in `context`, by default the one calling in.
    static func array<C: Collection>(_ data: C, in given: JSContext? = nil) -> Any where C.Element == UInt8 {
        guard let context = given ?? JSContext.current(), let ref = context.jsGlobalContextRef,
              let object = JSObjectMakeTypedArray(ref, kJSTypedArrayTypeUint8Array, data.count, nil) else { return NSNull() }
        if !data.isEmpty, let start = JSObjectGetTypedArrayBytesPtr(ref, object, nil) {
            _ = UnsafeMutableRawBufferPointer(start: start, count: data.count).copyBytes(from: data)
        }
        return JSValue(jsValueRef: object, in: context) as Any
    }

    private static func timespec(_ ms: Double) -> Darwin.timespec {
        Darwin.timespec(tv_sec: Int(floor(ms / 1000)), tv_nsec: Int((ms - floor(ms / 1000) * 1000) * 1_000_000))
    }
}

/// One of Node's zlib streams on libz: `mode` is Node's number (1 deflate, 2 inflate, 3 gzip, 4 gunzip, 5 deflate raw,
/// 6 inflate raw, 7 unzip), its window bits made what libz takes for that wrapper.
final class ZStream {
    let inflating: Bool
    private let gunzip: Bool
    private var z = z_stream()
    private(set) var ended = false

    init?(mode: Int, level: Int32, windowBits: Int32, memLevel: Int32, strategy: Int32) {
        guard (1...7).contains(mode) else { return nil }
        inflating = [2, 4, 6, 7].contains(mode)
        gunzip = mode == 4 || mode == 7
        let bits = switch mode { case 3, 4: windowBits + 16; case 5, 6: -windowBits; case 7: windowBits + 32; default: windowBits }
        let size = Int32(MemoryLayout<z_stream>.size)
        let status = inflating ? inflateInit2_(&z, bits, ZLIB_VERSION, size)
            : deflateInit2_(&z, level, Z_DEFLATED, bits, memLevel, strategy, ZLIB_VERSION, size)
        guard status == Z_OK else { return nil }
    }

    deinit { _ = inflating ? inflateEnd(&z) : deflateEnd(&z) }

    func reset() {
        _ = inflating ? inflateReset(&z) : deflateReset(&z)
        ended = false
    }

    /// Feeds `input` with Node's `flush` flag; answers what came out, or the failure in Node's words. A gunzip reads on
    /// into a next gzip member, as Node's does; anything after the stream's end is otherwise left. A Z_FINISH that
    /// leaves an inflate short of its end is Node's "unexpected end of file".
    func push(_ input: Data, flush: Int32) -> (Data, [String: Any]?) {
        guard !ended else { return (Data(), nil) }
        var out = Data(), buffer = [UInt8](repeating: 0, count: 65_536), status = Z_OK
        input.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            z.next_in = UnsafeMutablePointer(mutating: source.baseAddress?.assumingMemoryBound(to: Bytef.self))
            z.avail_in = uInt(source.count)
            while true {
                buffer.withUnsafeMutableBufferPointer { into in
                    z.next_out = into.baseAddress
                    z.avail_out = uInt(into.count)
                    status = inflating ? inflate(&z, flush) : deflate(&z, flush)
                    out.append(into.baseAddress!, count: into.count - Int(z.avail_out))
                }
                if status == Z_STREAM_END {
                    if gunzip, z.avail_in > 0, z.next_in.pointee == 0x1f { inflateReset(&z); continue }
                    ended = true
                    break
                }
                // Z_BUF_ERROR is no progress, not a failure: all of this input is through.
                guard status == Z_OK || status == Z_BUF_ERROR else { break }
                if z.avail_out != 0 { break }
            }
            z.next_in = nil
            z.next_out = nil
        }
        if status == Z_OK || status == Z_BUF_ERROR || status == Z_STREAM_END {
            if inflating, flush == Z_FINISH, !ended { return (out, failure(Z_BUF_ERROR, "unexpected end of file")) }
            return (out, nil)
        }
        return (out, failure(status, z.msg.map { String(cString: $0) }))
    }

    private func failure(_ code: Int32, _ message: String?) -> [String: Any] {
        let names: [Int32: String] = [Z_NEED_DICT: "Z_NEED_DICT", Z_ERRNO: "Z_ERRNO", Z_STREAM_ERROR: "Z_STREAM_ERROR", Z_DATA_ERROR: "Z_DATA_ERROR",
                                      Z_MEM_ERROR: "Z_MEM_ERROR", Z_BUF_ERROR: "Z_BUF_ERROR", Z_VERSION_ERROR: "Z_VERSION_ERROR"]
        let standard = code == Z_NEED_DICT ? "Missing dictionary" : code == Z_DATA_ERROR ? "invalid data" : "zlib error"
        return ["error": names[code] ?? "Z_ERRNO", "message": message ?? standard, "errno": Int(code)]
    }
}

extension Host {
    /// A stat as the prelude's Stats reads it.
    static func stats(_ info: Darwin.stat) -> [String: Any] {
        let type = info.st_mode & S_IFMT
        func ms(_ t: timespec) -> Double { Double(t.tv_sec) * 1000 + Double(t.tv_nsec) / 1_000_000 }
        return ["size": Double(info.st_size), "mode": Int(info.st_mode), "mtimeMs": ms(info.st_mtimespec), "birthtimeMs": ms(info.st_birthtimespec),
                "atimeMs": ms(info.st_atimespec), "ctimeMs": ms(info.st_ctimespec), "uid": Int(info.st_uid), "gid": Int(info.st_gid),
                "ino": Double(info.st_ino), "dev": Int(info.st_dev), "nlink": Int(info.st_nlink),
                "isFile": type == S_IFREG, "isDirectory": type == S_IFDIR, "isSymbolicLink": type == S_IFLNK]
    }
}
