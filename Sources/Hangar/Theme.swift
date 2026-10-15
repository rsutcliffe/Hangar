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
    /// The user's system accent colour (System Settings ▸ Appearance ▸ Theme), not a fixed blue.
    static let running = Color.accentColor
    static let problem = Color("Problem")
    static let problemText = Color("ProblemText")
    static let onProblem = Color("OnProblem")

    /// The window's own corner is drawn by the system, so the glass is a plain rectangle that the system clips.
    /// (A fixed or ConcentricRectangle radius did not follow it: measured 26pt against ~17pt on standard windows.)
    static let windowShape = Rectangle()
    /// Inside the ~17pt window corner with 14pt padding; the handover's 18pt would be rounder than the window itself.
    static let cardRadius: CGFloat = 12
}
