// One hop: who does Ada know?
let friends = try database.matchJSON(
  """
  MATCH (person:Person)-[:KNOWS]->(friend:Person)
  WHERE person.name = $name
  RETURN friend.name
  """,
  parameters: ["name": .string("Ada Chen")]
)

// Two hops: which events do Ada's friends attend, and where?
let plans = try database.matchJSON(
  """
  MATCH (person:Person)-[:KNOWS]->(friend:Person)-[:ATTENDS]->(event:Event)-[:HAPPENS_AT]->(place:Place)
  WHERE person.name = $name
  RETURN friend.name AS friend, event.name AS event, place.name AS place
  """,
  parameters: ["name": .string("Ada Chen")]
)
print(plans)
// [{"friend":"Ben Ortiz","event":"Design Salon","place":"Harbor Park"}]
