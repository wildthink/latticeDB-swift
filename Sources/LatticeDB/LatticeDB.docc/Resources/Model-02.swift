import Foundation
import LatticeDB

let database = try Database(path: "neighborhood.db")

let people = try database.write { transaction in
  let ada = try transaction.createNode(label: "Person")
  let ben = try transaction.createNode(label: "Person")
  return (ada: ada, ben: ben)
}
