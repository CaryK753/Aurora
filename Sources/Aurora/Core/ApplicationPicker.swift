import AppKit
import UniformTypeIdentifiers

@MainActor
enum ApplicationPicker {
    static func choose(completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.title = T("选择要打开的应用程序")
        panel.prompt = T("选择应用程序")
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            Task { @MainActor in completion(response == .OK ? panel.url : nil) }
        }
    }
}
