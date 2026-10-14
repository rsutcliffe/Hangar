import SwiftUI

/// Colour tokens live in the asset catalog (light/dark variants); see README design tokens.
enum Theme {
    static let text = Color("Text")
    static let muted = Color("Muted")
    static let line = Color("Line")          // track and hairline
    static let cardFill = Color("CardFill")
    static let glassFill = Color("GlassFill")   // body tint under the window glass
    static let pill = Color("Pill")
    static let pillHover = Color("PillHover")
    static let running = Color("Running")
    static let problem = Color("Problem")
    static let problemText = Color("ProblemText")
    static let onProblem = Color("OnProblem")

    /// Follows the system window corner (concentric with the window); 26pt only if the system gives none.
    static let windowShape = ConcentricRectangle(corners: .concentric(minimum: .fixed(windowRadius)), isUniform: true)
    static let windowRadius: CGFloat = 26
    static let cardRadius: CGFloat = 18
}
