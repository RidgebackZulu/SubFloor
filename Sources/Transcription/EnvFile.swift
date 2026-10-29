import Foundation

/// Reads the OpenRouter key from the contents of a `.env` file.
public enum EnvFile {
    /// The first non-empty value of an `OPENROUTER=` or `OPENROUTER_API_KEY=` line. Accepts an
    /// `export ` prefix, single or double quotes around the value, and spaces around the name and
    /// value. Lines starting with `#` are skipped. Returns nil when no line has a value.
    public static func openRouterKey(in contents: String) -> String? {
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export "), let space = line.firstIndex(of: " ") {
                line = line[space...].trimmingCharacters(in: .whitespaces)
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let name = line[..<equals].trimmingCharacters(in: .whitespaces)
            guard name == "OPENROUTER" || name == "OPENROUTER_API_KEY" else { continue }
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            }
            if !value.isEmpty { return value }
        }
        return nil
    }
}
