-- People and their roles
MATCH (person:Person) RETURN person.name, person.role

-- Events and where they happen
MATCH (event:Event)-[:HAPPENS_AT]->(place:Place) RETURN event.name, event.date, place.name

-- Connections around Ada
MATCH (ada:Person)-[relationship]->(other) WHERE ada.name = 'Ada Chen' RETURN relationship, other
