import Foundation

enum VeilLookTarget {
    case snap
    case angle
    case privacy

    var accessibilityLabel: String.LocalizationValue {
        switch self {
        case .snap: "Snap to blur look"
        case .angle: "Blur by angle look"
        case .privacy: "Privacy veil look"
        }
    }
}

enum VeilLook: CaseIterable, Equatable, Hashable, Identifiable {
    case frost
    case mist
    case slate
    case smoke
    case charcoal

    var id: Self { self }

    var strength: Double {
        switch self {
        case .frost: 0.35
        case .mist: 0.5
        case .slate: 0.68
        case .smoke: 0.85
        case .charcoal: 1
        }
    }

    var tint: Double {
        switch self {
        case .frost: 0
        case .mist: 0.18
        case .slate: 0.38
        case .smoke: 0.7
        case .charcoal: 1
        }
    }

    var title: String {
        switch self {
        case .frost: L10n.string("Frost")
        case .mist: L10n.string("Mist")
        case .slate: L10n.string("Slate")
        case .smoke: L10n.string("Smoke")
        case .charcoal: L10n.string("Charcoal")
        }
    }

    static func matching(strength: Double, tint: Double, target: VeilLookTarget) -> Self? {
        allCases.first { look in
            abs(look.tint - tint) < 0.000_001
                && (target == .angle || abs(look.strength - strength) < 0.000_001)
        }
    }
}

extension VeilLookTarget: Equatable {}
