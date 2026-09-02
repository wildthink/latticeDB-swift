import Foundation

/// A ceiling on how much retrieval may return, and how the cost is measured.
///
/// Retrieval fills the budget in rank order and stops. What "cost" means is
/// yours to define: characters for something that will be pasted into a
/// document, items for a fixed-size list, or a measure of your own for anything
/// else — a token count, a byte count, a display height.
public struct Budget: Sendable {
  /// The ceiling, or `nil` for no ceiling.
  public let limit: Int?

  /// What one item costs against the limit.
  public let measure: @Sendable (String) -> Int

  /// Creates a budget from a limit and a cost measure.
  public init(limit: Int?, measure: @escaping @Sendable (String) -> Int) {
    self.limit = limit
    self.measure = measure
  }

  /// No ceiling. Every candidate that survives filtering is returned.
  public static let unlimited = Budget(limit: nil) { $0.count }

  /// At most `count` characters of rendered text.
  public static func characters(_ count: Int) -> Budget {
    Budget(limit: count) { $0.count }
  }

  /// At most `count` items, whatever their size.
  public static func items(_ count: Int) -> Budget {
    Budget(limit: count) { _ in 1 }
  }

  /// At most `count` of whatever `measure` counts.
  ///
  /// Use this for a unit the library cannot know — a tokenizer's count, a
  /// rendered width, a per-item weight.
  public static func custom(_ count: Int, measure: @escaping @Sendable (String) -> Int) -> Budget {
    Budget(limit: count, measure: measure)
  }
}
