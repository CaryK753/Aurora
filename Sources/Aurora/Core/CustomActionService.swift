//  CustomActionService.swift
//  Aurora — 自定义右键动作：生成 Automator 快速操作（.workflow），由系统菜单承载
//  说明：不做 FinderSync 扩展，改用系统原生的「快速操作」通道，稳定性更好，也能被本应用统一开关。

import AppKit
import Combine

struct CustomAction: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var command: String
    var enabled: Bool

    var fileName: String { "Aurora - \(name).workflow" }
}

@MainActor
final class CustomActionService: ObservableObject {
    @Published private(set) var actions: [CustomAction] = []
    @Published var draftName: String = ""
    @Published var draftCommand: String = ""

    private let servicesDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Services", isDirectory: true)
    private let storeURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aurora", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        storeURL = support.appendingPathComponent("actions.json")
        load()
        // 缺失的 workflow 补齐
        for action in actions where action.enabled {
            if !FileManager.default.fileExists(atPath: workflowURL(action).path) {
                writeWorkflow(action)
            }
        }
    }

    var canAdd: Bool {
        !draftName.trimmingCharacters(in: .whitespaces).isEmpty
            && !draftCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func add() {
        guard canAdd else { return }
        let action = CustomAction(
            id: UUID(),
            name: draftName.trimmingCharacters(in: .whitespaces),
            command: draftCommand,
            enabled: true
        )
        actions.append(action)
        writeWorkflow(action)
        draftName = ""
        draftCommand = ""
        save()
        refreshFinder()
    }

    func remove(_ action: CustomAction) {
        try? FileManager.default.removeItem(at: workflowURL(action))
        actions.removeAll { $0.id == action.id }
        save()
        refreshFinder()
    }

    func setEnabled(_ action: CustomAction, enabled: Bool) {
        guard let index = actions.firstIndex(where: { $0.id == action.id }) else { return }
        actions[index].enabled = enabled
        if enabled {
            writeWorkflow(actions[index])
        } else {
            try? FileManager.default.removeItem(at: workflowURL(actions[index]))
        }
        save()
        refreshFinder()
    }

    func openServicesFolder() {
        NSWorkspace.shared.open(servicesDirectory)
    }

    // MARK: - 生成 workflow

    private func workflowURL(_ action: CustomAction) -> URL {
        servicesDirectory.appendingPathComponent(action.fileName)
    }

    private func writeWorkflow(_ action: CustomAction) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: servicesDirectory, withIntermediateDirectories: true)

        let bundleURL = workflowURL(action)
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        try? fileManager.createDirectory(at: contentsURL, withIntermediateDirectories: true)

        let command = xmlEscape(action.command)
        let uuid = UUID().uuidString
        let outputUUID = UUID().uuidString

        let workflow = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>AMApplicationBuild</key>
            <string>521</string>
            <key>AMApplicationVersion</key>
            <string>2.10</string>
            <key>AMDocumentVersion</key>
            <string>2</string>
            <key>actions</key>
            <array>
                <dict>
                    <key>action</key>
                    <dict>
                        <key>AMAccepts</key>
                        <dict>
                            <key>Container</key>
                            <string>List</string>
                            <key>Optional</key>
                            <true/>
                            <key>Types</key>
                            <array>
                                <string>com.apple.cocoa.string</string>
                            </array>
                        </dict>
                        <key>AMActionVersion</key>
                        <string>2.0.3</string>
                        <key>AMApplication</key>
                        <array>
                            <string>Automator</string>
                        </array>
                        <key>AMParameterProperties</key>
                        <dict>
                            <key>COMMAND_STRING</key>
                            <dict/>
                            <key>CheckedForUserDefaultShell</key>
                            <dict/>
                            <key>inputMethod</key>
                            <dict/>
                            <key>shell</key>
                            <dict/>
                            <key>source</key>
                            <dict/>
                        </dict>
                        <key>AMProvides</key>
                        <dict>
                            <key>Container</key>
                            <string>List</string>
                            <key>Types</key>
                            <array>
                                <string>com.apple.cocoa.string</string>
                            </array>
                        </dict>
                        <key>ActionBundlePath</key>
                        <string>/System/Library/Automator/Run Shell Script.action</string>
                        <key>ActionName</key>
                        <string>Run Shell Script</string>
                        <key>ActionParameters</key>
                        <dict>
                            <key>COMMAND_STRING</key>
                            <string>\(command)</string>
                            <key>CheckedForUserDefaultShell</key>
                            <true/>
                            <key>inputMethod</key>
                            <integer>1</integer>
                            <key>shell</key>
                            <string>/bin/bash</string>
                            <key>source</key>
                            <string></string>
                        </dict>
                        <key>BundleIdentifier</key>
                        <string>com.apple.RunShellScript</string>
                        <key>CFBundleVersion</key>
                        <string>2.0.3</string>
                        <key>CanShowSelectedItemsWhenRun</key>
                        <false/>
                        <key>CanShowWhenRun</key>
                        <true/>
                        <key>Category</key>
                        <array>
                            <string>AMCategoryUtilities</string>
                        </array>
                        <key>Class Name</key>
                        <string>RunShellScriptAction</string>
                        <key>InputUUID</key>
                        <string>\(uuid)</string>
                        <key>Keywords</key>
                        <array>
                            <string>Shell</string>
                            <string>Script</string>
                        </array>
                        <key>OutputUUID</key>
                        <string>\(outputUUID)</string>
                        <key>UUID</key>
                        <string>\(outputUUID)</string>
                        <key>UnlocalizedApplications</key>
                        <array>
                            <string>Automator</string>
                        </array>
                        <key>arguments</key>
                        <dict/>
                        <key>isViewVisible</key>
                        <integer>1</integer>
                        <key>location</key>
                        <string>300.000000:250.000000</string>
                        <key>nibPath</key>
                        <string>/System/Library/Automator/Run Shell Script.action/Contents/Resources/Base.lproj/main.nib</string>
                    </dict>
                    <key>isViewVisible</key>
                    <integer>1</integer>
                </dict>
            </array>
            <key>connectors</key>
            <dict/>
            <key>workflowMetaData</key>
            <dict>
                <key>applicationBundleIDsByPath</key>
                <dict/>
                <key>applicationPaths</key>
                <array/>
                <key>inputTypeIdentifier</key>
                <string>com.apple.Automator.fileSystemObject</string>
                <key>outputTypeIdentifier</key>
                <string>com.apple.Automator.nothing</string>
                <key>presentationMode</key>
                <integer>11</integer>
                <key>processesInput</key>
                <false/>
                <key>serviceInputTypeIdentifier</key>
                <string>com.apple.Automator.fileSystemObject</string>
                <key>serviceOutputTypeIdentifier</key>
                <string>com.apple.Automator.nothing</string>
                <key>serviceProcessesInput</key>
                <false/>
                <key>systemImageName</key>
                <string>NSActionTemplate</string>
                <key>useAutomaticInputType</key>
                <false/>
                <key>workflowTypeIdentifier</key>
                <string>com.apple.Automator.servicesMenu</string>
            </dict>
        </dict>
        </plist>
        """

        try? workflow.write(to: contentsURL.appendingPathComponent("document.wflow"), atomically: true, encoding: .utf8)

        // pbs 通过 Info.plist 里的 NSServices 注册服务
        let info = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>NSServices</key>
            <array>
                <dict>
                    <key>NSBackgroundColorName</key>
                    <string>background</string>
                    <key>NSIconName</key>
                    <string>NSActionTemplate</string>
                    <key>NSMenuItem</key>
                    <dict>
                        <key>default</key>
                        <string>\(xmlEscape(action.name))</string>
                    </dict>
                    <key>NSMessage</key>
                    <string>runWorkflowAsService</string>
                    <key>NSSendTypes</key>
                    <array>
                        <string>public.item</string>
                    </array>
                </dict>
            </array>
        </dict>
        </plist>
        """
        try? info.write(to: contentsURL.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)

        // 让 pbs 立刻感知
        let register = Process()
        register.executableURL = URL(fileURLWithPath: "/System/Library/CoreServices/pbs")
        register.arguments = ["-flush"]
        try? register.run()
    }

    private func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func refreshFinder() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Finder"]
        try? process.run()
    }

    // MARK: - 持久化

    private func save() {
        if let data = try? JSONEncoder().encode(actions) {
            try? data.write(to: storeURL)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([CustomAction].self, from: data) else { return }
        actions = decoded
    }
}
