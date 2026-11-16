import Foundation

/// pluginkit 的用户选择状态；空结果不等于成功启用。作者：wwj。
enum FinderElection {
    static func parse(_ output: String) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for line in output.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard let marker = text.first, marker == "+" || marker == "-",
                  let identifier = text.dropFirst().split(whereSeparator: { $0 == " " || $0 == "\t" }).first?
                    .split(separator: "(").first else { continue }
            // -A 可能包含历史版本；只要有一个版本被选用，就不能被后续旧记录覆盖。
            let key = String(identifier)
            result[key] = (result[key] ?? false) || marker == "+"
        }
        return result
    }
}
