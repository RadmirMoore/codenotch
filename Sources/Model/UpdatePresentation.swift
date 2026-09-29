import Foundation
struct UpdatePrompt: Equatable {
    enum Phase: Equatable {
        case available
        /// Downloading, with how much of it has come, once its size is known.
        case downloading(Double?)
        case extracting(Double)
        case installing
    }

    var version: String
    var notes: String
    var phase: Phase

    /// A line of release notes from the appcast's HTML: the tags and entities
    /// out, the whitespace run together.
    static func summary(of html: String) -> String {
        var text = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (entity, character) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
                                    ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " ")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// What the notch said to the update it offered.
enum UpdateChoice: Equatable {
    case install, later, close
}
