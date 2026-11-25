import SwiftUI

/// 在同一坐标系内处理标尺和片段，拖出轨道后也能在窗口内完成投放。
struct RecordingClipTrackInput: NSViewRepresentable {
    let map: RecordingEditMap
    let seek: (Double) -> Void
    let select: (RecordingClip, Double) -> Void
    let move: (RecordingClip, Int) -> Void
    @Binding var insertion: Int?

    func makeNSView(context: Context) -> Track { Track(self) }
    func updateNSView(_ view: Track, context: Context) { view.input = self }

    final class Track: NSView {
        var input: RecordingClipTrackInput
        private var startX: CGFloat = 0
        private var pressedClip: RecordingClip?
        private var dragging = false
        private var scrubbing = false

        init(_ input: RecordingClipTrackInput) {
            self.input = input
            super.init(frame: .zero)
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { nil }
        override var acceptsFirstResponder: Bool { true }
        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        private func seconds(_ x: CGFloat) -> Double {
            min(1, max(0, x / max(1, bounds.width))) * input.map.length
        }

        private func slot(_ x: CGFloat) -> Int {
            let t = seconds(x)
            return input.map.clips.firstIndex { t < $0.start + $0.length / 2 } ?? input.map.clips.count
        }

        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            window?.makeFirstResponder(self)
            startX = point.x
            dragging = false
            scrubbing = point.y < 15
            let t = seconds(point.x)
            pressedClip = scrubbing ? nil : input.map.clip(at: t)
            if scrubbing { input.seek(t) }
            else if let pressedClip { input.select(pressedClip, t) }
        }

        override func mouseDragged(with event: NSEvent) {
            let x = convert(event.locationInWindow, from: nil).x
            if scrubbing { input.seek(seconds(x)); return }
            if pressedClip != nil && (dragging || abs(x - startX) >= 4) {
                dragging = true
                input.insertion = slot(x)
            }
        }

        override func mouseUp(with event: NSEvent) {
            if dragging, let pressedClip {
                input.move(pressedClip, slot(convert(event.locationInWindow, from: nil).x))
            }
            pressedClip = nil
            input.insertion = nil
            dragging = false
            scrubbing = false
        }
    }
}
