import Foundation

/// A syntactically validated international number. This does not establish who owns it.
public struct PhoneNumber: Hashable, Sendable, CustomStringConvertible {
    public enum ValidationError: Error, Equatable, LocalizedError, Sendable {
        case empty
        case mustUseInternationalFormat
        case invalidCharacters
        case invalidLength
        case invalidCountryCode

        public var errorDescription: String? {
            switch self {
            case .empty:
                return "Enter an international phone number, including + and the country code."
            case .mustUseInternationalFormat:
                return "Use a leading + and country code, for example +1 312 555 0123."
            case .invalidCharacters:
                return "Only digits, spaces, parentheses, hyphens and dots are allowed after +. Extensions and dial codes are not supported."
            case .invalidLength:
                return "Use an international number with 8 to 15 digits."
            case .invalidCountryCode:
                return "The first digit after + cannot be zero."
            }
        }
    }

    /// The validated number, containing only + followed by 8–15 ASCII digits.
    public let normalized: String

    /// A display value revealing only the final four digits.
    public var masked: String {
        let digits = normalized.dropFirst()
        return "+" + String(repeating: "•", count: digits.count - 4) + digits.suffix(4)
    }

    /// Logging a number defaults to the masked form.
    public var description: String { masked }

    public init(_ rawValue: String) throws {
        let trimmed = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: " "))
        guard !trimmed.isEmpty else { throw ValidationError.empty }

        // Deliberately exclude Unicode digits, newlines, URI syntax, extensions,
        // pause/wait characters, and * / # dial codes before normalization.
        let separators: Set<Unicode.Scalar> = [" ", "(", ")", "-", "."]
        guard trimmed.unicodeScalars.allSatisfy({ scalar in
            (48...57).contains(scalar.value) || scalar == "+" || separators.contains(scalar)
        }) else { throw ValidationError.invalidCharacters }

        guard trimmed.first == "+" else { throw ValidationError.mustUseInternationalFormat }
        let normalized = String(String.UnicodeScalarView(trimmed.unicodeScalars.filter {
            !separators.contains($0)
        }))
        let digits = normalized.dropFirst()
        guard digits.utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw ValidationError.invalidCharacters
        }
        guard (8...15).contains(digits.count) else { throw ValidationError.invalidLength }
        guard digits.first != "0" else { throw ValidationError.invalidCountryCode }
        self.normalized = normalized
    }
}
