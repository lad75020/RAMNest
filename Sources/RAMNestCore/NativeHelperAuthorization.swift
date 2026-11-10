import Foundation
import Darwin
import Security
import Carbon

/// A retained script, not a cache of credentials or successful command results.
/// The seam lets tests count contexts and simulated prompts without authorization.
protocol NativeAdministratorExecuting: AnyObject {
    func execute(command: String) throws -> String
    func finish()
}

struct NativeAppleScriptFailure: LocalizedError {
    let number: Int
    let message: String
    var errorDescription: String? { "\(message) (AppleScript \(number))" }
    var authorizationStopped: Bool {
        number == -128 || number == Int(errAuthorizationCanceled) || number == Int(errAuthorizationDenied)
    }
    init(number: Int, message: String) { self.number = number; self.message = message }
    init(_ info: NSDictionary?) {
        number = (info?[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? -1
        message = info?[NSAppleScript.errorMessage] as? String ?? "macOS could not execute the native administrator operation."
    }
}

final class NativeAppleScriptContext: NativeAdministratorExecuting {
    // Apple DTS confirms secondary-thread use since 10.6, provided work is
    // serialized (developer.apple.com/forums/thread/759287). Include creation,
    // compilation and disposal, across all operation-local instances.
    private static let lock = NSLock()
    private var script: NSAppleScript?

    static func source(operation: UUID) -> String {
        // TN2065: authentication belongs to this unchanged script, normally for
        // five minutes. Commands are handler DATA; never recompile per step.
        // A unique source also prevents reuse by a later user operation.
        """
        use scripting additions
        property operationIdentity : "\(operation.uuidString)"
        on ramnest_authorize(commandText)
            return do shell script commandText with administrator privileges without altering line endings
        end ramnest_authorize
        """
    }
    init(source: String) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var info: NSDictionary?
        guard let script = NSAppleScript(source: source), script.compileAndReturnError(&info) else {
            throw NativeAppleScriptFailure(info)
        }
        self.script = script
    }
    func execute(command: String) throws -> String {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard let script else { throw NestError("Native administrator context is closed.", code: NestError.Code.helper) }
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kASAppleScriptSuite),
            eventID: AEEventID(kASSubroutineEvent), targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: "ramnest_authorize"), forKeyword: AEKeyword(keyASSubroutineName))
        let parameters = NSAppleEventDescriptor.list()
        parameters.insert(NSAppleEventDescriptor(string: command), at: 1)
        event.setParam(parameters, forKeyword: AEKeyword(keyDirectObject))
        var info: NSDictionary?
        guard let result = script.executeAppleEvent(event, error: &info) as NSAppleEventDescriptor?,
              let text = result.stringValue, info == nil else { throw NativeAppleScriptFailure(info) }
        return text
    }
    func finish() {
        Self.lock.lock(); defer { Self.lock.unlock() }
        script = nil
    }
    deinit { finish() }
}

/// Owned by ONE synchronous mount/save/eject/recovery call, including its error
/// cleanup and linked restoration. Never stored on Engine, the journal or disk.
/// Each step still captures compiled byte authority and stages/verifies a fresh
/// root helper. No privileged process, socket or arbitrary-exec service survives.
final class NativeTmpfsAuthorization {
    private let helper: URL
    private let capture: (URL) throws -> NativeHelperImage
    private let makeScript: (String) throws -> any NativeAdministratorExecuting
    private let source = NativeAppleScriptContext.source(operation: UUID())
    private let lock = NSLock()
    private var script: (any NativeAdministratorExecuting)?
    private var slot: [String]?
    private var stopped = false

    init(helper: URL, capture: @escaping (URL) throws -> NativeHelperImage = { try NativeHelperImage.capture(helper: $0) },
         makeScript: @escaping (String) throws -> any NativeAdministratorExecuting = { try NativeAppleScriptContext(source: $0) }) {
        self.helper = helper; self.capture = capture; self.makeScript = makeScript
    }
    func authorize(arguments: [String]) throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { throw NestError("Native administrator operation was cancelled or closed; retry the user operation explicitly.", code: NestError.Code.helper) }
        let image = try capture(helper)
        let command = try NativeHelperBootstrap.command(image: image, arguments: arguments)
        let requestedSlot = Array(arguments.dropFirst(2).prefix(2))
        guard requestedSlot.count == 2, slot == nil || slot == requestedSlot else {
            throw NestError("Native administrator context cannot cross user/session slots.", code: NestError.Code.unsafePath)
        }
        slot = requestedSlot
        let result: String
        do {
            if script == nil { script = try makeScript(source) }
            result = try script!.execute(command: command)
        } catch {
            if script == nil || (error as? NativeAppleScriptFailure)?.authorizationStopped == true {
                // A rollback may ask to thaw an already guarded tree. It must
                // not open a second authorization dialog after Cancel/Denied.
                stopped = true; script?.finish(); script = nil
            }
            let freeze = arguments.dropFirst().first == "freeze"
            throw NestError((freeze ? "Native freeze/mapping validation failed; no checkpoint was authorized. " : "Native tmpfs control could not complete using operation-scoped macOS administrator authorization. ") + error.localizedDescription, code: freeze ? 78 : 2)
        }
        let fields = result.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\t")
        guard fields.first == "OK" else { throw NestError("Invalid native control receipt; inspect the owned slot before retrying.", code: NestError.Code.retained) }
        return Array(fields.dropFirst())
    }
    func finish() {
        lock.lock(); defer { lock.unlock() }
        stopped = true; script?.finish(); script = nil
    }
    deinit { finish() }
}

/// The only expected byte authority is compiled into the Core image actually
/// linked by this process. No manifest/path/environment supplies its value.
public struct NativeHelperCompiledAuthority: Codable, Equatable, Sendable {
    public let engine: String
    public let sha256: String
    public let configuration: String
    public static var current: Self {
        .init(engine: NativeHelperBuildIdentity.engine, sha256: NativeHelperBuildIdentity.sha256,
              configuration: NativeHelperBuildIdentity.configuration)
    }
    func require(pinnedDigest: String, receipt: [String: Any]?) throws {
        guard engine == NativeTmpfsControl.protocolVersion,
              sha256.count == 64, sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              ["Debug", "Release"].contains(configuration), pinnedDigest == sha256,
              receipt?["engine"] as? String == engine, receipt?["helperSHA256"] as? String == sha256,
              receipt?["configuration"] as? String == (configuration == "Debug" ? "Debug" : "RelWithDebInfo") else {
            throw NestError("Native helper bytes/provenance do not match the authority compiled into this running RAMNest. Rebuild a coherent package; no administrator operation was started.", code: NestError.Code.unsafePath)
        }
    }
}

/// Integrity of the selected running package, not a claim of notarization or an
/// Apple-trusted publisher. Development ad-hoc signatures are supported. The
/// administrator is authorizing these captured package bytes for this operation.
struct NativeHelperImage {
    let source: URL
    let bytes: Int
    let digest: String

    private static func signedCode(_ url: URL, nested: Bool = false) throws -> SecStaticCode {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            throw NestError("Cannot authenticate packaged native code.", code: NestError.Code.unsafePath)
        }
        var flags = kSecCSStrictValidate | kSecCSCheckAllArchitectures
        if nested { flags |= kSecCSCheckNestedCode }
        guard SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: flags), nil) == errSecSuccess else {
            throw NestError("Packaged native code signature/resource validation failed.", code: NestError.Code.unsafePath)
        }
        return code
    }
    private static func codeHash(_ code: SecStaticCode) throws -> String {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
              let hash = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else {
            throw NestError("Missing packaged native code identity.", code: NestError.Code.unsafePath)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
    static func capture(helper: URL) throws -> NativeHelperImage {
        var running: SecCode?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCheckValidity(running, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else {
            throw NestError("Running RAMNest code identity is not valid.", code: NestError.Code.unsafePath)
        }
        let app = helper.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = BinaryLocation.executable
        guard app.pathExtension == "app", helper == app.appendingPathComponent("Contents/Helpers/ramnest-helper"),
              [app.appendingPathComponent("Contents/MacOS/RAMNest"), app.appendingPathComponent("Contents/Helpers/ramnest")].contains(executable),
              Bundle(url: app)?.bundleIdentifier == "sh.ramnest.app" else {
            throw NestError("Administrator operations require the helper in the same signed RAMNest app as the running app/CLI.", code: NestError.Code.unsafePath)
        }
        try Paths.rejectSymlinks(helper.path)
        let fd = open(helper.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NestError("Cannot pin packaged native helper bytes.", code: NestError.Code.unsafePath) }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1,
              before.st_uid == getuid() || before.st_uid == 0,
              before.st_mode & 0o022 == 0, before.st_size > 0, before.st_size <= 32 << 20 else {
            throw NestError("Packaged native helper type/ownership/size is unsafe.", code: NestError.Code.unsafePath)
        }
        func readPinned() throws -> Data {
            guard lseek(fd, 0, SEEK_SET) == 0 else { throw NestError("Cannot seek pinned native image.", code: NestError.Code.unsafePath) }
            var result = Data(), buffer = [UInt8](repeating: 0, count: 65536)
            while result.count < before.st_size {
                let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, min($0.count, Int(before.st_size) - result.count)) }
                guard n > 0 else { throw NestError("Packaged native image changed during capture.", code: NestError.Code.unsafePath) }
                result.append(contentsOf: buffer.prefix(n))
            }
            return result
        }
        let bytes = try readPinned(), digest = Snapshot.digest(bytes)
        let current = try signedCode(executable), currentHash = try codeHash(current)
        let code = try signedCode(helper), hash = try codeHash(code)
        // Path-based seal checks are defense in depth, NOT captured-byte
        // authority. Mutable resources can be swapped around their validation.
        _ = try signedCode(app, nested: true)
        let provenance = app.appendingPathComponent("Contents/Resources/native-provenance.json")
        try Paths.rejectSymlinks(provenance.path)
        let receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: provenance)) as? [String: Any]
        // Mandatory on the real capture path, before any image can reach
        // AppleScript/root staging. A self-signed replacement plus forged matching
        // receipt cannot change this process's compiled expected SHA256.
        try NativeHelperCompiledAuthority.current.require(pinnedDigest: digest, receipt: receipt)
        guard try codeHash(signedCode(executable)) == currentHash,
              try codeHash(signedCode(helper)) == hash,
              SecCodeCheckValidity(running, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess,
              Snapshot.digest(try readPinned()) == digest else {
            throw NestError("Packaged native helper/provenance changed before authorization.", code: NestError.Code.unsafePath)
        }
        var after = stat(), named = stat()
        guard fstat(fd, &after) == 0, lstat(helper.path, &named) == 0,
              after.st_dev == before.st_dev, after.st_ino == before.st_ino, after.st_size == before.st_size,
              after.st_mtimespec == before.st_mtimespec, after.st_ctimespec == before.st_ctimespec,
              named.st_dev == before.st_dev, named.st_ino == before.st_ino else {
            throw NestError("Packaged native helper identity changed before authorization.", code: NestError.Code.unsafePath)
        }
        return NativeHelperImage(source: helper, bytes: bytes.count, digest: digest)
    }
}

/// Only system executables run before the staged image passes digest AND code
/// signature checks. No mutable source executable or user-supplied script runs as
/// root. The stage is fresh, root-owned 0700 under the root/sticky-protected Shared
/// directory; a user cannot replace it between verification and exec.
enum NativeHelperBootstrap {
    static func copyVerification(source: URL, bytes: Int, digest: String) throws -> String {
        guard source.isFileURL, source.path.hasPrefix("/"), !source.path.contains(where: { $0 == "\0" || $0.isNewline }),
              bytes > 0, bytes <= 32 << 20, digest.count == 64, digest.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw NestError("Invalid captured native image authority.", code: NestError.Code.unsafePath)
        }
        let source = NativeTmpfsControl.shellQuote(source.path)
        return """
        [ ! -L \(source) ] && [ -f \(source) ] || { echo 'Native source image was replaced' >&2; exit 74; }
        [ "$(/usr/bin/stat -f '%z' \(source))" = '\(bytes)' ] || { echo 'Native source image size changed' >&2; exit 74; }
        /usr/bin/head -c \(bytes) \(source) > "$stage/helper"
        [ ! -L "$stage/helper" ] && [ -f "$stage/helper" ] || exit 74
        [ "$(/usr/bin/stat -f '%u:%z:%l' "$stage/helper")" = "$(/usr/bin/id -u):\(bytes):1" ] || exit 74
        /bin/chmod 500 "$stage/helper"
        actual=$(/usr/bin/shasum -a 256 "$stage/helper")
        [ "${actual%% *}" = '\(digest)' ] || { echo 'Native staged image digest mismatch; no custom code executed' >&2; exit 74; }
        /usr/bin/codesign --verify --strict --all-architectures "$stage/helper"
        """
    }
    static func script(image: NativeHelperImage, arguments: [String]) throws -> String {
        guard arguments.first == "--native-v1", arguments.allSatisfy({ !$0.contains("\0") && !$0.contains(where: \.isNewline) }) else {
            throw NestError("Invalid bounded native operation.", code: NestError.Code.unsafePath)
        }
        let copy = try copyVerification(source: image.source, bytes: image.bytes, digest: image.digest)
        let args = arguments.map(NativeTmpfsControl.shellQuote).joined(separator: " ")
        return """
        set -eu
        cd /
        umask 077
        [ "$(/usr/bin/id -u)" = 0 ] || exit 77
        for path in / /Users /Users/Shared; do [ ! -L "$path" ] && [ -d "$path" ] || exit 74; done
        [ "$(/usr/bin/stat -f '%u:%Lp' /)" = '0:755' ] || exit 74
        [ "$(/usr/bin/stat -f '%u:%Lp' /Users)" = '0:755' ] || exit 74
        [ "$(/usr/bin/stat -f '%u:%p' /Users/Shared)" = '0:41777' ] || exit 74
        listing=$(/bin/ls -lde /Users/Shared)
        case "$listing" in *'
        '*) echo 'Shared runtime parent ACL is unsupported' >&2; exit 74;; esac
        stage=$(/usr/bin/mktemp -d /Users/Shared/.RAMNestNativeExec.XXXXXXXX)
        [ ! -L "$stage" ] && [ "$(/usr/bin/stat -f '%u:%Lp' "$stage")" = '0:700' ] || exit 74
        identity=$(/usr/bin/stat -f '%d:%i:%u:%Lp' "$stage")
        cleanup() {
            result=$?
            trap - EXIT HUP INT TERM
            if [ ! -L "$stage" ] && [ "$(/usr/bin/stat -f '%d:%i:%u:%Lp' "$stage")" = "$identity" ]; then
                /bin/rm -f "$stage/helper" || result=73
                /bin/rmdir "$stage" || result=73
            else result=73; fi
            exit "$result"
        }
        trap cleanup EXIT
        trap 'exit 74' HUP INT TERM
        \(copy)
        "$stage/helper" \(args)
        """
    }
    static func command(image: NativeHelperImage, arguments: [String]) throws -> String {
        ["/usr/bin/env", "-i", "PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL=C", "/bin/sh", "-c", try script(image: image, arguments: arguments)]
            .map(NativeTmpfsControl.shellQuote).joined(separator: " ")
    }
}
