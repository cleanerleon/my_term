import Foundation

public enum PaneAxis: String, Codable { case columns, rows }

/// A terminal belongs to one leaf at a time. Removing a leaf collapses its divider.
public indirect enum TerminalLayout: Equatable {
    case terminal(UUID)
    case split(PaneAxis, TerminalLayout, TerminalLayout)

    public var terminals: [UUID] {
        switch self {
        case .terminal(let id): return [id]
        case .split(_, let first, let second): return first.terminals + second.terminals
        }
    }
    public func splitting(_ target: UUID, with new: UUID, axis: PaneAxis) -> TerminalLayout {
        guard !terminals.contains(new) else { return self }
        switch self {
        case .terminal(let id): return id == target ? .split(axis, self, .terminal(new)) : self
        case .split(let direction, let first, let second):
            return .split(direction, first.splitting(target, with: new, axis: axis), second.splitting(target, with: new, axis: axis))
        }
    }
    public func replacing(_ target: UUID, with new: UUID) -> TerminalLayout {
        guard !terminals.contains(new) else { return self }
        switch self {
        case .terminal(let id): return .terminal(id == target ? new : id)
        case .split(let axis, let first, let second): return .split(axis, first.replacing(target, with: new), second.replacing(target, with: new))
        }
    }
    public func removing(_ target: UUID) -> TerminalLayout? {
        switch self {
        case .terminal(let id): return id == target ? nil : self
        case .split(let axis, let first, let second):
            let a = first.removing(target), b = second.removing(target)
            if let a, let b { return .split(axis, a, b) }
            return a ?? b
        }
    }
}

public struct SavedCommand: Identifiable, Codable, Equatable {
    public var id: UUID
    public var name: String
    public var text: String
    public init(id: UUID = UUID(), name: String, text: String) { self.id = id; self.name = name; self.text = text }
}
