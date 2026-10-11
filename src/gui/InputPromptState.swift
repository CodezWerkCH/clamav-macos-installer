import Foundation

/// Tracks the latest real child-output line, independently of GUI messages.
/// A consumed prompt cannot become active again because a timer, an ECHO
/// update, or a blank output line revisits the old console text.
struct InputPromptState {
    enum Kind { case none, returnKey, yesNo }
    private(set) var kind: Kind = .none
    private var line = Data()
    private var lineNumber: UInt64 = 0
    private var latestLine: (number: UInt64, text: String)?
    private var consumedLine: UInt64?

    mutating func append(_ data: Data) {
        for byte in data {
            if byte == 10 || byte == 13 {
                inspectLine()
                line.removeAll(keepingCapacity: true)
                lineNumber &+= 1
            } else {
                line.append(byte)
                if line.count > 16_384 { line.removeFirst(line.count - 8192) }
            }
        }
        inspectLine()
        guard let latest = latestLine, latest.number != consumedLine else {
            kind = .none
            return
        }
        let value = latest.text
        if value.range(of: #"\[\s*[yY]\s*/\s*[nN]\s*\]\s*[:?]?\s*$"#,
                       options: .regularExpression) != nil {
            kind = .yesNo
        } else if value.range(of: #"\bpress\s+(return|enter)\b"#,
                              options: [.regularExpression, .caseInsensitive]) != nil {
            kind = .returnKey
        } else {
            kind = .none
        }
    }

    private mutating func inspectLine() {
        let value = String(decoding: line, as: UTF8.self)
            .replacingOccurrences(of: "\u{001B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { latestLine = (lineNumber, value) }
    }

    @discardableResult
    mutating func consume(_ expected: Kind) -> Bool {
        guard kind == expected, kind != .none else { return false }
        consumedLine = latestLine?.number
        kind = .none
        return true
    }

    mutating func reset() { self = InputPromptState() }
}
