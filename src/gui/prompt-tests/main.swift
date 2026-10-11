import Foundation

var count = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    count += 1
    guard condition() else { fatalError("Failed: " + name) }
}
func data(_ text: String) -> Data { Data(text.utf8) }
var state = InputPromptState()
state.append(data("==> Do you want to proceed with the upgrade? [y/n]\r\n"))
check(state.kind == .yesNo, "actual Homebrew prompt with terminal newline")
check(state.consume(.yesNo), "explicit yes/no consumes once")
check(!state.consume(.yesNo), "double click cannot send duplicate")
state.append(data("\r\n"))
check(state.kind == .none, "blank terminal update does not revive answered prompt")
state.append(data("==> Do you want to proceed with the upgrade? [y/n]\n"))
check(state.kind == .yesNo, "genuine repeated prompt on later line")
state.append(data("ordinary progress output\n"))
check(state.kind == .none, "later ordinary output invalidates question")
for suffix in ["[y/N]", "[Y/n]", "[y/n]"] {
    state.reset()
    for byte in data("\u{001b}[32mContinue? " + suffix + "\u{001b}[0m") { state.append(Data([byte])) }
    check(state.kind == .yesNo, "chunked ANSI prompt " + suffix)
}
state.reset()
state.append(data("PRESS RETURN/ENTER to continue or any other key to abort:"))
check(state.kind == .returnKey, "Homebrew installation Return request")
check(!state.consume(.yesNo), "wrong input kind cannot consume Return")
check(state.consume(.returnKey), "Return is single use")
state.append(data("\nLoading Homebrew\n"))
check(state.kind == .none, "no Return after subsequent output")
state.reset()
state.append(data("press enter then choose? [Y/n]"))
check(state.kind == .yesNo, "explicit yes/no has precedence")
state.append(data("\n@@CLAMAV:STAGE:configuration\n"))
check(state.kind == .none, "internal stage clears stale prompt")
for text in ["Do you want to proceed?", "Information about [y/n] in the manual", "y/n", "Password:", "READY"] {
    state.reset(); state.append(data(text))
    check(state.kind == .none, "ordinary output is not a yes/no prompt: " + text)
}
state.reset()
check(state.kind == .none, "cancellation/reset clears prompt")
print("\(count) prompt-state checks passed")
