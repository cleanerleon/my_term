import Foundation
import WindCore

func checkTerminalLayout() throws {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID()
    let layout = TerminalLayout.terminal(a).splitting(a, with: b, axis: .columns).splitting(b, with: c, axis: .rows)
    try expectEqual(layout.terminals, [a, b, c])
    try expectEqual(layout.splitting(a, with: b, axis: .rows), layout, "A PTY must not appear in two panes")
    try expectEqual(layout.replacing(a, with: c), layout, "Selecting a visible PTY must not duplicate its NSView")
    let replaced = layout.replacing(a, with: d)
    try expectEqual(replaced.terminals, [d, b, c])
    try expectEqual(layout.removing(b), .split(.columns, .terminal(a), .terminal(c)))
    try expectEqual(layout.removing(a)?.removing(b), .terminal(c))
    try expectTrue(layout.removing(a)?.removing(b)?.removing(c) == nil)
    try expectEqual(layout.removing(UUID()), layout)
}
