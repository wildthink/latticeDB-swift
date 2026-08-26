struct Plan: Decodable {
  let friend: String
  let event: String
  let place: String
}

let plans = try database.matchJSON(
  """
  MATCH (person:Person)-[:KNOWS]->(friend:Person)-[:ATTENDS]->(event:Event)-[:HAPPENS_AT]->(place:Place)
  WHERE person.name = $name
  RETURN friend.name AS friend, event.name AS event, place.name AS place
  """,
  parameters: ["name": .string("Ada Chen")]
)

let rows = try JSONDecoder().decode([Plan].self, from: Data(plans.utf8))
for row in rows {
  print("\(row.friend) is at \(row.event), \(row.place)")
}
