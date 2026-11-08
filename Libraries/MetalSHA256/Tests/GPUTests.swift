import Foundation
import CryptoKit
import CommonCrypto
import MetalSHA256
import CMetalSHA256
import Dispatch

struct TestError: Error { let text: String }
func require(_ ok: Bool, _ text: String) throws { if !ok { throw TestError(text: text) } }
func ck(_ d: Data) -> Data { Data(SHA256.hash(data:d)) }
func cc(_ d: Data) -> Data {
    var out=Data(count:32)
    _ = out.withUnsafeMutableBytes { dst in d.withUnsafeBytes { src in CC_SHA256(src.baseAddress, CC_LONG(src.count), dst.baseAddress!.assumingMemoryBound(to:UInt8.self)) } }
    return out
}
func hex(_ d: Data) -> String { d.map { String(format:"%02x",$0) }.joined() }
var rng: UInt64=0x123456789abcdef
func random(_ n: Int) -> Data {
    var d=Data(count:n)
    d.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
        var i=0
        while i<n { rng &+= 0x9e3779b97f4a7c15; var z=rng; z=(z^(z>>30)) &* 0xbf58476d1ce4e5b9; z=(z^(z>>27)) &* 0x94d049bb133111eb; z ^= z>>31
            let k=min(8,n-i); withUnsafeBytes(of:&z) { raw.baseAddress!.advanced(by:i).copyMemory(from:$0.baseAddress!,byteCount:k) }; i += k
        }
    }; return d
}
var commands: UInt64=0, seconds=0.0, checked=0
func verify(_ result: MetalSHA256Result, _ inputs:[Data]) throws {
    try require(result.digests.count==inputs.count*32,"output shape")
    for (i,d) in inputs.enumerated() {
        let reference=ck(d); try require(reference==cc(d),"independent CPU references disagree")
        try require(result.digests.subdata(in:i*32..<(i+1)*32)==reference,"GPU full digest/order mismatch at \(i), length \(d.count)")
    }
    if inputs.isEmpty {
        try require(result.metrics.completedCommands==0 && result.metrics.gpuSeconds==nil,"empty batch must not claim GPU execution")
    } else {
        try require(result.metrics.completedCommands==1,"missing real completed command")
        try require((result.metrics.gpuSeconds ?? -1)>0 && (result.metrics.gpuEndSeconds ?? 0)>(result.metrics.gpuStartSeconds ?? 0),"missing positive observed GPU timestamps")
        commands += result.metrics.completedCommands; seconds += result.metrics.gpuSeconds!
    }
    checked += inputs.count
}
func negativeTests() throws {
    var ctx: OpaquePointer?
    var invalid=MS256Config(max_packed_bytes:UInt64.max,max_messages:1)
    try require(ms256_context_create(&invalid,&ctx)==MS256_LIMIT && ctx==nil,"invalid config")
    var testConfig=MS256Config(max_packed_bytes:1024,max_messages:65536)
    let creation=ms256_context_create(&testConfig,&ctx)
    if creation != 0 { var error=[CChar](repeating:0,count:2048); _=ms256_last_error(&error,error.count); throw TestError(text:"native context create: \(String(cString:error))") }
    defer { ms256_context_free(ctx) }
    var byte:UInt8=0, d=MS256Message(offset:0,length:1), metrics=MS256Metrics(), p:OpaquePointer?
    var out=[UInt8](repeating:0xA5,count:32)
    func call(_ n:UInt64=1,_ count:UInt64=1,_ stride:Int=16,_ cap:Int=32) -> Int32 {
        ms256_hash_batch(ctx,&byte,n,&d,count,stride,&out,cap,&metrics)
    }
    func rejected(_ status:Int32,_ why:String) throws {
        try require(status != 0,"accepted \(why)")
        try require(metrics.completed_commands==0 && metrics.gpu_seconds == -1,"negative test dispatched \(why)")
        try require(out.allSatisfy{$0==0xA5},"negative test modified output \(why)")
    }
    d.offset=UInt64.max; try rejected(call(),"offset overflow")
    d.offset=1; d.length=UInt64.max; try rejected(call(),"length overflow")
    d.offset=0; d.length=16*1024*1024+1; try rejected(call(),"oversize message")
    d.length=1; try rejected(call(256*1024*1024+1),"oversize packed bytes")
    try rejected(call(1,UInt64.max),"count/output overflow")
    try rejected(call(1,65537),"count limit")
    try rejected(call(1,1,8),"descriptor size mismatch")
    try rejected(call(1,1,16,31),"undersized destination")
    d.offset=1; try rejected(call(),"out of range")
    d.offset=0
    // Compact overlapping descriptors cannot be used to submit unbounded work.
    let repeated=[MS256Message](repeating:MS256Message(offset:0,length:64),count:17)
    let validBacking=Data(repeating:0,count:64)
    let overwork=validBacking.withUnsafeBytes { raw in repeated.withUnsafeBufferPointer { ms256_prepare(ctx,raw.baseAddress,UInt64(raw.count),$0.baseAddress,17,16,&p) } }
    try require(overwork==MS256_LIMIT && p==nil,"overlap workload limit")
    try require(ms256_hash_batch(ctx,nil,1,&d,1,16,&out,32,&metrics) != 0,"null input accepted")
    try require(ms256_hash_batch(ctx,&byte,1,nil,1,16,&out,32,&metrics) != 0,"null descriptors accepted")
    try require(ms256_hash_batch(ctx,&byte,1,&d,1,16,nil,32,&metrics) != 0,"null output accepted")
    try require(ms256_prepare(ctx,&byte,1,&d,1,16,&p)==0,"native prepare")
    defer { ms256_prepared_free(p) }
    byte=99 // prepared must retain zero snapshot
    try require(ms256_hash_prepared(ctx,p,&out,32,&metrics)==0,"native prepared hash")
    try require(Data(out)==ck(Data([0])),"native input mutation changed snapshot")
    try require(metrics.completed_commands==1 && metrics.gpu_seconds>0,"native command evidence")
    commands += 1; seconds += metrics.gpu_seconds
    var other:OpaquePointer?; try require(ms256_context_create(nil,&other)==0,"second context")
    defer { ms256_context_free(other) }
    try require(ms256_hash_prepared(other,p,&out,32,&metrics) != 0 && metrics.completed_commands==0,"cross context accepted")
    var error=[CChar](repeating:1,count:3)
    let needed=ms256_last_error(&error,3)
    try require(needed>3 && error[2]==0,"last error bounds")
    print("NEGATIVE PASS: config, ranges, overflow, sizes, nulls, wrong owner, snapshot, last-error bounds; no invalid dispatch")
}
do {
    try negativeTests()
    let engine=try MetalSHA256Engine()
    print("DEVICE \(engine.info.deviceName) unified=\(engine.info.unifiedMemory) width=\(engine.info.threadExecutionWidth) group=\(engine.info.threadsPerGroup) bootstrap=\(engine.info.bootstrapSeconds) shader=\(engine.info.shaderSHA256)")
    if let expected=ProcessInfo.processInfo.environment["METAL_SHA256_EXPECT_DEVICE"] { try require(engine.info.deviceName==expected,"unexpected GPU device") }
    let kats:[(Data,String)] = [
        (Data(),"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
        (Data("abc".utf8),"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
        (Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8),"248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"),
        (Data(repeating:97,count:1_000_000),"cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")]
    let kr=try engine.hashBatch(kats.map{$0.0}); try verify(kr,kats.map{$0.0})
    for (i,k) in kats.enumerated() { try require(hex(kr.digests.subdata(in:i*32..<(i+1)*32))==k.1,"NIST KAT") }
    let lengths=[0,1,55,56,57,63,64,65,119,120,127,128,129,255,256,4095,4096,65535,65536,65537,1_000_000,1_000_003]
    var mixed=lengths.map{random($0)}
    mixed += [Data(repeating:0,count:129),Data(repeating:255,count:63),Data((0..<256).map(UInt8.init)),mixed[8],Data()]
    try verify(engine.hashBatch(mixed),mixed)
    for count in [1,31,32,33,255,256,257,4096] {
        let inputs=(0..<count).map{ i in random([0,1,55,56,63,64,65,127,128,129,255][i%11]) }
        try verify(engine.hashBatch(inputs),inputs)
    }
    for _ in 0..<8 {
        let inputs=(0..<97).map{_ in random(Int(random(2).withUnsafeBytes{$0.loadUnaligned(as:UInt16.self)})%4097)}
        try verify(engine.hashBatch(inputs),inputs)
    }
    let packed=random(4099), views:[MetalSHA256Message]=[.init(offset:1,length:55),.init(offset:3,length:4096),.init(offset:3,length:57),.init(offset:4099,length:0)]
    let viewInputs=views.map{packed.subdata(in:Int($0.offset)..<Int($0.offset+$0.length))}
    try verify(engine.hashPacked(packed,messages:views),viewInputs)
    var mutable=Data([0,1,2,3,4]); let snapshot=mutable
    let prepared=try engine.preparePacked(mutable,messages:[.init(offset:0,length:5)])
    mutable[0]=255; try verify(prepared.hash(),[snapshot]); try verify(prepared.hash(),[snapshot])
    try verify(engine.prepare([]).hash(),[]); try verify(engine.hashBatch([]),[]); try verify(engine.hashBatch([Data(),Data()]),[Data(),Data()])
    try verify(engine.hashBatch([Data](repeating:Data(),count:65536)),[Data](repeating:Data(),count:65536))
    // Context's native mutex serializes synchronous calls. No free/use races.
    let group=DispatchGroup(), lock=NSLock(); var concurrentError:Error?
    for _ in 0..<4 { group.enter(); DispatchQueue.global().async {
        do { let r=try prepared.hash(); try require(r.digests==ck(snapshot) && r.metrics.completedCommands==1 && (r.metrics.gpuSeconds ?? 0)>0,"concurrent prepared result") }
        catch { lock.lock(); concurrentError=error; lock.unlock() }; group.leave()
    } }; group.wait(); if let e=concurrentError { throw e }
    commands += 4
    // Lifetime: prepared retains Swift engine after local engine variable expires.
    let retained=try { () throws -> MetalSHA256Prepared in let e=try MetalSHA256Engine(); return try e.prepare([Data("abc".utf8)]) }()
    try verify(retained.hash(),[Data("abc".utf8)])
    print("GPU TEST PASS fullDigestComparisons=\(checked) completedCommands=\(commands) observedGPUSecondsSumExcludingConcurrency=\(seconds)")
} catch { fputs("GPU TEST FAIL (no skip / no CPU fallback): \(error)\n",stderr); exit(1) }
