import Foundation
import SidewireCore

/// Human-readable text for the wire/internal close reasons that Session emits (backlog C2).
/// Kept in ONE place so both `SourceController` and `DisplayController` map identically and the
/// copy lives once — a prerequisite for F1 localization. Every sentence goes through
/// `String(localized:)` so Xcode's String Catalog extraction picks it up (F1); the raw `reason`
/// still goes to the logs untranslated, only these user-facing strings pass through here.
///
/// Wire reasons: "auth" (wrong PIN), "superseded" (displaced by a newer Source), "role"
/// (both Macs picked the same role), "protocol"/"badMagic" (version/codec mismatch or a foreign
/// client), "timeout", "user" (the peer disconnected). Anything else (internal reconnect
/// reasons like "capture-stall") falls through to a generic, non-cryptic sentence — the raw
/// `reason` there is a diagnostic token deliberately left untranslated inside the parentheses.
enum CloseReasonText {
    private static var updateBoth: String {
        String(localized: "The Macs couldn't agree on a video format — update Sidewire on both Macs.")
    }

    /// Phrasing for the Source (the Mac sharing its screen).
    static func source(_ reason: String) -> String {
        switch reason {
        case "user":
            return String(localized: "The other Mac disconnected.")
        case SessionConstants.authFailureReason:
            return String(localized: "PIN incorrect — check the code shown on the other Mac.")
        case SessionConstants.supersededReason:
            return String(localized: "Another Mac took over this display.")
        case "role":
            return String(localized: "The other Mac is also set to Share — switch one of them to 'Use as a display'.")
        case "protocol", "badMagic":
            return updateBoth
        case "timeout":
            return String(localized: "Connection timed out.")
        default:
            return String(localized: "Connection closed (\(reason)).")
        }
    }

    /// Phrasing for the Display (the Mac acting as the extra screen).
    static func display(_ reason: String) -> String {
        switch reason {
        case SessionConstants.supersededReason:
            return String(localized: "Another Source took over.")
        case "user":
            return String(localized: "The other Mac disconnected.")
        case "role":
            return String(localized: "The other Mac is also set to 'Use as a display' — switch one of them to Share.")
        case "protocol", "badMagic":
            return updateBoth
        case "timeout":
            return String(localized: "Connection timed out.")
        default:
            return String(localized: "Connection closed (\(reason)).")
        }
    }
}
