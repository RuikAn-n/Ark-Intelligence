import AppKit
import Foundation

@MainActor
final class ApplicationCapability {
    private let workspace = NSWorkspace.shared
    private var catalog: [[String: JSONValue]]?

    func prepare(action: String, arguments: [String: JSONValue]) async throws -> (preview: [String: JSONValue], read: [String: JSONValue]?) {
        switch action {
        case "applications.find_apps":
            let query = try arguments.requiredString("query").localizedLowercase
            let matches = installedApps().filter {
                ($0["name"]?.displayText.localizedLowercase.contains(query) ?? false) ||
                ($0["bundle_id"]?.displayText.localizedLowercase.contains(query) ?? false)
            }.prefix(20)
            let result: [String: JSONValue] = ["apps": .array(matches.map(JSONValue.object)), "verified": .bool(true)]
            return (["summary": .string("查找名称包含“\(query)”的应用")], result)
        case "applications.list_running_apps":
            let apps = workspace.runningApplications.filter { $0.activationPolicy == .regular }.compactMap { app -> JSONValue? in
                guard let id = app.bundleIdentifier else { return nil }
                return .object(["name": .string(app.localizedName ?? id), "bundle_id": .string(id), "pid": .number(Double(app.processIdentifier))])
            }
            return (["summary": .string("查看正在运行的应用")], ["apps": .array(apps), "verified": .bool(true)])
        case "applications.open_app", "applications.activate_app", "applications.quit_app":
            let id = try arguments.requiredString("bundle_id")
            guard id != Bundle.main.bundleIdentifier else { throw NativeActionError(code: "PERMISSION_DENIED", message: "不能通过自身连接退出 Ark") }
            guard let url = workspace.urlForApplication(withBundleIdentifier: id) else { throw NativeActionError(code: "TARGET_NOT_FOUND", message: "找不到 bundle ID 为 \(id) 的应用") }
            let verb = action.hasSuffix("open_app") ? "打开" : action.hasSuffix("activate_app") ? "切换到" : "正常退出"
            return (["summary": .string("\(verb) \(url.deletingPathExtension().lastPathComponent)"), "bundle_id": .string(id), "path": .string(url.path)], nil)
        default: throw NativeActionError(code: "CAPABILITY_UNAVAILABLE", message: "不支持的应用动作")
        }
    }

    func execute(action: String, arguments: [String: JSONValue], readResult: [String: JSONValue]?) async throws -> [String: JSONValue] {
        if let readResult { return readResult }
        let id = try arguments.requiredString("bundle_id")
        guard let url = workspace.urlForApplication(withBundleIdentifier: id) else { throw NativeActionError(code: "TARGET_NOT_FOUND", message: "应用已不存在") }
        switch action {
        case "applications.open_app":
            let app = try await workspace.openApplication(at: url, configuration: .init())
            return ["name": .string(app.localizedName ?? id), "bundle_id": .string(id), "pid": .number(Double(app.processIdentifier)), "verified": .bool(!app.isTerminated)]
        case "applications.activate_app":
            let app: NSRunningApplication
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).first { app = running }
            else { app = try await workspace.openApplication(at: url, configuration: .init()) }
            guard app.activate(options: []) else { throw NativeActionError(code: "EXECUTION_FAILED", message: "应用无法切换到前台") }
            return ["name": .string(app.localizedName ?? id), "bundle_id": .string(id), "pid": .number(Double(app.processIdentifier)), "verified": .bool(!app.isTerminated)]
        case "applications.quit_app":
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            if apps.isEmpty { return ["bundle_id": .string(id), "already_quit": .bool(true), "verified": .bool(true)] }
            guard apps.allSatisfy({ $0.terminate() }) else { throw NativeActionError(code: "EXECUTION_FAILED", message: "系统拒绝了正常退出请求") }
            for _ in 0..<50 {
                if apps.allSatisfy(\.isTerminated) { return ["bundle_id": .string(id), "verified": .bool(true)] }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw NativeActionError(code: "EXECUTION_FAILED", message: "应用仍在运行，可能正在等待你处理未保存内容")
        default: throw NativeActionError(code: "CAPABILITY_UNAVAILABLE", message: "不支持的应用动作")
        }
    }

    private func installedApps() -> [[String: JSONValue]] {
        if let catalog { return catalog }
        var roots = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"), URL(fileURLWithPath: "/System/Library/CoreServices/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        let cryptexApplications = URL(fileURLWithPath: "/Applications/Safari.app").resolvingSymlinksInPath().deletingLastPathComponent()
        if cryptexApplications.path != "/Applications" { roots.append(cryptexApplications) }
        var seen = Set<String>(), result: [[String: JSONValue]] = []
        for root in roots {
            for url in applicationURLs(in: root, remainingDepth: 3) {
                let resolvedURL = url.resolvingSymlinksInPath()
                guard let bundle = Bundle(url: resolvedURL), let id = bundle.bundleIdentifier, seen.insert(id).inserted else { continue }
                let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? url.deletingPathExtension().lastPathComponent
                result.append(["name": .string(name), "bundle_id": .string(id), "path": .string(resolvedURL.path)])
            }
        }
        catalog = result.sorted { $0["name"]!.displayText.localizedCompare($1["name"]!.displayText) == .orderedAscending }
        print("[ApplicationCapability] indexed \(catalog!.count) installed applications")
        return catalog!
    }

    private func applicationURLs(in directory: URL, remainingDepth: Int) -> [URL] {
        guard remainingDepth >= 0,
              let children = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var result: [URL] = []
        for child in children {
            if child.pathExtension.localizedLowercase == "app" { result.append(child); continue }
            if remainingDepth > 0, (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                result.append(contentsOf: applicationURLs(in: child, remainingDepth: remainingDepth - 1))
            }
        }
        return result
    }
}
