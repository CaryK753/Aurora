import Combine
import Foundation

struct ZoomDraftFile: Codable {
    var version: Int
    var segments: [ZoomSegment]
    var appearance: RecordingAppearance?
}

@MainActor
final class ZoomTimelineDraft: ObservableObject {
    let movie: URL
    @Published var segments: [ZoomSegment] = [] {
        didSet { if loaded && oldValue != segments { scheduleSave() } }
    }
    @Published var appearance = RecordingAppearance() {
        didSet { if loaded && oldValue != appearance { scheduleSave() } }
    }
    @Published private(set) var saveError: String?
    private var loaded = false
    private var dirty = false
    private var revision = 0
    private var scheduled: Task<Void, Never>?
    private let writer = DispatchQueue(label: "aurora.zoom-draft")
    private var file: URL { Self.file(for: movie) }

    init(movie: URL) { self.movie = movie }

    nonisolated static func file(for movie: URL) -> URL {
        movie.deletingLastPathComponent().appendingPathComponent("." + movie.lastPathComponent + ".zoom-edits.json")
    }

    nonisolated static func read(for movie: URL, duration: Double) throws -> [ZoomSegment]? {
        try readDocument(for: movie, duration: duration)?.segments
    }

    nonisolated static func readDocument(for movie: URL, duration: Double) throws -> ZoomDraftFile? {
        let data: Data
        do { data = try Data(contentsOf: file(for: movie)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        let draft = try JSONDecoder().decode(ZoomDraftFile.self, from: data)
        guard draft.version == 1 else { throw CocoaError(.fileReadUnsupportedScheme) }
        if let clips = draft.appearance?.clipOrder {
            var last = 0.0
            for clip in clips.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                guard clip.lowerBound >= last, clip.lowerBound < clip.upperBound,
                      clip.upperBound <= duration else { throw CocoaError(.fileReadCorruptFile) }
                last = clip.upperBound
            }
        }
        var previousEnd = 0.0
        var ids = Set<UUID>()
        for segment in draft.segments {
            guard ids.insert(segment.id).inserted, segment.start >= previousEnd,
                  segment.start < segment.end, segment.end <= duration,
                  (0...1).contains(segment.center.x), (0...1).contains(segment.center.y),
                  (1...4).contains(segment.scale) else { throw CocoaError(.fileReadCorruptFile) }
            previousEnd = segment.end
        }
        return draft
    }

    func restore(_ initial: [ZoomSegment], appearance: RecordingAppearance = .init()) {
        guard !loaded else { return }
        segments = initial
        self.appearance = appearance
        loaded = true
    }

    private nonisolated static func write(_ draft: ZoomDraftFile, to file: URL) throws {
        try JSONEncoder().encode(draft).write(to: file, options: .atomic)
    }

    private func scheduleSave() {
        dirty = true
        revision += 1
        guard scheduled == nil else { return }
        scheduled = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard let self else { return }
            scheduled = nil
            let stamp = revision, snapshot = ZoomDraftFile(version: 1, segments: segments, appearance: appearance), url = file
            writer.async {
                let result = Result { try Self.write(snapshot, to: url) }
                Task { @MainActor in
                    guard self.revision == stamp else { return }
                    switch result {
                    case .success: self.dirty = false; self.saveError = nil
                    case .failure(let error): self.saveError = error.localizedDescription
                    }
                }
            }
        }
    }

    func flush() throws {
        scheduled?.cancel()
        scheduled = nil
        guard dirty else { return }
        revision += 1
        let snapshot = ZoomDraftFile(version: 1, segments: segments, appearance: appearance), url = file
        do {
            try writer.sync { try Self.write(snapshot, to: url) }
            dirty = false
            saveError = nil
        } catch {
            saveError = error.localizedDescription
            throw error
        }
    }
}
