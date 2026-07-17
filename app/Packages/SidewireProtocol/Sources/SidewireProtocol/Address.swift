import Foundation

/// Parsing for addresses a human types by hand (the "connect by address" fallback, used when
/// discovery can't see the other Mac — most often over a Thunderbolt cable).
public enum Address {
    /// Parse `host` or `host:port` into its parts, or nil when the text cannot be an address.
    ///
    /// Returning nil rather than guessing is the point. This used to fall through and hand the
    /// raw string to the network stack verbatim — colon, spaces and all — where it failed as an
    /// ordinary *transient* resolve error and was therefore retried forever by the Reconnector.
    /// One stray space bought a two-minute hang that ended by blaming the other Mac. A caller that
    /// gets nil has been told, cheaply and immediately, that there is nothing here worth dialling.
    ///
    /// - Parameter defaultPort: used when the text carries no port of its own.
    public static func parse(_ raw: String,
                             defaultPort: UInt16 = ProtocolConstants.fallbackPort) -> (host: String, port: UInt16)? {
        // whitespacesAndNewlines, not whitespaces: the latter is spaces and tabs only, so a value
        // pasted with a trailing newline survived trimming and was dialled with the newline still
        // attached.
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Bracketed IPv6, with or without a port: "[fe80::1]" or "[fe80::1]:5006". The brackets
        // are syntax, not part of the address — passing them through got the entire string, port
        // and all, handed to the resolver as a DNS name.
        if trimmed.hasPrefix("[") {
            guard let close = trimmed.firstIndex(of: "]") else { return nil }
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            guard !host.isEmpty, !host.contains(where: \.isWhitespace) else { return nil }
            let rest = trimmed[trimmed.index(after: close)...]
            if rest.isEmpty { return (host, defaultPort) }
            guard rest.hasPrefix(":"),
                  let port = UInt16(rest.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)),
                  port > 0 else { return nil }
            return (host, port)
        }

        // Exactly one ":" unambiguously means host:port for IPv4 and hostnames. Zero colons is a
        // bare address; several means an unbracketed IPv6 literal, which takes the default port —
        // there is no way to tell a port from another group without brackets.
        guard trimmed.filter({ $0 == ":" }).count == 1, let separator = trimmed.firstIndex(of: ":") else {
            guard !trimmed.contains(where: \.isWhitespace) else { return nil } // a name, not an address
            return (trimmed, defaultPort)
        }

        // Trim the two halves SEPARATELY. "169.254.3.4 : 5006" is a natural thing to type, and
        // trimming only the whole string left UInt16(" 5006") == nil — which is exactly how a
        // typo became an unparseable host that got dialled anyway.
        let host = trimmed[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
        let portText = trimmed[trimmed.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !host.contains(where: \.isWhitespace),
              let port = UInt16(portText), port > 0 else { return nil }
        return (host, port)
    }
}
