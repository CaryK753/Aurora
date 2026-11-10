import AppKit
import Darwin

@MainActor
enum SingleInstance {
    private static var descriptor: Int32 = -1

    static func acquire() -> Bool {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aurora", isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { Debug.log("single instance directory: \(error)"); return false }
        descriptor = Darwin.open(directory.appendingPathComponent("instance.lock").path,
                                 O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return false }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            descriptor = -1
            if let id = Bundle.main.bundleIdentifier {
                NSRunningApplication.runningApplications(withBundleIdentifier: id)
                    .first(where: { $0.processIdentifier != getpid() })?.activate()
            }
            return false
        }
        return true
    }
}
