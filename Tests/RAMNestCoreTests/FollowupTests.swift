import Foundation
import Darwin
import Testing
@testable import RAMNestCore
extension RAMNestTestSuite {
    struct SparseExtentFallbackTests {
        private let page = 65536
        private var length: Int { 20 * page + 37 }
        private struct Payload {
            let name: String, bytes: Data, checksum: String
            let pages: UInt64
        }
        private func payloads() -> [Payload] {
            var sparse = Data(repeating: 0, count: length)
            sparse[3 * page + 17] = 65; sparse[12 * page + 3] = 66
            var tail = sparse; tail[length - 1] = 67
            // Fixed reference digests include padded final pages and logical indices.
            return [
                Payload(name: "dense", bytes: Data(repeating: 90, count: length),
                        checksum: "b4a46de3ff39db4a7b03ca5f83e076b9a62c25b31111a822b561192901cc9e12", pages: 21),
                Payload(name: "sparse", bytes: tail,
                        checksum: "29f3ba0f44fb7f8e400c14aa46d6e889b4522aeb52e792d5515e3d0803fae8b2", pages: 3),
                Payload(name: "trailing-zero", bytes: sparse,
                        checksum: "a400a8dcb30f359dff80c704d37e9595d858b3d0fcafaa114b0d6504248992db", pages: 2),
                Payload(name: "zero", bytes: Data(repeating: 0, count: length),
                        checksum: "ed58828563a71e400ceb079b70c8d0816d2e55bb281afa7c598bb132dd9ad670", pages: 0)
            ]
        }
        private func fixture(_ body: (URL) throws -> Void) throws {
            let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("ramnest-sparse-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: root) }
            try body(root)
        }
        private func file(_ root: URL, _ name: String, _ bytes: Data, sparse: Bool = false) throws -> Int32 {
            let fd = open(root.appendingPathComponent(name).path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw NestError("Sparse test fixture open failed") }
            do {
                guard ftruncate(fd, off_t(bytes.count)) == 0 else { throw NestError("Sparse test truncate failed") }
                for offset in stride(from: 0, to: bytes.count, by: page) {
                    let count = min(page, bytes.count - offset)
                    if sparse && !bytes[offset..<(offset + count)].contains(where: { $0 != 0 }) { continue }
                    let wrote = bytes.withUnsafeBytes { pwrite(fd, $0.baseAddress!.advanced(by: offset), count, off_t(offset)) }
                    guard wrote == count else { throw NestError("Sparse test fixture write failed") }
                }
                return fd
            } catch { close(fd); throw error }
        }
        private func supported(_ bytes: Data) -> SparseContent.ExtentSeeker {
            { _, offset, whence in
                #expect(whence == SEEK_DATA)
                guard let next = bytes[Int(offset)...].firstIndex(where: { $0 != 0 }) else {
                    errno = ENXIO; return -1
                }
                return off_t(next)
            }
        }
        private func assertIdentity(_ result: SparseContent.Result, _ payload: Payload,
                                    sourceLocation: SourceLocation = SourceLocation(fileID: #fileID, filePath: #filePath,
                                                                                 line: #line, column: #column)) {
            #expect(result.checksum == "sparse64-v1:" + payload.checksum, Comment(rawValue: payload.name), sourceLocation: sourceLocation)
            #expect(result.allocated == payload.pages * UInt64(page), Comment(rawValue: payload.name), sourceLocation: sourceLocation)
        }
        private func assertCopy(_ source: Int32, _ payload: Payload, _ root: URL, _ name: String,
                                seek: SparseContent.ExtentSeeker) throws {
            let destination = try file(root, name, Data())
            defer { close(destination) }
            try SparseContent.copy(source, to: destination, size: Int64(payload.bytes.count), seekExtent: seek)
            #expect((try Data(contentsOf: root.appendingPathComponent(name))) == payload.bytes, Comment(rawValue: name))
            assertIdentity(try SparseContent.scan(destination, size: Int64(payload.bytes.count),
                                                 seekExtent: supported(payload.bytes)), payload)
        }
        @Test func `Sparse disk copies retain physical holes after durable flush`() throws {
            try fixture { root in
                var bytes = Data(repeating: 0, count: 8 * 1024 * 1024 + 17)
                bytes[3 * page + 7] = 65; bytes[bytes.count - 1] = 66
                let source = try file(root, "dense-zero-source", bytes)
                let destination = try file(root, "durable-sparse-copy", Data())
                defer { close(source); close(destination) }
                try SparseContent.copy(source, to: destination, size: Int64(bytes.count), seekExtent: { _, _, _ in errno = ENOTSUP; return -1 })
                #expect(fcopyfile(source, destination, nil, copyfile_flags_t(COPYFILE_STAT | COPYFILE_XATTR)) == 0)
                #expect(fsync(destination) == 0)
                var info = stat(); #expect(fstat(destination, &info) == 0)
                #expect(info.st_size == Int64(bytes.count))
                #expect(info.st_blocks * 512 < Int64(bytes.count / 2))
                #expect(try Data(contentsOf: root.appendingPathComponent("durable-sparse-copy")) == bytes)
            }
        }
        @Test func `Unsupported extents preserve checksum allocation and exact copy`() throws {
            try fixture { root in
                for payload in payloads() {
                    for physicalSparse in [false, true] {
                        let label = payload.name + (physicalSparse ? "-holes" : "-dense")
                        let source = try file(root, label, payload.bytes, sparse: physicalSparse)
                        defer { close(source) }
                        let optimized = try SparseContent.scan(source, size: Int64(length), seekExtent: supported(payload.bytes))
                        assertIdentity(optimized, payload)
                        for code in [EINVAL, ENOTSUP, ENOTTY] {
                            var calls = 0
                            let seek: SparseContent.ExtentSeeker = { _, _, whence in
                                #expect(whence == SEEK_DATA); calls += 1; errno = code; return -1
                            }
                            let scanned = try SparseContent.scan(source, size: Int64(length), seekExtent: seek)
                            assertIdentity(scanned, payload)
                            #expect(scanned.checksum == optimized.checksum)
                            #expect(scanned.allocated == optimized.allocated)
                            #expect(scanned.bytesRead == UInt64(length))
                            #expect(calls == 1, "fallback must disable later extent queries")
                            calls = 0
                            try assertCopy(source, payload, root, label + "-copy-\(code)", seek: seek)
                            #expect(calls == 1)
                        }
                    }
                }
            }
        }
        @Test func `Unsupported extents after successful skip`() throws {
            let payload = payloads()[1]
            try fixture { root in
                let source = try file(root, "source", payload.bytes, sparse: true)
                defer { close(source) }
                for code in [EINVAL, ENOTSUP, ENOTTY] {
                    var offsets: [off_t] = []
                    let seek: SparseContent.ExtentSeeker = { _, offset, whence in
                        #expect(whence == SEEK_DATA); offsets.append(offset)
                        if offsets.count == 1 { return off_t(3 * self.page + 17) }
                        errno = code; return -1
                    }
                    let result = try SparseContent.scan(source, size: Int64(length), seekExtent: seek)
                    assertIdentity(result, payload)
                    #expect(result.bytesRead == UInt64(length - 3 * page))
                    #expect(offsets == [0, off_t(4 * page)])
                    offsets = []
                    try assertCopy(source, payload, root, "copy-\(code)", seek: seek)
                    #expect(offsets == [0, off_t(4 * page)])
                }
            }
        }
        @Test func `ENXIO still ends extent walk`() throws {
            try fixture { root in
                for payload in [payloads()[2], payloads()[3]] {
                    let source = try file(root, payload.name, payload.bytes, sparse: true)
                    defer { close(source) }
                    var calls = 0
                    let extent = supported(payload.bytes)
                    let seek: SparseContent.ExtentSeeker = { fd, offset, whence in
                        calls += 1; return extent(fd, offset, whence)
                    }
                    let result = try SparseContent.scan(source, size: Int64(length), seekExtent: seek)
                    assertIdentity(result, payload)
                    #expect(result.bytesRead == payload.pages * UInt64(page))
                    #expect(calls == Int(payload.pages) + 1)
                    calls = 0
                    try assertCopy(source, payload, root, payload.name + "-copy", seek: seek)
                    #expect(calls == Int(payload.pages) + 1)
                }
            }
        }
        @Test func `Extent hard errors remain fatal before and after skip`() throws {
            let payload = payloads()[1]
            try fixture { root in
                let source = try file(root, "source", payload.bytes, sparse: true)
                defer { close(source) }
                for code in [EIO, EBADF, EPERM] {
                    for skip in [false, true] {
                        var calls = 0
                        let seek: SparseContent.ExtentSeeker = { _, _, _ in
                            calls += 1
                            if skip && calls == 1 { return off_t(3 * self.page + 17) }
                            errno = code; return -1
                        }
                        func check(_ error: Error) {
                            #expect((error as? NestError)?.code == 6)
                            #expect(error.localizedDescription.contains("errno \(code)"))
                        }
                        #expect { try SparseContent.scan(source, size: Int64(length), seekExtent: seek) } throws: { error in check(error); return true }
                        #expect(calls == (skip ? 2 : 1))
                        calls = 0
                        let destination = try file(root, "error-\(code)-\(skip)", Data())
                        defer { close(destination) }
                        #expect { try SparseContent.copy(source, to: destination, size: Int64(length), seekExtent: seek) } throws: { error in check(error); return true }
                        #expect(calls == (skip ? 2 : 1))
                    }
                }
            }
        }
        @Test func `Legacy and small hashes do not query extents`() throws {
            try fixture { root in
                let seek: SparseContent.ExtentSeeker = { _, _, _ in
                    Issue.record("legacy and small hashes must retain sequential SHA256"); errno = EIO; return -1
                }
                let dense = try file(root, "dense", payloads()[0].bytes)
                defer { close(dense) }
                let legacy = try SparseContent.scan(dense, size: Int64(length), legacy: true, seekExtent: seek)
                #expect(legacy.checksum == "f1874f462d463d368ff5923cc6bc1bd5e16e948d2108fc31057dd8c11407633e")
                #expect(legacy.allocated == 21 * UInt64(page))
                let bytes = Data("small payload".utf8), small = try file(root, "small", bytes)
                defer { close(small) }
                let result = try SparseContent.scan(small, size: Int64(bytes.count), seekExtent: seek)
                #expect(result.checksum == "5bfcd728e8dd338dac05e838f287e56fe4fcb154754cbfb408bb72042df90935")
                #expect(result.allocated == UInt64(page))
            }
        }
    }

}
