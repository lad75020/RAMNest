import Foundation
import CryptoKit
import MetalSHA256
import Dispatch

// Separate schema: these are independent messages, never one large file hash.
struct BatchRow: Codable {
    let api: String, messageBytes: Int, messageCount: Int, iterations: Int, repetition: Int, order: Int
    let workloadBytesPerBatch: UInt64, totalBytes: UInt64, totalHashes: UInt64
    let elapsedNanoseconds: UInt64
    let gbPerSecond: Double, amortizedNSPerMessage: Double, batchLatencyUS: Double, hashesPerSecond: Double
    let completedGPUCommands: UInt64, gpuCommandSeconds: Double?
    let firstGPUStartSeconds: Double?, lastGPUEndSeconds: Double?
    let preparedSetupMS: Double
    let sink: Sink, before: Sample, after: Sample, flags: [String]
}
struct BatchSummary: Codable {
    let api: String, messageBytes: Int, messageCount: Int, samples: Int
    let medianGBPerSecond: Double, minGBPerSecond: Double, maxGBPerSecond: Double
    let gpuOverCryptoKitThroughputSpeedup: Double
}
struct BatchReport: Encodable {
    let schemaVersion = 1
    let completed: Bool, options: Options, metadata: Metadata
    let backend = "Metal MSL SHA-256 compression (one complete independent message/thread); no CPU fallback"
    let deviceName: String, unifiedMemory: Bool, maxBufferLength: UInt64
    let maxMessageBytes: UInt64, maxPackedBytes: UInt64, maxMessages: UInt64
    let threadExecutionWidth: UInt64, threadsPerGroup: UInt64
    let shaderSHA256: String, bootstrapCompileSeconds: Double
    let libraryBuild: [String:String]
    let inputState = "Deterministic prefaulted immutable CPU Data per message, generated outside clocks; not zero-copy into Metal. End-to-end packs a fresh Data, allocates shared Metal buffers, copies packed bytes/descriptors, dispatches, waits, copies all digests. Prepared retains one owned Metal snapshot per cell; setup excluded and reported. No buffer pool or verified cache."
    let timing = "CPU batch loop and both GPU APIs return flat N*32 bytes. All full digests enter the same timed sink. Reference generation, complete pre/post validation, probes, JSON/CSV I/O and context startup are outside timers. GPU command seconds are diagnostic, not primary throughput. Speedup = GPU wall GB/s / CryptoKit wall GB/s; >1 means GPU faster. ns/message is amortized batch cost, not isolated call latency. No energy measurement; CPU/GPU share memory, power and thermal budget."
    let validation = "CryptoKit and CommonCrypto full 32-byte references agree for every input before timing; every API warmed and compared, full last output per repetition compared, all calls consumed into full-digest expected sink. Any Metal/validation error aborts without a valid row. Empty inputs used only in correctness tests."
    let workloadMatrix = "Full: lengths 64,128,256,512,1024,2048,4096,65536,1048576 bytes; counts 1,256,4096 except 1048576 uses 1,64,256. Smoke: lengths 64,65536, counts 1,33. Full base iterations: count1=32, count<=256=4, else2; min(base,max(1,floor(128MiB/batchBytes))). Smoke iterations=2. Same messages/count/iterations across all APIs. CPU legacy sizing arguments do not alter this matrix."
    let shortSamples = "Bounded iterations, same for all APIs per cell. Samples below 100ms flagged; clock/dispatch overhead can dominate, especially count=1. Six repetitions rotate three API first positions equally. Smoke or explicit nonmultiples of three have unbalanced first positions. GPU matrix does not run legacy one-million-call workloads."
    let measurements: [BatchRow], summaries: [BatchSummary]
}
@inline(never) func cryptoKitBatch(_ messages: [Data]) -> Data {
    var out = Data(count: messages.count*32)
    out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
        for (i,d) in messages.enumerated() {
            SHA256.hash(data:d).withUnsafeBytes { dst.baseAddress!.advanced(by:i*32).copyMemory(from:$0.baseAddress!,byteCount:32) }
        }
    }; return out
}
@inline(never) func consumeBatch(_ bytes: Data, _ sink: inout Sink) {
    bytes.withUnsafeBytes { raw in
        for i in stride(from:0,to:raw.count,by:32) { sink.consume(raw.loadUnaligned(fromByteOffset:i,as:Digest32.self)) }
    }
}
func batchSummaries(_ rows:[BatchRow]) -> [BatchSummary] {
    let groups=Dictionary(grouping:rows){"\($0.messageBytes):\($0.messageCount):\($0.api)"}
    return groups.keys.sorted().map { key in
        let g=groups[key]!, r=g[0]
        let cpu=rows.filter{$0.messageBytes==r.messageBytes && $0.messageCount==r.messageCount && $0.api=="CryptoKitCPU-batch"}.map(\.gbPerSecond)
        return BatchSummary(api:r.api,messageBytes:r.messageBytes,messageCount:r.messageCount,samples:g.count,medianGBPerSecond:median(g.map(\.gbPerSecond)),minGBPerSecond:g.map(\.gbPerSecond).min()!,maxGBPerSecond:g.map(\.gbPerSecond).max()!,gpuOverCryptoKitThroughputSpeedup:median(g.map(\.gbPerSecond))/median(cpu))
    }
}
func runMetalBatch(_ options: Options) throws {
    // Runner supplies legacy output-directory refusal policy, but no CPU report is written here.
    let runner=try Runner(options), dir=runner.directory
    let engine=try MetalSHA256Engine(), info=engine.info
    var libraryBuild=[String:String]()
    let build=URL(fileURLWithPath:CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build")
    for name in ["library-source-sha256.txt","clang.txt","flags.txt"] { libraryBuild[name]=(try? String(contentsOf:build.appendingPathComponent(name),encoding:.utf8)) ?? "unknown" }
    var rows=[BatchRow]()
    func save(_ completed:Bool) throws {
        let report=BatchReport(completed:completed,options:options,metadata:runner.metadata,deviceName:info.deviceName,unifiedMemory:info.unifiedMemory,maxBufferLength:info.maxBufferLength,maxMessageBytes:info.maxMessageBytes,maxPackedBytes:info.maxPackedBytes,maxMessages:info.maxMessages,threadExecutionWidth:info.threadExecutionWidth,threadsPerGroup:info.threadsPerGroup,shaderSHA256:info.shaderSHA256,bootstrapCompileSeconds:info.bootstrapSeconds,libraryBuild:libraryBuild,measurements:rows,summaries:batchSummaries(rows))
        let encoder=JSONEncoder(); encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try atomicWrite(encoder.encode(report),to:dir.appendingPathComponent("batch-report.json"))
        var csv=["api,message_bytes,message_count,iterations,repetition,order,total_bytes,total_hashes,elapsed_ns,GB_per_s,amortized_ns_per_message,batch_latency_us,hashes_per_s,completed_GPU_commands,gpu_command_seconds,first_GPU_start_seconds,last_GPU_end_seconds,prepared_setup_ms,flags"]
        for r in rows { csv.append([r.api,String(r.messageBytes),String(r.messageCount),String(r.iterations),String(r.repetition),String(r.order),String(r.totalBytes),String(r.totalHashes),String(r.elapsedNanoseconds),String(r.gbPerSecond),String(r.amortizedNSPerMessage),String(r.batchLatencyUS),String(r.hashesPerSecond),String(r.completedGPUCommands),r.gpuCommandSeconds.map{String($0)} ?? "",r.firstGPUStartSeconds.map{String($0)} ?? "",r.lastGPUEndSeconds.map{String($0)} ?? "",String(r.preparedSetupMS),r.flags.joined(separator:";")].joined(separator:",")) }
        try atomicWrite(Data((csv.joined(separator:"\n")+"\n").utf8),to:dir.appendingPathComponent("batch-measurements.csv"))
    }
    print("Metal batch device=\(info.deviceName) unifiedMemory=\(info.unifiedMemory) width=\(info.threadExecutionWidth) group=\(info.threadsPerGroup) bootstrapSeconds=\(info.bootstrapSeconds) shader=\(info.shaderSHA256)")
    let sizes=options.smoke ? [64,65536] : [64,128,256,512,1024,2048,4096,65536,1_048_576]
    try save(false)
    for size in sizes {
        let counts=options.smoke ? [1,33] : (size==1_048_576 ? [1,64,256] : [1,256,4096])
        for count in counts {
            let bytes=size*count
            try check(UInt64(bytes)<=info.maxPackedBytes,"Workload exceeds batch budget")
            let pool=try (0..<count).map{try Input(size,seed &+ UInt64($0))}
            // Data wrappers do not own these allocations. Swift may release pool
            // after map's last use, so retain every owner through GPU/CPU use.
            try withExtendedLifetime(pool) {
            let messages=pool.map(\.data)
            var reference=Data(); reference.reserveCapacity(count*32)
            for d in messages { let a=try ccOne(d); try check(a==ckOne(d),"CPU batch references disagree"); withUnsafeBytes(of:a){reference.append(contentsOf:$0)} }
            let setup=DispatchTime.now().uptimeNanoseconds
            let prepared=try engine.prepare(messages)
            let setupMS=Double(DispatchTime.now().uptimeNanoseconds-setup)/1e6
            let apis=["CryptoKitCPU-batch","MetalSHA256-end-to-end","MetalSHA256-prepared"]
            func invoke(_ api:String) throws -> (Data,MetalSHA256Metrics?) {
                if api==apis[0] { return (cryptoKitBatch(messages),nil) }
                let r=try api==apis[1] ? engine.hashBatch(messages) : prepared.hash()
                try check(r.metrics.completedCommands==1 && r.metrics.messageCount==UInt64(count) && r.metrics.workloadBytes==UInt64(bytes),"Missing completed Metal workload")
                return (r.digests,r.metrics)
            }
            for api in apis { let r=try invoke(api); try check(r.0==reference,"Warmup full output mismatch") }
            let baseIterations=count==1 ? 32 : (count<=256 ? 4 : 2)
            let iterations=options.smoke ? 2 : max(1,min(baseIterations,128*1024*1024/bytes))
            var expected=Sink(); for _ in 0..<iterations { consumeBatch(reference,&expected) }
            for rep in 0..<options.repetitions {
                for position in 0..<3 {
                    let api=apis[(position+rep)%3]
                    var sink=Sink(), last=Data(), commandCount:UInt64=0, gpuSeconds=0.0
                    var gpuKnown=true, firstStart:Double?, lastEnd:Double?
                    let before=Sample(), start=DispatchTime.now().uptimeNanoseconds
                    for _ in 0..<iterations {
                        let (out,m)=try invoke(api); last=out; consumeBatch(out,&sink)
                        if let m=m {
                            commandCount += m.completedCommands
                            if let duration=m.gpuSeconds { gpuSeconds += duration } else { gpuKnown=false }
                            if firstStart==nil { firstStart=m.gpuStartSeconds }; lastEnd=m.gpuEndSeconds
                        }
                    }
                    let elapsed=DispatchTime.now().uptimeNanoseconds-start, after=Sample()
                    try check(last==reference && sink==expected,"Timed batch full digest/sink mismatch: api=\(api) size=\(size) count=\(count) rep=\(rep) outputEqual=\(last==reference) sinkEqual=\(sink==expected) actual=\(sink) expected=\(expected)")
                    try check(elapsed>0,"Zero batch elapsed")
                    if api != apis[0] { try check(commandCount==UInt64(iterations),"GPU command count mismatch") }
                    var flags=[String]()
                    if elapsed<100_000_000 { flags.append("short-sample-under-100ms") }
                    if before.thermalState>=2 || after.thermalState>=2 { flags.append("contaminated:serious-or-critical-thermal") }
                    if let a=before.pageins,let b=after.pageins,b>a { flags.append("contaminated:process-pageins-increased") }
                    if !before.available || !after.available { flags.append("pagein-residency-unknown") }
                    if api != apis[0] && !gpuKnown { flags.append("GPU-timestamps-unavailable") }
                    let total=UInt64(bytes)*UInt64(iterations), hashes=UInt64(count)*UInt64(iterations), ns=Double(elapsed)
                    rows.append(BatchRow(api:api,messageBytes:size,messageCount:count,iterations:iterations,repetition:rep+1,order:position+1,workloadBytesPerBatch:UInt64(bytes),totalBytes:total,totalHashes:hashes,elapsedNanoseconds:elapsed,gbPerSecond:Double(total)/ns,amortizedNSPerMessage:ns/Double(hashes),batchLatencyUS:ns/Double(iterations)/1000,hashesPerSecond:Double(hashes)*1e9/ns,completedGPUCommands:commandCount,gpuCommandSeconds:api != apis[0] && gpuKnown ? gpuSeconds : nil,firstGPUStartSeconds:firstStart,lastGPUEndSeconds:lastEnd,preparedSetupMS:setupMS,sink:sink,before:before,after:after,flags:flags))
                    try save(false)
                }
            }
            print("Completed independent batch \(size) B × \(count) messages × \(iterations) iterations/API/repeat")
            }
        }
    }
    try save(true)
    print("Verified batch reports: \(dir.path)")
}
