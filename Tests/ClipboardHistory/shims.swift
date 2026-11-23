import Foundation
func T(_ key: String) -> String { key }
func TF(_ key: String, _ args: CVarArg...) -> String { String(format: key, arguments: args) }
