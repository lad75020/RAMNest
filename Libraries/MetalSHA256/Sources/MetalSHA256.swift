import Foundation
import CMetalSHA256

public struct MetalSHA256Error: Error, CustomStringConvertible {
    public let status: Int32
    public let description: String
}
private func requireStatus(_ status: Int32) throws {
    if status != MS256_OK {
        var text = [CChar](repeating: 0, count: 2048)
        _ = ms256_last_error(&text, text.count)
        throw MetalSHA256Error(status: status, description: String(cString: text))
    }
}
public struct MetalSHA256Message: Sendable {
    public let offset: UInt64, length: UInt64
    public init(offset: UInt64, length: UInt64) { self.offset = offset; self.length = length }
}
public struct MetalSHA256Metrics: Sendable {
    public let completedCommands: UInt64, messageCount: UInt64, workloadBytes: UInt64
    public let gpuStartSeconds: Double?, gpuEndSeconds: Double?, gpuSeconds: Double?
    init(_ m: MS256Metrics) {
        completedCommands = m.completed_commands; messageCount = m.message_count; workloadBytes = m.workload_bytes
        gpuStartSeconds = m.gpu_start_seconds > 0 ? m.gpu_start_seconds : nil
        gpuEndSeconds = m.gpu_end_seconds > 0 ? m.gpu_end_seconds : nil
        gpuSeconds = m.gpu_seconds > 0 ? m.gpu_seconds : nil
    }
}
public struct MetalSHA256Result: Sendable {
    /// Flat N*32 bytes; digest i occupies i*32 ..< (i+1)*32.
    public let digests: Data
    public let metrics: MetalSHA256Metrics
}
public struct MetalSHA256Info: Sendable {
    public let deviceName: String, shaderSHA256: String
    public let unifiedMemory: Bool
    public let maxBufferLength: UInt64, maxPackedBytes: UInt64, maxMessages: UInt64, maxMessageBytes: UInt64
    public let threadExecutionWidth: UInt64, threadsPerGroup: UInt64
    public let bootstrapSeconds: Double
    init(_ i: MS256Info) {
        var d = i.device_name, s = i.shader_sha256
        deviceName = withUnsafePointer(to: &d) { $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) } }
        shaderSHA256 = withUnsafePointer(to: &s) { $0.withMemoryRebound(to: CChar.self, capacity: 65) { String(cString: $0) } }
        unifiedMemory = i.unified_memory != 0
        maxBufferLength = i.max_buffer_length; maxPackedBytes = i.max_packed_bytes; maxMessages = i.max_messages
        maxMessageBytes = i.max_message_bytes; threadExecutionWidth = i.thread_execution_width; threadsPerGroup = i.threads_per_group
        bootstrapSeconds = i.bootstrap_seconds
    }
}
/// Experimental standard SHA-256 batch engine. No CPU fallback. Synchronous calls
/// serialize on this context. Each independent message is completed by one GPU thread.
public final class MetalSHA256Engine {
    private let context: OpaquePointer
    public let info: MetalSHA256Info
    public init(maxPackedBytes: UInt64 = 256*1024*1024, maxMessages: UInt64 = 65536) throws {
        var config = MS256Config(max_packed_bytes: maxPackedBytes, max_messages: maxMessages)
        var c: OpaquePointer?
        try requireStatus(ms256_context_create(&config, &c))
        context = c!
        var i = MS256Info()
        let status = ms256_context_info(context, &i)
        if status != MS256_OK { ms256_context_free(context); try requireStatus(status) }
        info = MetalSHA256Info(i)
    }
    deinit { ms256_context_free(context) }
    private func pack(_ messages: [Data]) throws -> (Data, [MetalSHA256Message]) {
        guard UInt64(messages.count) <= info.maxMessages else { throw MetalSHA256Error(status: Int32(MS256_LIMIT), description: "Too many messages") }
        var size: UInt64 = 0, descriptors = [MetalSHA256Message]()
        descriptors.reserveCapacity(messages.count)
        for message in messages {
            let n = UInt64(message.count)
            guard n <= info.maxMessageBytes, n <= info.maxPackedBytes - size else {
                throw MetalSHA256Error(status: Int32(MS256_LIMIT), description: "Message/batch exceeds configured limit; only chunk independent workloads, never ordinary file SHA")
            }
            descriptors.append(.init(offset: size, length: n)); size += n
        }
        var packed = Data(); packed.reserveCapacity(Int(size))
        for message in messages { packed.append(message) } // deliberately included in hashBatch end-to-end
        return (packed, descriptors)
    }
    private func descriptors(_ messages: [MetalSHA256Message]) throws -> [MS256Message] {
        guard UInt64(messages.count) <= info.maxMessages else { throw MetalSHA256Error(status: Int32(MS256_LIMIT), description: "Too many messages") }
        return messages.map { MS256Message(offset: $0.offset, length: $0.length) }
    }
    public func hashBatch(_ messages: [Data]) throws -> MetalSHA256Result {
        let (packed, d) = try pack(messages)
        return try hashPacked(packed, messages: d)
    }
    public func hashPacked(_ packed: Data, messages: [MetalSHA256Message]) throws -> MetalSHA256Result {
        let d = try descriptors(messages)
        var out = Data(count: d.count * 32), m = MS256Metrics()
        let status = packed.withUnsafeBytes { bytes in d.withUnsafeBufferPointer { desc in
            out.withUnsafeMutableBytes { dst in
                ms256_hash_batch(context, bytes.baseAddress, UInt64(bytes.count), desc.baseAddress, UInt64(d.count), MemoryLayout<MS256Message>.stride, dst.baseAddress, dst.count, &m)
            }
        } }
        try requireStatus(status); return MetalSHA256Result(digests: out, metrics: MetalSHA256Metrics(m))
    }
    public func prepare(_ messages: [Data]) throws -> MetalSHA256Prepared {
        let (packed, d) = try pack(messages); return try preparePacked(packed, messages: d)
    }
    public func preparePacked(_ packed: Data, messages: [MetalSHA256Message]) throws -> MetalSHA256Prepared {
        let d = try descriptors(messages); var p: OpaquePointer?
        let status = packed.withUnsafeBytes { bytes in d.withUnsafeBufferPointer { desc in
            ms256_prepare(context, bytes.baseAddress, UInt64(bytes.count), desc.baseAddress, UInt64(d.count), MemoryLayout<MS256Message>.stride, &p)
        } }
        try requireStatus(status); return MetalSHA256Prepared(engine: self, handle: p!, count: d.count)
    }
    fileprivate func hash(_ prepared: OpaquePointer, count: Int) throws -> MetalSHA256Result {
        var out = Data(count: count*32), m = MS256Metrics()
        let s = out.withUnsafeMutableBytes { ms256_hash_prepared(context, prepared, $0.baseAddress, $0.count, &m) }
        try requireStatus(s); return MetalSHA256Result(digests: out, metrics: MetalSHA256Metrics(m))
    }
}
/// Owns an immutable copy of packed bytes in shared Metal buffers; retains engine.
public final class MetalSHA256Prepared {
    private let engine: MetalSHA256Engine, handle: OpaquePointer, count: Int
    fileprivate init(engine: MetalSHA256Engine, handle: OpaquePointer, count: Int) { self.engine = engine; self.handle = handle; self.count = count }
    deinit { ms256_prepared_free(handle) }
    public func hash() throws -> MetalSHA256Result { try engine.hash(handle, count: count) }
}
