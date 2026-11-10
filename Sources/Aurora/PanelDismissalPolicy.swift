import Foundation
import CoreGraphics

enum PanelDismissalPolicy {
    static func shouldDismiss(at point: CGPoint, panel: CGRect, statusButton: CGRect?) -> Bool {
        if panel.insetBy(dx: -2, dy: -2).contains(point) { return false }
        if let statusButton, statusButton.insetBy(dx: -3, dy: -3).contains(point) { return false }
        return true
    }
}
