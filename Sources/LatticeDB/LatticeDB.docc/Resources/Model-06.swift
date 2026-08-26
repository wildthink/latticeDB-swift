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
