import Foundation

/// Something in the scan that may be worth removing, with what removing it means.
public struct Suggestion: Sendable, Identifiable {
    /// What happens after removing it.
    public enum Effect: Sendable {
        /// Built again when needed (build products, indexes).
        case rebuilt
        /// Downloaded again when needed (package caches, installers).
        case redownloaded
        /// Gone for good (archives, backups, simulators with their data).
        case lost
    }

    public let id: String
    public let title: String
    /// Shown next to the title, e.g. the project folder.
    public let subtitle: String?
    public let effect: Effect
    /// What it is and what removing it means.
    public let note: String
    /// The nodes to collect, largest first.
    public let items: [Int32]
    /// Names for items that their path doesn't tell (a simulator's device name).
    public let itemLabels: [Int32: String]
    /// When it was last changed or added, where that matters (projects, downloads).
    public let date: Date?
    public let size: Int64

    public init(id: String, title: String, subtitle: String? = nil, effect: Effect, note: String,
                items: [Int32], itemLabels: [Int32: String] = [:], date: Date? = nil, tree: FileTree) {
        let sorted = items.sorted { tree.nodes[Int($0)].size > tree.nodes[Int($1)].size }
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.effect = effect
        self.note = note
        self.items = sorted
        self.itemLabels = itemLabels
        self.date = date
        size = sorted.reduce(0) { $0 + tree.nodes[Int($1)].size }
    }
}

/// Suggestions under a heading.
public struct SuggestionSection: Sendable, Identifiable {
    public var id: String { title }
    public let title: String
    /// Whether the age filter applies (its suggestions have dates).
    public let byAge: Bool
    public let grouping: Grouping
    public let suggestions: [Suggestion]

    /// Sections showing the same items grouped another way; only one grouping is shown.
    public enum Grouping: Sendable {
        case always, byProject, byKind
    }

    public init(title: String, byAge: Bool = false, grouping: Grouping = .always, suggestions: [Suggestion]) {
        self.title = title
        self.byAge = byAge
        self.grouping = grouping
        self.suggestions = suggestions
    }
}

enum SuggestionDates {
    /// The newest modification of `path` and what's directly inside it, leaving out `except`
    /// (a project's build output changes on every build, which says nothing about the project).
    static func lastChange(of path: String, except: Set<String> = []) -> Date? {
        let files = FileManager.default
        var newest = (try? files.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        for name in ((try? files.contentsOfDirectory(atPath: path)) ?? []).prefix(300)
        where !except.contains(name) && name != ".DS_Store" {
            guard let date = (try? files.attributesOfItem(atPath: path + "/" + name))?[.modificationDate] as? Date
            else { continue }
            if newest.map({ date > $0 }) ?? true { newest = date }
        }
        return newest.map { min($0, Date()) }
    }
}
