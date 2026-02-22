import Foundation

public enum DomainSanitizer {
    public static func normalized(_ rawValue: String) -> String? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else {
            return nil
        }

        if value.contains("://"), let host = URL(string: value)?.host(percentEncoded: false) {
            value = host
        }

        if let slashIndex = value.firstIndex(of: "/") {
            value = String(value[..<slashIndex])
        }

        if let atIndex = value.lastIndex(of: "@") {
            value = String(value[value.index(after: atIndex)...])
        }

        if let colonIndex = value.firstIndex(of: ":") {
            value = String(value[..<colonIndex])
        }

        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "."))

        guard !value.isEmpty else {
            return nil
        }

        if value == "localhost" {
            return value
        }

        guard value.contains("."), !value.contains("..") else {
            return nil
        }

        if value.hasPrefix("-") || value.hasSuffix("-") {
            return nil
        }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.")
        let unicodeScalars = value.unicodeScalars
        guard unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return nil
        }

        return value
    }

    public static func normalizeList(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for value in values {
            guard let normalized = normalized(value), !seen.contains(normalized) else {
                continue
            }
            seen.insert(normalized)
            result.append(normalized)
        }

        return result
    }
}
