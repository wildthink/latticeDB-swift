import LatticeBridge
import Foundation

public typealias NodeID = UInt64
public typealias EdgeID = UInt64
public enum Value: Sendable, Equatable { case null, bool(Bool), integer(Int64), double(Double), string(String) }
public struct DatabaseConfiguration: Sendable { public var createIfMissing = true; public var readOnly = false; public init(createIfMissing: Bool = true, readOnly: Bool = false) { self.createIfMissing = createIfMissing; self.readOnly = readOnly } }
public enum LatticeError: Error, Sendable, Equatable { case native(Int32), transactionClosed }

public final class Database {
    private var handle: OpaquePointer?
    public init(path: String, configuration: DatabaseConfiguration = .init()) throws { var result: OpaquePointer?; let code = path.withCString { lattice_bridge_open($0, configuration.createIfMissing, configuration.readOnly, &result) }; try check(code); handle = result }
    deinit { if let handle { _ = lattice_bridge_close(handle) } }
    public func read<T>(_ body: (Transaction) throws -> T) throws -> T { try transact(false, body) }
    public func write<T>(_ body: (Transaction) throws -> T) throws -> T { try transact(true, body) }
    private func transact<T>(_ writable: Bool, _ body: (Transaction) throws -> T) throws -> T { guard let handle else { throw LatticeError.transactionClosed }; var native: OpaquePointer?; try check(lattice_bridge_begin(handle, writable, &native)); let transaction = Transaction(native!); do { let value = try body(transaction); try transaction.commit(); return value } catch { transaction.rollback(); throw error } }
}

public final class Transaction {
    private var handle: OpaquePointer?
    fileprivate init(_ handle: OpaquePointer) { self.handle = handle }
    deinit { rollback() }
    public func createNode(label: String? = nil) throws -> NodeID { try withHandle { handle in var id: UInt64 = 0; let code = label.map { $0.withCString { lattice_bridge_node_create(handle, $0, &id) } } ?? lattice_bridge_node_create(handle, nil, &id); try check(code); return id } }
    public func createEdge(from source: NodeID, to target: NodeID, type: String) throws -> EdgeID { try withHandle { handle in var id: UInt64 = 0; let code = type.withCString { lattice_bridge_edge_create(handle, source, target, $0, &id) }; try check(code); return id } }
    public func nodeExists(_ node: NodeID) throws -> Bool { try withHandle { handle in var exists = false; try check(lattice_bridge_node_exists(handle, node, &exists)); return exists } }
    public func deleteNode(_ node: NodeID) throws { try withHandle { try check(lattice_bridge_node_delete($0, node)) } }
    public func addLabel(_ label: String, to node: NodeID) throws { try withHandle { handle in try label.withCString { try check(lattice_bridge_node_add_label(handle, node, $0)) } } }
    public func removeLabel(_ label: String, from node: NodeID) throws { try withHandle { handle in try label.withCString { try check(lattice_bridge_node_remove_label(handle, node, $0)) } } }
    public func deleteEdge(from source: NodeID, to target: NodeID, type: String) throws { try withHandle { handle in try type.withCString { try check(lattice_bridge_edge_delete(handle, source, target, $0)) } } }
    public func setProperty(_ key: String, onNode node: NodeID, to value: Value) throws { try setScalar(key, id: node, value: value, setter: lattice_bridge_node_set_scalar) }
    public func setProperty(_ key: String, onEdge edge: EdgeID, to value: Value) throws { try setScalar(key, id: edge, value: value, setter: lattice_bridge_edge_set_scalar) }
    public func nodeIDs(label: String) throws -> [NodeID] { try withHandle { handle in var ids: UnsafeMutablePointer<UInt64>?; var count = 0; try label.withCString { try check(lattice_bridge_nodes_with_label(handle, $0, &ids, &count)) }; defer { if let ids { lattice_bridge_free_node_ids(ids, count) } }; return ids.map { Array(UnsafeBufferPointer(start: $0, count: count)) } ?? [] } }
    public func labels(of node: NodeID) throws -> [String] { try withHandle { handle in var string: UnsafeMutablePointer<CChar>?; try check(lattice_bridge_node_labels(handle, node, &string)); defer { if let string { lattice_bridge_free_string(string) } }; guard let string else { return [] }; return String(cString: string).split(separator: ",").map(String.init) } }
    private func setScalar(_ key: String, id: UInt64, value: Value, setter: (OpaquePointer?, UInt64, UnsafePointer<CChar>?, Int32, Int64, Double, Bool, UnsafePointer<CChar>?) -> Int32) throws { try withHandle { handle in try key.withCString { key in switch value { case .null: try check(setter(handle, id, key, 0, 0, 0, false, nil)); case let .bool(value): try check(setter(handle, id, key, 1, 0, 0, value, nil)); case let .integer(value): try check(setter(handle, id, key, 2, value, 0, false, nil)); case let .double(value): try check(setter(handle, id, key, 3, 0, value, false, nil)); case let .string(value): try value.withCString { try check(setter(handle, id, key, 4, 0, 0, false, $0)) } } } } }
    public func commit() throws { guard let handle else { throw LatticeError.transactionClosed }; self.handle = nil; try check(lattice_bridge_commit(handle)) }
    public func rollback() { guard let handle else { return }; self.handle = nil; _ = lattice_bridge_rollback(handle) }
    private func withHandle<T>(_ body: (OpaquePointer) throws -> T) throws -> T { guard let handle else { throw LatticeError.transactionClosed }; return try body(handle) }
}
public enum LatticeDB { public static let nativeVersion = "0.11.1" }
public extension Database { func matchJSON(_ cypher: String) throws -> String { guard let handle else { throw LatticeError.transactionClosed }; var output: UnsafeMutablePointer<CChar>?; let code = cypher.withCString { lattice_bridge_match_json(handle, $0, &output) }; try check(code); guard let output else { return "[]" }; defer { lattice_bridge_free_json(output) }; return String(cString: output) } }
public extension Transaction {
    func allNodeIDs() throws -> [NodeID] { try withHandle { handle in var ids: UnsafeMutablePointer<UInt64>?; var count = 0; try check(lattice_bridge_all_node_ids(handle, &ids, &count)); defer { if let ids { lattice_bridge_free_node_ids(ids, count) } }; return ids.map { Array(UnsafeBufferPointer(start: $0, count: count)) } ?? [] } }
    func nodePropertyJSON(_ key: String, of node: NodeID) throws -> String { try withHandle { handle in var output: UnsafeMutablePointer<CChar>?; let code = key.withCString { lattice_bridge_node_property_json(handle, node, $0, &output) }; try check(code); guard let output else { return "null" }; defer { lattice_bridge_free_json(output) }; return String(cString: output) } }
    func edgesJSON(for node: NodeID, outgoing: Bool, type: String? = nil) throws -> String { try withHandle { handle in var output: UnsafeMutablePointer<CChar>?; let code = type.map { $0.withCString { lattice_bridge_edges_json(handle, node, outgoing, $0, &output) } } ?? lattice_bridge_edges_json(handle, node, outgoing, nil, &output); try check(code); guard let output else { return "[]" }; defer { lattice_bridge_free_json(output) }; return String(cString: output) } }
}
public extension Database { func nodeTypes() throws -> [String] { try read { transaction in var types = Set<String>(); for node in try transaction.allNodeIDs() { types.formUnion(try transaction.labels(of: node)) }; return types.sorted() } } }
public extension Database {
    func createNodeIndex(label: String, property: String) throws { try index(label, property, create: true, operation: lattice_bridge_node_index) }
    func dropNodeIndex(label: String, property: String) throws { try index(label, property, create: false, operation: lattice_bridge_node_index) }
    func createEdgeIndex(type: String, property: String) throws { try index(type, property, create: true, operation: lattice_bridge_edge_index) }
    func dropEdgeIndex(type: String, property: String) throws { try index(type, property, create: false, operation: lattice_bridge_edge_index) }
    private func index(_ kind: String, _ property: String, create: Bool, operation: (OpaquePointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, Bool) -> Int32) throws { guard let handle else { throw LatticeError.transactionClosed }; let code = kind.withCString { kind in property.withCString { property in operation(handle, kind, property, create) } }; try check(code) }
}
public extension Database {
    func nodeSummaryJSON(_ node: NodeID) throws -> String {
        try read { transaction in
            guard try transaction.nodeExists(node) else { throw LatticeError.native(-4) }
            let labels = try JSONEncoder().encode(try transaction.labels(of: node))
            let labelJSON = String(decoding: labels, as: UTF8.self)
            let outgoing = try transaction.edgesJSON(for: node, outgoing: true)
            let incoming = try transaction.edgesJSON(for: node, outgoing: false)
            return "{\"id\":\(node),\"labels\":\(labelJSON),\"outgoing\":\(outgoing),\"incoming\":\(incoming)}"
        }
    }
}
private func check(_ code: Int32) throws { guard code == 0 else { throw LatticeError.native(code) } }
