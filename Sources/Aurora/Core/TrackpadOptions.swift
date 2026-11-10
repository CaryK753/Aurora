import Foundation

struct TrackpadOption: Identifiable {
    enum Section: String, CaseIterable { case point = "光标与点按", scroll = "滚动与缩放", gestures = "更多手势", access = "拖移与辅助功能" }
    struct Write {
        let domain: String
        let key: String
        let host: Bool
        let value: Int
    }
    let id: String
    let title: String
    let section: Section
    let choices: [String]
    let domain: String
    let key: String
    let values: [Int]
    var hostKey: String? = nil
    var dockKey: String? = nil
    var defaultValue: Int = 0
    var note: String? = nil

    static let internalDomain = "com.apple.AppleMultitouchTrackpad"
    static let externalDomain = "com.apple.driver.AppleBluetoothMultitouch.trackpad"
    static let global = "NSGlobalDomain"
    static let dock = "com.apple.dock"

    func writes(choice: Int) -> [Write] {
        guard values.indices.contains(choice) else { return [] }
        let value = values[choice]
        var result = [Write(domain: domain, key: key, host: false, value: value)]
        if domain == Self.internalDomain {
            result.append(Write(domain: Self.externalDomain, key: key, host: false, value: value))
        }
        if let hostKey { result.append(Write(domain: Self.global, key: hostKey, host: true, value: value)) }
        if id == "tap" {
            result += [false, true].map { Write(domain: Self.global, key: "com.apple.mouse.tapBehavior", host: $0, value: value) }
        }
        if id == "spaces" || id == "mission" || id == "expose" {
            let horizontal = id == "spaces"
            let threeKey = horizontal ? "TrackpadThreeFingerHorizSwipeGesture" : "TrackpadThreeFingerVertSwipeGesture"
            let fourKey = horizontal ? "TrackpadFourFingerHorizSwipeGesture" : "TrackpadFourFingerVertSwipeGesture"
            let threeHost = horizontal ? "com.apple.trackpad.threeFingerHorizSwipeGesture" : "com.apple.trackpad.threeFingerVertSwipeGesture"
            let fourHost = horizontal ? "com.apple.trackpad.fourFingerHorizSwipeGesture" : "com.apple.trackpad.fourFingerVertSwipeGesture"
            result = []
            if horizontal || choice != 0 {
                for domain in [Self.internalDomain, Self.externalDomain] {
                    result.append(Write(domain: domain, key: threeKey, host: false, value: choice == 1 ? 2 : 0))
                    result.append(Write(domain: domain, key: fourKey, host: false, value: choice == 2 ? 2 : 0))
                }
                result.append(Write(domain: Self.global, key: threeHost, host: true, value: choice == 1 ? 2 : 0))
                result.append(Write(domain: Self.global, key: fourHost, host: true, value: choice == 2 ? 2 : 0))
            }
            if let dockKey { result.append(Write(domain: Self.dock, key: dockKey, host: false, value: choice == 0 ? 0 : 1)) }
            return result
        }
        if id == "desktop" || id == "apps", value != 0 {
            for domain in [Self.internalDomain, Self.externalDomain] {
                for key in ["TrackpadFourFingerPinchGesture", "TrackpadFiveFingerPinchGesture"] {
                    result.append(Write(domain: domain, key: key, host: false, value: 2))
                }
            }
        }
        if id == "lookup" {
            for domain in [Self.internalDomain, Self.externalDomain] {
                result.append(Write(domain: domain, key: "TrackpadThreeFingerTapGesture", host: false, value: choice == 2 ? 2 : 0))
            }
            result.append(Write(domain: Self.global, key: "com.apple.trackpad.threeFingerTapGesture", host: true, value: choice == 2 ? 2 : 0))
        }
        if id == "corner" && value != 0 {
            for domain in [Self.internalDomain, Self.externalDomain] {
                result.append(Write(domain: domain, key: "TrackpadRightClick", host: false, value: 0))
            }
        }
        if id == "secondary" {
            result.append(Write(domain: Self.global, key: "com.apple.trackpad.enableSecondaryClick", host: true, value: value))
        }
        if id == "pressure" {
            result += [Self.internalDomain, Self.externalDomain].map {
                Write(domain: $0, key: "SecondClickThreshold", host: false, value: value)
            }
        }
        if let dockKey { result.append(Write(domain: Self.dock, key: dockKey, host: false, value: value == 0 ? 0 : 1)) }
        if id == "drag" && value == 1 {
            for domain in [Self.internalDomain, Self.externalDomain] {
                for key in ["Dragging", "DragLock"] { result.append(Write(domain: domain, key: key, host: false, value: 0)) }
            }
        }
        return result
    }

    private static func toggle(_ id: String, _ title: String, _ section: Section, _ key: String,
                               on: Int = 1, defaultValue: Int = 0, host: String? = nil,
                               domain: String = internalDomain, dock: String? = nil, note: String? = nil) -> TrackpadOption {
        TrackpadOption(id: id, title: title, section: section, choices: ["关闭", "开启"], domain: domain,
                       key: key, values: [0, on], hostKey: host, dockKey: dock, defaultValue: defaultValue, note: note)
    }

    static let all: [TrackpadOption] = [
        toggle("tap", "轻点来点按", .point, "Clicking"),
        toggle("secondary", "双指辅助点按", .point, "TrackpadRightClick", defaultValue: 1),
        TrackpadOption(id: "corner", title: "角落辅助点按", section: .point, choices: ["关闭", "左下角", "右下角"],
                       domain: internalDomain, key: "TrackpadCornerSecondaryClick", values: [0, 1, 2]),
        TrackpadOption(id: "pressure", title: "点按力度", section: .point, choices: ["轻", "中", "强"],
                       domain: internalDomain, key: "FirstClickThreshold", values: [0, 1, 2], defaultValue: 1),
        TrackpadOption(id: "lookup", title: "查询与数据检测器", section: .point,
                       choices: ["关闭", "用力点按", "三指轻点"], domain: global,
                       key: "com.apple.trackpad.forceClick", values: [0, 1, 0], defaultValue: 1),
        TrackpadOption(id: "force", title: "用力点按与触感反馈", section: .point, choices: ["关闭", "开启"],
                       domain: internalDomain, key: "ForceSuppressed", values: [1, 0]),
        toggle("natural", "自然滚动", .scroll, "com.apple.swipescrolldirection", defaultValue: 1, domain: global,
               note: "此设置与系统鼠标的自然滚动共用"),
        toggle("pinch", "放大或缩小", .scroll, "TrackpadPinch", defaultValue: 1, host: "com.apple.trackpad.pinchGesture"),
        toggle("smartZoom", "智能缩放", .scroll, "TrackpadTwoFingerDoubleTapGesture", defaultValue: 1,
               host: "com.apple.trackpad.twoFingerDoubleTapGesture"),
        toggle("rotate", "旋转", .scroll, "TrackpadRotate", defaultValue: 1, host: "com.apple.trackpad.rotateGesture"),
        toggle("pages", "在页面之间轻扫", .gestures, "AppleEnableSwipeNavigateWithScrolls", defaultValue: 1, domain: global),
        TrackpadOption(id: "spaces", title: "在全屏幕应用之间轻扫", section: .gestures,
                       choices: ["关闭", "三指", "四指"], domain: internalDomain,
                       key: "TrackpadFourFingerHorizSwipeGesture", values: [0, 3, 4], defaultValue: 2),
        toggle("notification", "通知中心", .gestures, "TrackpadTwoFingerFromRightEdgeSwipeGesture", on: 3, defaultValue: 3),
        TrackpadOption(id: "mission", title: "调度中心", section: .gestures, choices: ["关闭", "三指上扫", "四指上扫"],
                       domain: internalDomain, key: "TrackpadFourFingerVertSwipeGesture", values: [0, 3, 4],
                       dockKey: "showMissionControlGestureEnabled", defaultValue: 2),
        TrackpadOption(id: "expose", title: "App Exposé", section: .gestures, choices: ["关闭", "三指下扫", "四指下扫"],
                       domain: internalDomain, key: "TrackpadFourFingerVertSwipeGesture", values: [0, 3, 4],
                       dockKey: "showAppExposeGestureEnabled", defaultValue: 2,
                       note: "调度中心和 App Exposé 共用系统的手指数设置"),
        toggle("desktop", "显示桌面", .gestures, "showDesktopGestureEnabled", defaultValue: 1, domain: dock),
        toggle("apps", "启动台／应用程序手势", .gestures, "showLaunchpadGestureEnabled", defaultValue: 1, domain: dock),
        toggle("drag", "三指拖移", .access, "TrackpadThreeFingerDrag", host: "com.apple.trackpad.threeFingerDragGesture",
               note: "启用三指拖移后，请使用四指切换空间和打开调度中心")
    ]
}
