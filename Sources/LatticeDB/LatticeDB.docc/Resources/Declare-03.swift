// A plan is a value: building it touches no database.
let plan = GraphPlan {
  let ada = Node(.person) {
    Person.name .= "Ada Chen"
    Person.age .= 37
  }
  let cafe = Node(.place) {
    Place.name .= "River Cafe"
  }
  Edge(.frequents, from: ada, to: cafe) {
    Property("since", .integer(2019))
  }
}

// Nothing has been written yet.
print(plan.edgeSpecs.count)  // 1
