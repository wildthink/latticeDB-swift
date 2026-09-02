#include <lattice.h>
#include <stdbool.h>
#include <stdint.h>

typedef struct {
  const char *name;
  int32_t type;
  int64_t integer;
  double real;
  bool boolean;
  const char *string;
} lattice_bridge_parameter;
int32_t lattice_bridge_open(const char *, bool, bool, bool, uint16_t,
                            lattice_database **);
int32_t lattice_bridge_close(lattice_database *);
int32_t lattice_bridge_begin(lattice_database *, bool, lattice_txn **);
int32_t lattice_bridge_commit(lattice_txn *);
int32_t lattice_bridge_rollback(lattice_txn *);
int32_t lattice_bridge_node_create(lattice_txn *, const char *, uint64_t *);
int32_t lattice_bridge_edge_create(lattice_txn *, uint64_t, uint64_t,
                                   const char *, uint64_t *);
int32_t lattice_bridge_node_delete(lattice_txn *, uint64_t);
int32_t lattice_bridge_node_exists(lattice_txn *, uint64_t, bool *);
int32_t lattice_bridge_node_add_label(lattice_txn *, uint64_t, const char *);
int32_t lattice_bridge_node_remove_label(lattice_txn *, uint64_t, const char *);
int32_t lattice_bridge_edge_delete(lattice_txn *, uint64_t, uint64_t,
                                   const char *);
int32_t lattice_bridge_node_set_scalar(lattice_txn *, uint64_t, const char *,
                                       int32_t, int64_t, double, bool,
                                       const char *);
int32_t lattice_bridge_edge_set_scalar(lattice_txn *, uint64_t, const char *,
                                       int32_t, int64_t, double, bool,
                                       const char *);
int32_t lattice_bridge_nodes_with_label(lattice_txn *, const char *,
                                        uint64_t **, size_t *);
int32_t lattice_bridge_all_node_ids(lattice_txn *, uint64_t **, size_t *);
void lattice_bridge_free_node_ids(uint64_t *, size_t);
int32_t lattice_bridge_node_labels(lattice_txn *, uint64_t, char **);
void lattice_bridge_free_string(char *);
int32_t lattice_bridge_match_json(lattice_database *, const char *, char **);
int32_t lattice_bridge_match_json_parameters(lattice_database *, const char *,
                                             const lattice_bridge_parameter *,
                                             size_t, char **);
int32_t lattice_bridge_match_json_txn(lattice_database *, lattice_txn *,
                                      const char *,
                                      const lattice_bridge_parameter *, size_t,
                                      char **);
void lattice_bridge_free_json(char *);
void lattice_bridge_free_buffer(char *);
int32_t lattice_bridge_node_property(lattice_txn *, uint64_t, const char *,
                                     int32_t *, int64_t *, double *, bool *,
                                     char **);
int32_t lattice_bridge_edge_property(lattice_txn *, uint64_t, const char *,
                                     int32_t *, int64_t *, double *, bool *,
                                     char **);
int32_t lattice_bridge_edge_remove_property(lattice_txn *, uint64_t,
                                            const char *);
int32_t lattice_bridge_nodes_find_by_property(lattice_txn *, const char *,
                                              const char *, int32_t, int64_t,
                                              double, bool, const char *,
                                              size_t, uint64_t **, size_t *);
int32_t lattice_bridge_node_property_json(lattice_txn *, uint64_t, const char *,
                                          char **);
int32_t lattice_bridge_edges_json(lattice_txn *, uint64_t, bool, const char *,
                                  char **);
int32_t lattice_bridge_node_index(lattice_database *, const char *,
                                  const char *, bool);
int32_t lattice_bridge_edge_index(lattice_database *, const char *,
                                  const char *, bool);

/* Full-text search. `node` selects the node-label index when true and the
   edge-type index when false. */
int32_t lattice_bridge_fts_index(lattice_database *, const char *, const char *,
                                 bool, bool);
int32_t lattice_bridge_fts_index_exists(lattice_database *, const char *,
                                        const char *, bool, bool *);
/* Searches through `txn` when it is non-NULL and through `database` otherwise.
   Results are returned as parallel arrays owned by the caller, which must free
   them with lattice_bridge_free_matches(). */
int32_t lattice_bridge_fts_search(lattice_database *, lattice_txn *,
                                  const char *, const char *, const char *,
                                  uint32_t, bool, uint32_t, uint32_t,
                                  uint64_t **, float **, size_t *);
int32_t lattice_bridge_node_set_vector(lattice_txn *, uint64_t, const char *,
                                       const float *, uint32_t);
int32_t lattice_bridge_vector_search(lattice_database *, lattice_txn *,
                                     const float *, uint32_t, uint32_t,
                                     uint16_t, uint64_t **, float **, size_t *);
void lattice_bridge_free_matches(uint64_t *, float *, size_t);

/* Embeddings. Vectors are freed with lattice_bridge_free_vector(). */
int32_t lattice_bridge_hash_embed(const char *, uint16_t, float **, uint32_t *);
void lattice_bridge_free_vector(float *, uint32_t);
int32_t lattice_bridge_embedding_client_create(const char *, const char *,
                                               int32_t, const char *, uint32_t,
                                               lattice_embedding_client **);
int32_t lattice_bridge_embedding_client_embed(lattice_embedding_client *,
                                              const char *, float **,
                                              uint32_t *);
void lattice_bridge_embedding_client_free(lattice_embedding_client *);

/* Durable streams. */
int32_t lattice_bridge_stream_publish(lattice_txn *, const char *, const char *,
                                      int32_t, int64_t, double, bool,
                                      const char *, uint64_t *);
int32_t lattice_bridge_stream_read(lattice_database *, const char *, uint64_t,
                                   size_t, uint32_t, lattice_stream_batch **,
                                   size_t *);
/* The returned kind and string payload are owned by the caller and freed with
   lattice_bridge_free_buffer(). */
int32_t lattice_bridge_stream_batch_get(lattice_stream_batch *, size_t,
                                        uint64_t *, char **, int32_t *,
                                        int64_t *, double *, bool *, char **);
void lattice_bridge_stream_batch_free(lattice_stream_batch *);
int32_t lattice_bridge_stream_offset(lattice_database *, const char *,
                                     const char *, bool *, uint64_t *);
int32_t lattice_bridge_stream_last_sequence(lattice_database *, const char *,
                                            uint64_t *);
int32_t lattice_bridge_stream_set_offset(lattice_txn *, const char *,
                                         const char *, uint64_t);
int32_t lattice_bridge_stream_trim(lattice_txn *, const char *, uint64_t);
