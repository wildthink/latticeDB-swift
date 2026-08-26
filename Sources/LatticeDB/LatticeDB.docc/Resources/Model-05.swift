import Foundation
import LatticeDB

let database = try Database(path: "neighborhood.db")

let ids = try database.write { transaction in
  let ada = try transaction.createNode(label: "Person")
  try transaction.setProperty("name", onNode: ada, to: .string("Ada Chen"))
  try transaction.setProperty("role", onNode: ada, to: .string("Urban designer"))

  let ben = try transaction.createNode(label: "Person")
  try transaction.setProperty("name", onNode: ben, to: .string("Ben Ortiz"))
  try transaction.setProperty("role", onNode: ben, to: .string("Community gardener"))

  let park = try transaction.createNode(label: "Place")
  try transaction.setProperty("name", onNode: park, to: .string("Harbor Park"))

  let salon = try transaction.createNode(label: "Event")
  try transaction.setProperty("name", onNode: salon, to: .string("Design Salon"))
  try transaction.setProperty("date", onNode: salon, to: .string("2026-09-10"))

  _ = try transaction.createEdge(from: ada, to: ben, type: "KNOWS")
  _ = try transaction.createEdge(from: ben, to: park, type: "CARES_FOR")
  _ = try transaction.createEdge(from: salon, to: park, type: "HAPPENS_AT")

  let rsvp = try transaction.createEdge(from: ben, to: salon, type: "ATTENDS")
  try transaction.setProperty("rsvp", onEdge: rsvp, to: .bool(true))

  return (ada: ada, ben: ben, park: park, salon: salon)
}
