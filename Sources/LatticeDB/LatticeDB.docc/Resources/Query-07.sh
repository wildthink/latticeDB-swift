# The same graph, from a terminal — no rebuild needed.
swift run lattice match --database neighborhood.db --format table \
  --param name="Ada Chen" \
  'MATCH (person:Person)-[:KNOWS]->(friend:Person)
   WHERE person.name = $name
   RETURN friend.name, friend.role'

# | friend.name | friend.role         |
# |-------------|---------------------|
# | Ben Ortiz   | Community gardener  |

# Or explore interactively, opening the database once.
swift run lattice repl
# lattice > database open neighborhood.db
# lattice > node types
# lattice > node show 1
