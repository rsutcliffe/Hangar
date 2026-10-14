import SwiftUI

/// Colour tokens live in the asset catalog (light/dark variants); see README design tokens.
enum Theme {
    static let text = Color("Text")
    static let muted = Color("Muted")
    static let line = Color("Line")          // track and hairline
    static let cardFill = Color("CardFill")
    static let pill = Color("Pill")
    static let pillHover = Color("PillHover")
    static let running = Color("Running")
    static let problem = Color("Problem")
    static let problemText = Color("ProblemText")
    static let onProblem = Color("OnProblem")

    static let windowRadius: CGFloat = 26
    static let cardRadius: CGFloat = 18
}
