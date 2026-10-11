import Foundation

final class AppLanguage {
    static let shared = AppLanguage()
    static let choices = [("de", "Deutsch"), ("en", "English"), ("fr", "Français"),
                          ("it", "Italiano"), ("pt", "Português"), ("es", "Español")]
    var code: String
    private let tables: [String: [String: String]]

    private init() {
        var loaded: [String: [String: String]] = [:]
        if let root = Bundle.main.resourceURL?.appendingPathComponent("i18n") {
            for (language, _) in Self.choices {
                if let data = try? Data(contentsOf: root.appendingPathComponent(language + ".json")),
                   let table = try? JSONDecoder().decode([String: String].self, from: data) {
                    loaded[language] = table
                }
            }
        }
        tables = loaded
        // The primary macOS language wins on every launch, including upgrades
        // from versions that persisted a manual InterfaceLanguage override.
        let primary = Locale.preferredLanguages.first ?? "en"
        let language = String(primary.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "").lowercased()
        code = Self.choices.contains(where: { $0.0 == language }) && loaded[language] != nil ? language : "en"
    }
    func select(_ language: String) {
        guard Self.choices.contains(where: { $0.0 == language }) else { return }
        code = language
    }
    func text(_ source: String, fields: [String: String] = [:]) -> String {
        var result = tables[code]?[source] ?? tables["en"]?[source] ?? source
        for (key, value) in fields { result = result.replacingOccurrences(of: "{" + key + "}", with: value) }
        return result
    }
    func validationErrors() -> [String] {
        guard let master = tables["de"], !master.isEmpty else { return ["Missing German source catalog"] }
        var errors: [String] = []
        let expression = try! NSRegularExpression(pattern: "\\{[a-z]+\\}")
        func placeholders(_ value: String) -> [String] {
            expression.matches(in: value, range: NSRange(value.startIndex..., in: value))
                .map { (value as NSString).substring(with: $0.range) }.sorted()
        }
        for (language, _) in Self.choices {
            guard let table = tables[language] else { errors.append("Missing language: " + language); continue }
            if Set(table.keys) != Set(master.keys) { errors.append("Key mismatch: " + language) }
            for (key, value) in table {
                if value.isEmpty || placeholders(key) != placeholders(value) { errors.append("Invalid translation: " + language + " / " + key) }
            }
        }
        return errors
    }
}

func tr(_ source: String, _ fields: [String: String] = [:]) -> String {
    AppLanguage.shared.text(source, fields: fields)
}
