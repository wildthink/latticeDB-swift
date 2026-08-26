let schema = GraphSchema(
  nodes: [
    NodeSchema(
      label: "Person",
      properties: [
        "name": PropertyRule(kind: .string, required: true),
        "role": PropertyRule(kind: .string),
      ],
      allowsAdditionalProperties: false
    )
  ],
  edges: [
    EdgeSchema(
      type: "ATTENDS",
      properties: ["rsvp": PropertyRule(kind: .bool, required: true)]
    )
  ]
)

let chandra = try database.write { transaction in
  try schema.createNode(
    in: transaction,
    label: "Person",
    properties: ["name": .string("Chandra Rao"), "role": .string("Historian")]
  )
}
