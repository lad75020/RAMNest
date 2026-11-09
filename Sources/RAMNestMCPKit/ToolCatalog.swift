import Foundation
import RAMNestCore

public indirect enum Argument: Sendable {
    case string(Int = 4096), boolean, integer(Int, Int), integers([Int]), choice([String]), uuid, path, object([String: Argument])
    var schema: JSON {
        var p: [String: JSON]
        switch self {
        case .string(let max): p = ["type": .string("string"), "minLength": .integer(1), "maxLength": .integer(max)]
        case .boolean: p = ["type": .string("boolean")]
        case .integer(let min, let max): p = ["type": .string("integer"), "minimum": .integer(min), "maximum": .integer(max)]
        case .integers(let values): p = ["type": .string("integer"), "enum": .array(values.map(JSON.integer))]
        case .choice(let values): p = ["type": .string("string"), "enum": .array(values.map(JSON.string))]
        case .uuid: p = ["type": .string("string"), "format": .string("uuid"), "minLength": .integer(36), "maxLength": .integer(36)]
        case .path: p = ["type": .string("string"), "minLength": .integer(2), "maxLength": .integer(4096), "pattern": .string("^/")]
        case .object(let fields): return Self.objectSchema(fields, required: [])
        }
        return .object(p)
    }
    static func objectSchema(_ fields: [String: Argument], required: [String]) -> JSON {
        .object(["type": .string("object"), "properties": .object(fields.mapValues(\.schema)),
                 "required": .array(required.map(JSON.string)), "additionalProperties": .bool(false)])
    }
    func validate(_ value: JSON, key: String) throws {
        func invalid() -> MCPFailure { MCPFailure("invalid_arguments", "Invalid type, value or bounds for \(key).") }
        switch (self, value) {
        case (.string(let max), .string(let s)):
            guard !s.isEmpty, s.count <= max, !s.utf8.contains(0), !s.contains("\n"), !s.contains("\r") else { throw invalid() }
        case (.boolean, .bool): break
        case (.integer(let min, let max), .integer(let n)) where n >= min && n <= max: break
        case (.integers(let values), .integer(let n)) where values.contains(n): break
        case (.choice(let values), .string(let s)) where values.contains(s): break
        case (.uuid, .string(let s)) where s.count == 36 && UUID(uuidString: s) != nil: break
        case (.path, .string(let s)):
            guard s.hasPrefix("/"), s != "/", s.utf8.count < 4096, !s.utf8.contains(0),
                  !s.contains("\n"), !s.contains("\r"), URL(fileURLWithPath: s).standardizedFileURL.path == s else { throw invalid() }
        case (.object(let fields), .object(let values)):
            try ToolDefinition.validate(values, fields: fields, required: [], prefix: key + ".")
        default: throw invalid()
        }
    }
}

public struct ToolDefinition: Sendable {
    public let name: String
    public let description: String
    let fields: [String: Argument]
    let required: [String]
    public let readOnly: Bool
    public let destructive: Bool
    public var schema: JSON { Argument.objectSchema(fields, required: required) }
    public func validate(_ args: [String: JSON]) throws {
        try Self.validate(args, fields: fields, required: required)
    }
    static func validate(_ args: [String: JSON], fields: [String: Argument], required: [String], prefix: String = "") throws {
        guard Set(args.keys).isSubset(of: Set(fields.keys)) else { throw MCPFailure("invalid_arguments", "Unknown argument at \(prefix): \(Set(args.keys).subtracting(fields.keys).sorted().joined(separator: ", ")).") }
        guard required.allSatisfy({ args[$0] != nil }) else { throw MCPFailure("invalid_arguments", "Required arguments: \(required.joined(separator: ", ")).") }
        for (key, value) in args { try fields[key]!.validate(value, key: prefix + key) }
    }
}

public enum ToolCatalog {
    public static let options: [String: Argument] = ["mountAtLaunch": .boolean, "nobrowse": .boolean, "sync": .boolean,
        "periodicSave": .boolean, "intervalMinutes": .integers(FolderOptions.intervals), "comparison": .choice(["sizeAndModTime", "checksum"])]
    static let capacity = Argument.integer(16 << 20, Int(ProcessInfo.processInfo.physicalMemory / 4 * 3))
    public static let tools: [ToolDefinition] = {
        func t(_ name: String, _ description: String, _ fields: [String: Argument] = [:], _ required: [String] = [], read: Bool = false, destroy: Bool = false) -> ToolDefinition {
            .init(name: name, description: description, fields: fields, required: required, readOnly: read, destructive: destroy)
        }
        let ref: [String: Argument] = ["id": .uuid]
        return [
            t("capabilities", "Report prerequisites, package authority, fixed backend and unsupported removed controls.", read: true),
            t("folder_list", "List ALL configured folders and observed status; never mounts at startup.", read: true),
            t("folder_info", "Folder configuration, journal, mount and snapshot capability.", ref, ["id"], read: true),
            t("folder_create", "Register an EXISTING directory; mount only when mount=true. Capacity is bytes.", ["path": .path, "name": .string(255), "capacityBytes": capacity, "options": .object(options), "mount": .boolean], ["path", "capacityBytes"]),
            t("folder_mount", "Mount via the signed packaged CLI; one-shot macOS administrator authorization.", ref, ["id"]),
            t("folder_reconnect", "Reconnect the native coordinator for an existing managed mount.", ref, ["id"]),
            t("folder_unmount", "Normal eject; sync saves changes, temporary mode discards RAM changes. Ignore Busy never bypasses mapping guard.", ["id": .uuid, "ignoreBusy": .boolean], ["id"], destroy: true),
            t("folder_save", "Save a verified checkpoint; close all writers and mappings first.", ref, ["id"]),
            t("folder_resize", "Change capacity only after eject/recovery.", ["id": .uuid, "capacityBytes": capacity], ["id", "capacityBytes"]),
            t("folder_rename", "Rename the display label; original filesystem path stays the same.", ["id": .uuid, "name": .string(255)], ["id", "name"]),
            t("folder_options", "Apply a patch to all current FolderOptions. Intervals: 5/15/30/60/360/720/1440. No compression or FSEvents option.", ["id": .uuid, "options": .object(options)], ["id", "options"]),
            t("folder_delete", "Remove configuration, keeping originals by default. destroy=true requires confirmation='DELETE <UUID>'. Checkpoints remain.", ["id": .uuid, "destroy": .boolean, "confirmation": .string(64)], ["id"], destroy: true),
            t("folder_recover", "Explicit committed-checkpoint/original recovery; unsaved lost RAM cannot be recovered.", ref, ["id"], destroy: true),
            t("folder_export", "Export a committed revision to a NEW path. live=true captures through packaged CLI.", ["id": .uuid, "destination": .path, "revision": .uuid, "live": .boolean], ["id", "destination"]),
            t("folder_busy", "Observe open processes; never kills writers.", ref, ["id"], read: true),
            t("folder_open", "Ask macOS to open the configured folder in Finder. Requires a desktop; reports request acceptance only.", ref, ["id"]),
            t("folder_reveal", "Ask Finder to reveal the configured folder, as the app path link does. Reports request acceptance only.", ref, ["id"]),
            t("recovery_review", "Review a legacy publication missing its historic record. Returns evidence and a one-use, same-session token.", ref, ["id"], read: true),
            t("recovery_confirm", "Confirm ONLY the exact reviewed evidence. Requires acceptsMissingHistoricRecord=true and confirmation='ACCEPT MISSING HISTORIC RECORD'.", ["token": .uuid, "acceptsMissingHistoricRecord": .boolean, "confirmation": .string(64)], ["token", "acceptsMissingHistoricRecord", "confirmation"], destroy: true),
            t("recovery_cancel", "Cancel an outstanding same-session legacy review.", ["token": .uuid], ["token"]),
            t("settings_get", "Read menu mode and next-mount file verification preferences.", read: true),
            t("settings_update", "Persist menuBarMode and fileVerification. Existing sessions/revisions keep their verification. Running GUI appearance applies after app reload.", ["menuBarMode": .boolean, "fileVerification": .choice(["sha256", "sizeAndModTime"])]),
            t("login_item_get", "Read Open at Login using the APP-owned bounded bridge, without starting app mounts.", read: true),
            t("login_item_set", "Configure Open at Login for RAMNest.app; requires macOS approval if reported by ServiceManagement.", ["enabled": .boolean], ["enabled"]),
            t("storage_status", "Selected snapshot storage and asynchronous move/retry progress.", read: true),
            t("storage_move", "Start moving all snapshots/journals/preferences to a private RAMNest Snapshots child of an existing parent. Poll storage_status.", ["parent": .path], ["parent"]),
            t("storage_retry", "Resume an interrupted move/cleanup. Poll storage_status."),
            t("storage_pause", "Request cooperative pause BEFORE COMMIT. After commit cleanup may finish; poll storage_status."),
            t("settings_reset", "RESET managed records/snapshots; preserve originals, global preferences and selected storage, matching app RESET. Requires confirmation='RESET RAMNEST'.", ["confirmation": .string(64)], ["confirmation"], destroy: true),
            t("install_cli", "Install a symlink to this selected signed app's CLI in an existing chosen directory. Never overwrites.", ["directory": .path], ["directory"])
        ]
    }()
    public static func definition(_ name: String) throws -> ToolDefinition {
        guard let t = tools.first(where: { $0.name == name }) else { throw MCPFailure("unknown_tool", "Unknown tool: \(name).") }; return t
    }
}
