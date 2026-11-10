import Foundation
let panel = CGRect(x: 100, y: 100, width: 476, height: 664)
let button = CGRect(x: 300, y: 780, width: 24, height: 24)
func check(_ name: String, _ point: CGPoint, _ expected: Bool, buttonRect: CGRect? = button) {
    precondition(PanelDismissalPolicy.shouldDismiss(at: point, panel: panel, statusButton: buttonRect) == expected, name)
    print("✓ \(name)")
}
check("主面板内点击不收起", CGPoint(x: 180, y: 200), false)
check("菜单栏图标点击交由切换动作处理", CGPoint(x: 310, y: 790), false)
check("外部点击收起", CGPoint(x: 20, y: 20), true)
check("没有菜单栏锚点仍正确处理外部点击", CGPoint(x: 310, y: 790), true, buttonRect: nil)
check("面板边缘容错", CGPoint(x: 99, y: 105), false)
