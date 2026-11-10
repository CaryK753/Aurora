import Foundation

func check(_ title: String, _ condition: @autoclosure () -> Bool) {
    precondition(condition(), title)
    print("✓ \(title)")
}
let global: [String: Any] = ["scrolling": ["reverse": ["vertical": true, "horizontal": false]]]
let appOnly: [String: Any] = ["if": ["app": "example.app"], "scrolling": ["reverse": false]]
let trackpad: [String: Any] = ["if": ["device": ["category": "trackpad"]], "scrolling": ["reverse": false]]
let deviceSpecific: [String: Any] = ["if": ["device": ["category": "mouse", "vendorID": 123]], "scrolling": ["reverse": false]]
let filtered = ImportParsing.linearMouse([global, appOnly, trackpad, deviceSpecific])
check("全局垂直反转可迁移，应用、触控板及专用设备规则不混入", filtered.reverse == true)
let mouse: [String: Any] = ["if": ["device": ["category": "mouse"]],
    "scrolling": ["reverse": false, "modifiers": ["vertical": ["shift": ["type": "alterOrientation"]]]]]
let mouseResult = ImportParsing.linearMouse([global, mouse])
check("鼠标通用配置及 Shift 轴切换可读取", mouseResult.reverse == false && mouseResult.shiftHorizontal == true)
check("空配置没有伪造默认导入项", ImportParsing.linearMouse([]).reverse == nil)
let tap = TrackpadOption.all.first { $0.id == "tap" }!.writes(choice: 1)
check("轻点写入内外触控板和全局主机设置", tap.count == 4 && tap.allSatisfy { $0.value == 1 })
let drag = TrackpadOption.all.first { $0.id == "drag" }!.writes(choice: 1)
check("三指拖移同时关闭普通拖移及拖移锁", drag.filter { $0.key == "Dragging" || $0.key == "DragLock" }.allSatisfy { $0.value == 0 } && drag.count == 7)
let lookup = TrackpadOption.all.first { $0.id == "lookup" }!.writes(choice: 2)
check("三指查询不会误启用用力点按查询", lookup.first?.value == 0 && lookup.contains { $0.key == "TrackpadThreeFingerTapGesture" && $0.value == 2 })
check("非法选项不产生设置写入", TrackpadOption.all.allSatisfy { $0.writes(choice: -1).isEmpty && $0.writes(choice: 99).isEmpty })

let spaces = TrackpadOption.all.first { $0.id == "spaces" }!
let three = spaces.writes(choice: 1)
let four = spaces.writes(choice: 2)
check("三指与四指切换空间互斥配置", three.contains { $0.key == "TrackpadThreeFingerHorizSwipeGesture" && $0.value == 2 }
      && three.contains { $0.key == "TrackpadFourFingerHorizSwipeGesture" && $0.value == 0 }
      && four.contains { $0.key == "TrackpadThreeFingerHorizSwipeGesture" && $0.value == 0 }
      && four.contains { $0.key == "TrackpadFourFingerHorizSwipeGesture" && $0.value == 2 })
let missionOff = TrackpadOption.all.first { $0.id == "mission" }!.writes(choice: 0)
check("关闭调度中心不清除 App Exposé 共用的滑动手势", missionOff.count == 1 && missionOff.first?.key == "showMissionControlGestureEnabled")
