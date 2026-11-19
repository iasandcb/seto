import Foundation

/// Korean layout is independent of the current Korean/English language.
public enum KeyboardLayout: String, CaseIterable, Sendable {
    case sebeol390
    case dubeol
    case sebeolFinal

    public var title: String {
        switch self {
        case .sebeol390: return "세벌식 390"
        case .dubeol: return "두벌식"
        case .sebeolFinal: return "세벌식 최종"
        }
    }

    public func atom(for key: Character) -> KeyAtom {
        switch self {
        case .sebeol390: return Layout390.atom(for: key)
        case .dubeol: return LayoutDubeol.atom(for: key)
        case .sebeolFinal: return LayoutFinal.atom(for: key)
        }
    }
}
