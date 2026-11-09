import Foundation
import RAMNestCore
@testable import RAMNestMCPKit

enum MCPScenarios {
    static func check(_ value: Bool, _ message: String) throws {
        if !value { throw MCPFailure("test_failed", message) }
    }
    static func expectFailure(_ body: () async throws -> JSON, _ message: String) async throws {
        do { _ = try await body() }
        catch { return }
        throw MCPFailure("test_failed", "Expected failure: " + message)
    }
    static func run() async throws {
        let fm = FileManager.default
        let artifacts = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("artifacts")
        try fm.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let root = artifacts.appendingPathComponent("ramnest-mcp-owned-tests-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        let activities = Activities(bootstrap: root.appendingPathComponent("store"))
        let absent = UUID().uuidString

        // Every handler rejects unknown keys BEFORE it can open a store or act.
        for tool in ToolCatalog.tools {
            try check(tool.schema["additionalProperties"] == .bool(false), tool.name + " exact schema")
            do {
                try await expectFailure({ try await activities.call(tool.name, arguments: ["unexpected": .bool(true)]) }, tool.name + " unknown key")
                var valid = tool.fields.mapValues { sample($0) }
                try tool.validate(valid)
                for (key, _) in tool.fields {
                    // Null is never a default and is not silently coerced.
                    let old = valid[key]; valid[key] = .null
                    defer { valid[key] = old }
                    do { try tool.validate(valid); throw MCPFailure("test_failed", tool.name + "." + key + " accepted null") }
                    catch let error as MCPFailure where error.code == "test_failed" { throw error }
                    catch { }
                }
            }
        }
        try await expectFailure({ try await activities.call("arbitrary_shell", arguments: ["command": .string("true")]) }, "no shell API")
        let capability = try await activities.call("capabilities")
        try check(capability["backend"] == .string("tmpfs") && capability["startupMounts"] == .bool(false), "fixed backend; no auto mounts")
        try check(capability["package"]?["available"] == .bool(false), "unpackaged native prerequisite explicit")
        try check(!fm.fileExists(atPath: root.appendingPathComponent("store").path), "capabilities does not open store")

        let source = root.appendingPathComponent("original")
        try fm.createDirectory(at: source, withIntermediateDirectories: false)
        let bytes = Data("original fixture bytes\n".utf8)
        try bytes.write(to: source.appendingPathComponent("payload"))
        let created = try await activities.call("folder_create", arguments: ["path": .string(source.path), "name": .string("Fixture"), "capacityBytes": .integer(32 << 20)])
        guard case .string(let id) = created["id"] else { throw MCPFailure("test_failed", "Missing created ID") }
        let ref: [String: JSON] = ["id": .string(id)]
        let info = try await activities.call("folder_info", arguments: ref)
        try check(info["mounted"] == .bool(false) && info["journal"]?["phase"] == .string("idle"), "create defaults to no mount")
        try check(info["journal"]?["nativeTmpfs"] == nil, "no native session was created")
        let renamed = try await activities.call("folder_rename", arguments: ref.merging(["name": .string("Renamed")]) { _, v in v })
        try check(renamed["name"] == .string("Renamed"), "rename readback")
        let options: [String: JSON] = ["mountAtLaunch": .bool(false), "nobrowse": .bool(false), "sync": .bool(true), "periodicSave": .bool(true), "intervalMinutes": .integer(30), "comparison": .string("checksum")]
        let updated = try await activities.call("folder_options", arguments: ref.merging(["options": .object(options)]) { _, v in v })
        for (key, value) in options { try check(updated["options"]?[key] == value, "option " + key + " readback") }
        let resized = try await activities.call("folder_resize", arguments: ref.merging(["capacityBytes": .integer(48 << 20)]) { _, v in v })
        try check(resized["capacity"] == .integer(48 << 20), "resize readback")
        let prefs: [String: JSON] = ["menuBarMode": .bool(true), "fileVerification": .string("sizeAndModTime")]
        _ = try await activities.call("settings_update", arguments: prefs)
        let saved = try await activities.call("settings_get")
        for (key, value) in prefs { try check(saved[key] == value, "global preference readback") }
        let reopened = Activities(bootstrap: root.appendingPathComponent("store"))
        let reloaded = try await reopened.call("settings_get")
        for (key, value) in prefs { try check(reloaded[key] == value, "persisted preference " + key) }
        await reopened.shutdown()

        let negatives: [(String, [String: JSON])] = [
            ("folder_create", ["path": .string(source.path), "capacityBytes": .integer(1)]),
            ("folder_create", ["path": .string(root.appendingPathComponent("missing").path), "capacityBytes": .integer(32 << 20)]),
            ("folder_create", ["path": .string(source.path), "capacityBytes": .integer(32 << 20), "options": .object(["compression": .bool(true)])]),
            ("folder_create", ["path": .string(source.path), "capacityBytes": .integer(32 << 20), "mount": .bool(true)]),
            ("folder_info", ["id": .string(absent)]), ("folder_open", ["id": .string(absent)]), ("folder_reveal", ["id": .string(absent)]),
            ("folder_options", ref.merging(["options": .object(["intervalMinutes": .integer(6)])]) { _, v in v }),
            ("folder_options", ref.merging(["options": .object(["sync": .string("true")])]) { _, v in v }),
            ("folder_options", ref.merging(["options": .object([:])]) { _, v in v }),
            ("folder_rename", ref.merging(["name": .string("bad\nname")]) { _, v in v }),
            ("folder_delete", ref.merging(["destroy": .bool(true)]) { _, v in v }),
            ("folder_delete", ref.merging(["destroy": .bool(true), "confirmation": .string("DELETE " + absent)]) { _, v in v }),
            ("folder_delete", ref.merging(["destroy": .string("false")]) { _, v in v }),
            ("folder_export", ref.merging(["destination": .string(root.appendingPathComponent("export").path)]) { _, v in v }),
            ("folder_export", ref.merging(["destination": .string(root.appendingPathComponent("export").path), "live": .bool(true), "revision": .string(absent)]) { _, v in v }),
            ("folder_recover", ref), ("recovery_review", ref),
            ("recovery_confirm", ["token": .string(absent), "acceptsMissingHistoricRecord": .bool(false), "confirmation": .string("ACCEPT MISSING HISTORIC RECORD")]),
            ("recovery_confirm", ["token": .string(absent), "acceptsMissingHistoricRecord": .bool(true), "confirmation": .string("ACCEPT MISSING HISTORIC RECORD")]),
            ("recovery_cancel", ["token": .string(absent)]),
            ("settings_update", ["backend": .string("fskit")]), ("settings_update", [:]),
            ("settings_update", ["fileVerification": .string("checksum")]),
            ("settings_reset", ["confirmation": .string("yes")]),
            ("storage_pause", [:]), ("storage_retry", [:]),
            ("storage_move", ["parent": .string(root.appendingPathComponent("missing").path)]),
            ("login_item_get", [:]), ("login_item_set", ["enabled": .bool(true)]),
            ("install_cli", ["directory": .string(root.path)])
        ]
        // storage_move is asynchronous: test its final failure separately.
        for (name, args) in negatives where name != "storage_move" {
            try await expectFailure({ try await activities.call(name, arguments: args) }, name)
        }
        for name in ["folder_mount", "folder_reconnect", "folder_save"] {
            try await expectFailure({ try await activities.call(name, arguments: ref) }, name + " package prerequisite")
        }
        _ = try await activities.call("folder_unmount", arguments: ref) // explicit alreadyIdle
        _ = try await activities.call("folder_busy", arguments: ref)
        try check(try Data(contentsOf: source.appendingPathComponent("payload")) == bytes, "negative handlers preserve originals")
        _ = try await activities.call("folder_delete", arguments: ref)
        try check(try Data(contentsOf: source.appendingPathComponent("payload")) == bytes, "delete keep preserves originals")
        let list = try await activities.call("folder_list")
        try check(list == .array([]), "deleted configuration absent")

        let resetFolder = try await activities.call("folder_create", arguments: ["path": .string(source.path), "capacityBytes": .integer(32 << 20)])
        try check(resetFolder["id"] != nil, "second fixture admitted")
        _ = try await activities.call("settings_reset", arguments: ["confirmation": .string("RESET RAMNEST")])
        try check(try await activities.call("folder_list") == .array([]), "reset removes records")
        try check(try Data(contentsOf: source.appendingPathComponent("payload")) == bytes, "reset preserves originals")

        let parent = root.appendingPathComponent("destination-parent")
        try fm.createDirectory(at: parent, withIntermediateDirectories: false)
        _ = try await activities.call("storage_move", arguments: ["parent": .string(parent.path)])
        let done = try await waitForStorage(activities)
        try check(done["path"] == .string(parent.appendingPathComponent("RAMNest Snapshots").path), "selected storage changed")
        let afterMove = try await activities.call("settings_get")
        try check(afterMove["fileVerification"] == prefs["fileVerification"], "move retains preferences")
        _ = try await activities.call("settings_reset", arguments: ["confirmation": .string("RESET RAMNEST")])
        let afterReset = try await activities.call("storage_status")
        try check(afterReset["path"] == done["path"], "reset preserves selected storage")
        _ = try await activities.call("storage_move", arguments: ["parent": .string(root.appendingPathComponent("missing-parent").path)])
        try await expectFailure({ try await waitForStorage(activities) }, "asynchronous worker failure is reported")
        _ = try await activities.call("settings_get") // failed worker releases exclusive ownership
        await activities.shutdown()
        try await expectFailure({ try await activities.call("folder_list") }, "closed session")
        try await MCPAdvancedScenarios.run(root: root)
    }
    static func sample(_ arg: Argument) -> JSON {
        switch arg {
        case .boolean: return .bool(false)
        case .string: return .string("fixture")
        case .integer(let min, _): return .integer(min)
        case .integers(let values): return .integer(values[0])
        case .choice(let values): return .string(values[0])
        case .uuid: return .string(UUID().uuidString)
        case .path: return .string("/Volumes/owned-fixture")
        case .object(let fields): return .object(fields.mapValues { sample($0) })
        }
    }
    static func waitForStorage(_ activities: Activities) async throws -> JSON {
        for _ in 0..<500 {
            let value = try await activities.call("storage_status")
            if value["job"]?["running"] == .bool(false) {
                if let error = value["job"]?["error"], error != .null { throw MCPFailure("test_failed", "Storage job: \(error)") }
                return value
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw MCPFailure("test_failed", "Storage worker did not finish within 10 seconds")
    }
}
