import Foundation

/// After landing: how the flight felt compared with the forecast. Calibration data.
enum FeltRating: String, Codable, CaseIterable, Sendable {
    case smoother
    case aboutRight = "about_right"
    case bumpier

    var title: String {
        switch self {
        case .smoother: "Smoother"
        case .aboutRight: "About right"
        case .bumpier: "Bumpier"
        }
    }
}
