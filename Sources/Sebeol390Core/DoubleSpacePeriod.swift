import Foundation

/// Tracks an eligible first space and recognizes a second tap against the exact
/// host context produced by that first space.
public struct DoubleSpacePeriod: Sendable {
    public static let interval: TimeInterval = 0.4

    private var firstSpaceContext: String?
    private var firstSpaceTime: Date?

    public init() {}

    /// Records the context immediately after the first space was committed.
    public mutating func recordFirstSpace(contextBefore: String?, now: Date = Date()) {
        guard let contextBefore,
              contextBefore.hasSuffix(" "),
              let previous = contextBefore.dropLast().last,
              Self.isWordCharacter(previous) else {
            clear()
            return
        }
        firstSpaceContext = contextBefore
        firstSpaceTime = now
    }

    /// Consumes the pending tap and returns true only for an unchanged context
    /// within the double-tap interval.
    public mutating func shouldConvert(contextBefore: String?, now: Date = Date()) -> Bool {
        defer { clear() }
        guard let firstSpaceContext, let firstSpaceTime,
              contextBefore == firstSpaceContext,
              now >= firstSpaceTime,
              now.timeIntervalSince(firstSpaceTime) <= Self.interval else { return false }
        return true
    }

    public mutating func clear() {
        firstSpaceContext = nil
        firstSpaceTime = nil
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character.unicodeScalars.contains(where: isHangul)
    }

    private static func isHangul(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F,
             0xAC00...0xD7AF, 0xD7B0...0xD7FF:
            return true
        default:
            return false
        }
    }
}
