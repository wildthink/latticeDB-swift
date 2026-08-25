#include <stdbool.h>
#include <stdint.h>
#include <lattice.h>
int32_t lattice_bridge_open(const char *, bool, bool, lattice_database **);
int32_t lattice_bridge_close(lattice_database *);
int32_t lattice_bridge_begin(lattice_database *, bool, lattice_txn **);
int32_t lattice_bridge_commit(lattice_txn *);
int32_t lattice_bridge_rollback(lattice_txn *);
int32_t lattice_bridge_node_create(lattice_txn *, const char *, uint64_t *);
int32_t lattice_bridge_edge_create(lattice_txn *, uint64_t, uint64_t, const char *, uint64_t *);
int32_t lattice_bridge_node_delete(lattice_txn *, uint64_t);
int32_t lattice_bridge_node_exists(lattice_txn *, uint64_t, bool *);
int32_t lattice_bridge_node_add_label(lattice_txn *, uint64_t, const char *);
int32_t lattice_bridge_node_remove_label(lattice_txn *, uint64_t, const char *);
int32_t lattice_bridge_edge_delete(lattice_txn *, uint64_t, uint64_t, const char *);
int32_t lattice_bridge_node_set_scalar(lattice_txn *, uint64_t, const char *, int32_t, int64_t, double, bool, const char *);
int32_t lattice_bridge_edge_set_scalar(lattice_txn *, uint64_t, const char *, int32_t, int64_t, double, bool, const char *);
int32_t lattice_bridge_nodes_with_label(lattice_txn *, const char *, uint64_t **, size_t *);
int32_t lattice_bridge_all_node_ids(lattice_txn *, uint64_t **, size_t *);
void lattice_bridge_free_node_ids(uint64_t *, size_t);
int32_t lattice_bridge_node_labels(lattice_txn *, uint64_t, char **);
void lattice_bridge_free_string(char *);
int32_t lattice_bridge_match_json(lattice_database *, const char *, char **);
void lattice_bridge_free_json(char *);
int32_t lattice_bridge_node_property_json(lattice_txn *, uint64_t, const char *, char **);
int32_t lattice_bridge_edges_json(lattice_txn *, uint64_t, bool, const char *, char **);
int32_t lattice_bridge_node_index(lattice_database *, const char *, const char *, bool);
int32_t lattice_bridge_edge_index(lattice_database *, const char *, const char *, bool);
