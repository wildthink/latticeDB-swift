import Foundation
import LatticeDB

/// A short block of text that retrieval always includes within its scope.
///
/// Everything else in the store earns its way into a result by ranking. A pinned
/// note does not: it is there because someone decided it should always be there.
/// A standing instruction, a piece of nameplate data, a caveat that must
/// accompany every report — the things a ranking function has no business
/// deciding about.
///
/// Notes are authored, not derived. They cite no evidence, which means
/// ``MemoryStore/forget(_:)`` does not touch them; a note repeating something
/// that was forgotten has to be edited or unpinned by hand.
public struct PinnedNote: Sendable, Equatable, Identifiable {
  /// The stable identifier assigned when this was first pinned.
  public let id: RecordID

  /// A short name, unique within its scope.
  ///
  /// Pinning the same title in the same scope replaces the note's text rather
  /// than adding a second one, which is what makes a note editable in place.
  public var title: String

  /// The content.
  public var text: String

  /// The context this note belongs to.
  public var scope: Scope

  /// When it was last written.
  public var updatedAt: Date

  public init(id: RecordID, title: String, text: String, scope: Scope, updatedAt: Date) {
    self.id = id
    self.title = title
    self.text = text
    self.scope = scope
    self.updatedAt = updatedAt
  }
}

extension MemoryStore {
  /// Pins a note, replacing any note with the same title in the same scope.
  ///
  /// - Parameters:
  ///   - text: The content.
  ///   - title: A short name, unique within `scope`.
  ///   - scope: The context the note belongs to.
  @discardableResult
  public func pin(_ text: String, title: String, scope: Scope = .global) throws -> PinnedNote {
    let now = clock()
    return try database.write { transaction in
      // Re-pinning keeps the note's identity, so a reference to it survives an
      // edit.
      let existing = try noteNode(title: title, scope: scope, in: transaction)
      let id =
        try existing.map { try readNote($0, in: transaction).id }
        ?? RecordID.generate(prefix: "pn", now: now)
      let note = PinnedNote(id: id, title: title, text: text, scope: scope, updatedAt: now)
      let node = try existing ?? transaction.createNode(label: Labels.note)
      try transaction.setProperty(Keys.id, onNode: node, to: .string(note.id.rawValue))
      try transaction.setProperty(Keys.title, onNode: node, to: .string(title))
      try transaction.setProperty(Keys.text, onNode: node, to: .string(text))
      try transaction.setProperty(Keys.scope, onNode: node, to: .string(scope.storageKey))
      try transaction.setProperty(Keys.updatedAt, onNode: node, to: now.latticeValue)
      if let embedder {
        try transaction.setVector(
          try embedder.embed(text), forKey: Keys.embedding, onNode: node)
      }
      return note
    }
  }

  /// Removes a pinned note.
  ///
  /// Notes are deleted outright rather than tombstoned. A note is authored
  /// rather than evidence, so nothing cites it and nothing needs to know it
  /// existed.
  ///
  /// - Throws: ``MemoryError/unknownRecord(_:)`` when no such note is pinned.
  public func unpin(_ id: RecordID) throws {
    try database.write { transaction in
      guard let node = try locate(id, label: Labels.note, in: transaction) else {
        throw MemoryError.unknownRecord(id)
      }
      try transaction.deleteNode(node)
    }
  }

  /// Returns the notes visible in `scope`, by title.
  ///
  /// Visibility follows ``Scope/isVisible(in:)``, as everywhere else: a note
  /// scoped more narrowly than the query stays hidden.
  public func notes(in scope: Scope) throws -> [PinnedNote] {
    try database.read { transaction in
      try transaction.nodeIDs(label: Labels.note)
        .map { try readNote($0, in: transaction) }
        .filter { $0.scope.isVisible(in: scope) }
        .sorted { $0.title < $1.title }
    }
  }

  /// Returns the note with `title` in exactly `scope`, or `nil`.
  public func note(title: String, scope: Scope = .global) throws -> PinnedNote? {
    try database.read { transaction in
      guard let node = try noteNode(title: title, scope: scope, in: transaction) else {
        return nil
      }
      return try readNote(node, in: transaction)
    }
  }

  /// Finds the node holding `title` in exactly `scope`.
  ///
  /// Exact scope, not visibility: pinning a note in a broad context must create
  /// its own note rather than overwrite a narrower one that happens to be
  /// visible from there.
  private func noteNode(
    title: String, scope: Scope, in transaction: Transaction
  ) throws -> NodeID? {
    let key = scope.storageKey
    for node in try transaction.nodeIDs(
      label: Labels.note, property: Keys.title, equals: .string(title))
    where try transaction.propertyValue(Keys.scope, ofNode: node) == .string(key) {
      return node
    }
    return nil
  }

  func readNote(_ node: NodeID, in transaction: Transaction) throws -> PinnedNote {
    func string(_ key: String) throws -> String {
      guard case .string(let value) = try transaction.propertyValue(key, ofNode: node) else {
        return ""
      }
      return value
    }
    let id = RecordID(try string(Keys.id))
    guard case .integer(let milliseconds) = try transaction.propertyValue(
      Keys.updatedAt, ofNode: node)
    else {
      throw MemoryError.malformedRecord(id, "updatedAt is missing or is not a timestamp")
    }
    return PinnedNote(
      id: id,
      title: try string(Keys.title),
      text: try string(Keys.text),
      scope: Scope(storageKey: try string(Keys.scope)),
      updatedAt: Date(timeIntervalSince1970: Double(milliseconds) / 1_000))
  }
}
