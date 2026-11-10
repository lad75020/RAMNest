import Foundation
import CryptoKit
import Darwin

// Versioned content identity independent of filesystem extent boundaries. Sparse
// hashes include apparent size and every nonzero 64 KiB logical page. Zero pages
// normalize to holes in both the native tree and this quota policy.
enum SparseContent {
    struct Result { var checksum: String; var allocated: UInt64; var bytesRead: UInt64; var sha256Bytes: UInt64 = 0 }
    typealias ExtentSeeker = (Int32, off_t, Int32) -> off_t
    // SEEK_DATA is optional on source filesystems. Other errors
    // still fail closed; ENXIO retains its separate end-of-data meaning.
    private static func unsupportedExtents(_ error: Int32) -> Bool {
        error == EINVAL || error == ENOTSUP || error == ENOTTY
    }
    static func copy(_ source: Int32, to destination: Int32, size: Int64,
                     seekExtent: ExtentSeeker = Darwin.lseek) throws {
        var buffer = [UInt8](repeating: 0, count: 65536)
        var info = stat();guard fstat(source, &info) == 0 else { throw NestError("Cannot inspect sparse copy source.", code: NestError.Code.retained) }
        var holes: [(Int64, Int64)] = []
        func recordHole(_ start: Int64, _ end: Int64) {
            guard end > start else { return }
            if let last = holes.last, last.1 == start { holes[holes.count - 1].1 = end }
            else { holes.append((start, end)) }
        }
        var position: Int64 = 0, extents = info.st_flags & UInt32(UF_COMPRESSED) == 0
        while position < size {
            if extents {
                let data = seekExtent(source, position, SEEK_DATA)
                if data < 0 {
                    let error = errno
                    if error == ENXIO { recordHole(position, size); break }
                    if unsupportedExtents(error) { extents = false }
                    else { throw NestError("Cannot query copy extents (errno \(error)).", code: NestError.Code.retained) }
                } else {
                    let next = max(position, data / 65536 * 65536)
                    recordHole(position, min(next, size)); position = next
                    if position >= size { break }
                }
            }
            let count = Int(min(Int64(65536), size-position));var done = 0
            while done < count {
                let got = buffer.withUnsafeMutableBytes { pread(source, $0.baseAddress!.advanced(by: done), count-done, position+Int64(done)) }
                if got < 0 && errno == EINTR { continue }
                guard got > 0 else { throw NestError("Sparse copy source changed.", code: NestError.Code.retained) }
                done += got
            }
            if buffer.prefix(count).contains(where: { $0 != 0 }) {
                done = 0
                while done < count {
                    let wrote = buffer.withUnsafeBytes { pwrite(destination, $0.baseAddress!.advanced(by: done), count-done, position+Int64(done)) }
                    if wrote < 0 && errno == EINTR { continue }
                    guard wrote > 0 else { throw NestError("Sparse copy write failed.", code: NestError.Code.retained) }
                    done += wrote
                }
            } else { recordHole(position, position + Int64(count)) }
            position += Int64(count)
        }
        guard ftruncate(destination, size) == 0 else { throw NestError("Sparse copy length failed.", code: NestError.Code.retained) }
        // APFS can allocate skipped zero ranges when dirty data is flushed.
        // Deallocate only source-proven holes/zero blocks after all writes and
        // length changes; partially nonzero filesystem blocks remain untouched.
        if !holes.isEmpty {
            var filesystem = statfs()
            guard fstatfs(destination, &filesystem) == 0, filesystem.f_bsize > 0 else { throw NestError("Cannot inspect sparse copy destination.", code: NestError.Code.retained) }
            let type = withUnsafePointer(to: &filesystem.f_fstypename) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
            }
            if type == "apfs" {
                let block = Int64(filesystem.f_bsize)
                for (start, end) in holes {
                    let alignedEnd = end / block * block
                    let adjustment = (block - start % block) % block
                    guard alignedEnd > start, alignedEnd - start > adjustment else { continue }
                    let alignedStart = start + adjustment
                    var hole = fpunchhole_t(fp_flags: 0, reserved: 0, fp_offset: alignedStart, fp_length: alignedEnd - alignedStart)
                    var result: Int32
                    repeat { result = fcntl(destination, F_PUNCHHOLE, &hole) } while result < 0 && errno == EINTR
                    guard result == 0 else { throw NestError("Cannot preserve APFS sparse allocation (errno \(errno)).", code: NestError.Code.retained) }
                }
            }
        }
    }
    static func scan(_ fd: Int32, size: Int64, legacy: Bool = false, verification: FileVerification = .sha256,
                     seekExtent: ExtentSeeker = Darwin.lseek) throws -> Result {
        guard size >= 0 else { throw NestError("Invalid sparse length.", code: NestError.Code.retained) }
        let sparseHash = size > 1 << 20 && !legacy
        // nil is a real no-content-SHA path, including sparse page hashes.
        var hash: SHA256? = verification == .sha256 ? SHA256() : nil
        var allocated: UInt64 = 0, bytesRead: UInt64 = 0, sha256Bytes: UInt64 = 0
        if sparseHash { hash?.update(data: Data("RAMNest sparse64 v1 length=\(size)\n".utf8)) }
        var info = stat();guard fstat(fd, &info) == 0 else { throw NestError("Cannot inspect sparse source.", code: NestError.Code.retained) }
        var position: Int64 = 0, extents = sparseHash && info.st_flags & UInt32(UF_COMPRESSED) == 0
        var buffer = [UInt8](repeating: 0, count: 65536)
        while position < size {
            if extents {
                errno = 0
                let data = seekExtent(fd, position, SEEK_DATA)
                if data < 0 {
                    let error = errno
                    if error == ENXIO { break }
                    if unsupportedExtents(error) { extents = false }
                    else { throw NestError("Cannot query sparse extents (errno \(error)).", code: NestError.Code.retained) }
                } else { position = max(position, (data / 65536) * 65536); if position >= size { break } }
            }
            let count = Int(min(Int64(65536), size-position))
            _ = buffer.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
            var done = 0
            while done < count {
                let got = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress!.advanced(by: done), count-done, position+Int64(done)) }
                if got < 0 && errno == EINTR { continue }
                guard got > 0 else { throw NestError("Source changed during sparse read.", code: NestError.Code.retained) }
                done += got; bytesRead += UInt64(got)
            }
            let nonzero = buffer.contains { $0 != 0 }
            if nonzero { allocated += 65536 }
            if hash != nil && sparseHash {
                if nonzero {
                    hash?.update(data: Data("page=\(position/65536)\n".utf8))
                    hash?.update(data: Data(SHA256.hash(data: Data(buffer))))
                    sha256Bytes += 65536
                }
            } else if hash != nil { hash?.update(data: Data(buffer.prefix(count))); sha256Bytes += UInt64(count) }
            position += Int64(count)
        }
        let checksum = hash.map { $0.finalize().map { String(format: "%02x", $0) }.joined() }
        return Result(checksum: checksum.map { (sparseHash ? "sparse64-v1:" : "") + $0 } ?? "", allocated: allocated, bytesRead: bytesRead, sha256Bytes: sha256Bytes)
    }
}
