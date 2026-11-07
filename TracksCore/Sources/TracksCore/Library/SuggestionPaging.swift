import Foundation

/// How a list of suggestions that goes on as it's scrolled asks for more: a page at a time,
/// however many of what's found are left out on the way, and never for ever.
public enum SuggestionPaging {
    /// How many more a shelf laid out in columns wants: enough to finish its last column, or a
    /// whole new one when it's finished already.
    public static func wanted(showing count: Int, perColumn: Int) -> Int {
        precondition(perColumn > 0, "A column holds at least one song")
        return perColumn - max(0, count) % perColumn
    }

    /// Steps until `count` has grown by `want`, a step says there's nothing left to try, or
    /// `maxSteps` steps have gone by: a step whose songs are all left out, as songs your
    /// servers don't have are, asks again rather than leave the page short.
    /// - Parameters:
    ///   - count: how many there are to show now.
    ///   - step: looks for more, returning false when there's nowhere left to look.
    /// - Returns: how many more there are to show.
    @discardableResult
    public static func fill(
        want: Int,
        maxSteps: Int,
        isolation: isolated (any Actor)? = #isolation,
        count: () -> Int,
        step: () async -> Bool
    ) async -> Int {
        let start = count()
        var steps = 0
        while count() - start < want, steps < maxSteps, !Task.isCancelled {
            steps += 1
            guard await step() else { break }
        }
        return max(0, count() - start)
    }

    /// The items `keep` says yes to, in their order, asking about up to `limit` at once: one
    /// slow answer doesn't hold up the rest.
    public static func kept<Item: Sendable>(
        _ items: [Item],
        limit: Int = 6,
        where keep: @escaping @Sendable (Item) async -> Bool
    ) async -> [Item] {
        precondition(limit > 0, "Asking about none at a time would never finish")
        guard !items.isEmpty else { return [] }
        var answers = [Bool](repeating: false, count: items.count)
        await withTaskGroup(of: (Int, Bool).self) { group in
            var next = 0
            func start() {
                guard next < items.count else { return }
                let (index, item) = (next, items[next])
                next += 1
                group.addTask { (index, await keep(item)) }
            }
            for _ in 0..<min(limit, items.count) { start() }
            while let (index, answer) = await group.next() {
                answers[index] = answer
                start()
            }
        }
        return zip(items, answers).compactMap { $1 ? $0 : nil }
    }

    /// The items not already among `known`, each once, in order.
    public static func new<Item, Key: Hashable>(_ items: [Item], known: some Sequence<Key>, by key: (Item) -> Key) -> [Item] {
        var seen = Set(known)
        return items.filter { seen.insert(key($0)).inserted }
    }
}
