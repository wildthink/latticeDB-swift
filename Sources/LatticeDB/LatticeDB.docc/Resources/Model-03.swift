import Foundation
import LatticeDB

let database = try Database(path: "neighborhood.db")

let people = try database.write { transaction in
  let ada = try transaction.createNode(label: "Person")
  try transaction.setProperty("name", onNode: ada, to: .string("Ada Chen"))
  try transaction.setProperty("role", onNode: ada, to: .string("Urban designer"))

  let ben = try transaction.createNode(label: "Person")
  try transaction.setProperty("name", onNode: ben, to: .string("Ben Ortiz"))
  try transaction.setProperty("role", onNode: ben, to: .string("Community gardener"))

  return (ada: ada, ben: ben)
}
