import AppKit
import ScreenCaptureKit

struct RecorderSource: Identifiable, Equatable {
    enum Kind: String { case display, window, area, mobile }
    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    var display: SCDisplay?
    var window: SCWindow?
    /// 区域录制：全局 NS 坐标矩形
    var rect: CGRect?

    var supportsSystemAudio: Bool { kind == .display || kind == .area }
}
