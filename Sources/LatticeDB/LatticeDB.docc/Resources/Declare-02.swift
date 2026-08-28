extension NodeType {
  static let person: NodeType = "Person"
  static let place: NodeType = "Place"
}

extension EdgeType {
  static let frequents: EdgeType = "FREQUENTS"
}

// An entity ties a label to typed property keys. Any module can add more keys.
enum Person: GraphNode {
  static let nodeType: NodeType = .person

  static let name = PropertyKey<Person, String>("name")
  static let age = PropertyKey<Person, Int>("age")
}

enum Place: GraphNode {
  static let nodeType: NodeType = .place

  static let name = PropertyKey<Place, String>("name")
}
