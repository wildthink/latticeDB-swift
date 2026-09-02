#include "lattice_bridge.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int32_t lattice_bridge_open(const char *path, bool create, bool read_only,
                            bool enable_vector, uint16_t vector_dimensions,
                            lattice_database **out) {
  lattice_open_options_v3 options = LATTICE_OPEN_OPTIONS_V3_DEFAULT;
  options.create = create;
  options.read_only = read_only;
  options.enable_vector = enable_vector;
  if (enable_vector && vector_dimensions)
    options.vector_dimensions = vector_dimensions;
  return lattice_open_v3(path, &options, out);
}
int32_t lattice_bridge_close(lattice_database *db) { return lattice_close(db); }
int32_t lattice_bridge_begin(lattice_database *db, bool writable,
                             lattice_txn **out) {
  return lattice_begin(
      db, writable ? LATTICE_TXN_READ_WRITE : LATTICE_TXN_READ_ONLY, out);
}
int32_t lattice_bridge_commit(lattice_txn *txn) { return lattice_commit(txn); }
int32_t lattice_bridge_rollback(lattice_txn *txn) {
  return lattice_rollback(txn);
}
int32_t lattice_bridge_node_create(lattice_txn *txn, const char *label,
                                   uint64_t *out) {
  return lattice_node_create(txn, label, out);
}
int32_t lattice_bridge_edge_create(lattice_txn *txn, uint64_t source,
                                   uint64_t target, const char *type,
                                   uint64_t *out) {
  return lattice_edge_create(txn, source, target, type, out);
}
int32_t lattice_bridge_node_delete(lattice_txn *txn, uint64_t node) {
  return lattice_node_delete(txn, node);
}
int32_t lattice_bridge_node_exists(lattice_txn *txn, uint64_t node, bool *out) {
  return lattice_node_exists(txn, node, out);
}
int32_t lattice_bridge_node_add_label(lattice_txn *txn, uint64_t node,
                                      const char *label) {
  return lattice_node_add_label(txn, node, label);
}
int32_t lattice_bridge_node_remove_label(lattice_txn *txn, uint64_t node,
                                         const char *label) {
  return lattice_node_remove_label(txn, node, label);
}
int32_t lattice_bridge_edge_delete(lattice_txn *txn, uint64_t source,
                                   uint64_t target, const char *type) {
  return lattice_edge_delete(txn, source, target, type);
}
static lattice_value scalar(int32_t type, int64_t integer, double real,
                            bool boolean, const char *string) {
  lattice_value value = {0};
  value.type = (lattice_value_type)type;
  if (type == LATTICE_VALUE_BOOL)
    value.data.bool_val = boolean;
  else if (type == LATTICE_VALUE_INT)
    value.data.int_val = integer;
  else if (type == LATTICE_VALUE_FLOAT)
    value.data.float_val = real;
  else if (type == LATTICE_VALUE_STRING) {
    value.data.string_val.ptr = string;
    value.data.string_val.len = strlen(string);
  }
  return value;
}
int32_t lattice_bridge_node_set_scalar(lattice_txn *txn, uint64_t node,
                                       const char *key, int32_t type,
                                       int64_t integer, double real,
                                       bool boolean, const char *string) {
  lattice_value value = scalar(type, integer, real, boolean, string);
  return lattice_node_set_property(txn, node, key, &value);
}
int32_t lattice_bridge_edge_set_scalar(lattice_txn *txn, uint64_t edge,
                                       const char *key, int32_t type,
                                       int64_t integer, double real,
                                       bool boolean, const char *string) {
  lattice_value value = scalar(type, integer, real, boolean, string);
  return lattice_edge_set_property(txn, edge, key, &value);
}
int32_t lattice_bridge_nodes_with_label(lattice_txn *txn, const char *label,
                                        uint64_t **ids, size_t *count) {
  return lattice_get_nodes_by_label_txn(txn, label, strlen(label), ids, count);
}
int32_t lattice_bridge_all_node_ids(lattice_txn *txn, uint64_t **ids,
                                    size_t *count) {
  return lattice_get_all_nodes_txn(txn, ids, count);
}
void lattice_bridge_free_node_ids(uint64_t *ids, size_t count) {
  lattice_free_node_ids(ids, count);
}
int32_t lattice_bridge_node_labels(lattice_txn *txn, uint64_t node,
                                   char **labels) {
  return lattice_node_get_labels(txn, node, labels);
}
void lattice_bridge_free_string(char *string) { lattice_free_string(string); }
static void json_string(FILE *stream, const char *string, size_t length) {
  fputc('"', stream);
  for (size_t i = 0; i < length; i++) {
    unsigned char c = string[i];
    switch (c) {
    case '"':
      fputs("\\\"", stream);
      break;
    case '\\':
      fputs("\\\\", stream);
      break;
    case '\b':
      fputs("\\b", stream);
      break;
    case '\f':
      fputs("\\f", stream);
      break;
    case '\n':
      fputs("\\n", stream);
      break;
    case '\r':
      fputs("\\r", stream);
      break;
    case '\t':
      fputs("\\t", stream);
      break;
    default:
      if (c < 0x20)
        fprintf(stream, "\\u%04x", c);
      else
        fputc(c, stream);
    }
  }
  fputc('"', stream);
}
static void json_value(FILE *stream, lattice_value value) {
  switch (value.type) {
  case LATTICE_VALUE_NULL:
    fputs("null", stream);
    break;
  case LATTICE_VALUE_BOOL:
    fputs(value.data.bool_val ? "true" : "false", stream);
    break;
  case LATTICE_VALUE_INT:
    fprintf(stream, "%lld", (long long)value.data.int_val);
    break;
  case LATTICE_VALUE_FLOAT:
    if (isfinite(value.data.float_val))
      fprintf(stream, "%.17g", value.data.float_val);
    else
      fputs("null", stream);
    break;
  case LATTICE_VALUE_STRING:
    json_string(stream, value.data.string_val.ptr, value.data.string_val.len);
    break;
  case LATTICE_VALUE_BYTES:
    fputc('[', stream);
    for (size_t i = 0; i < value.data.bytes_val.len; i++) {
      if (i)
        fputc(',', stream);
      fprintf(stream, "%u", value.data.bytes_val.ptr[i]);
    }
    fputc(']', stream);
    break;
  case LATTICE_VALUE_VECTOR:
    fputc('[', stream);
    for (uint32_t i = 0; i < value.data.vector_val.dimensions; i++) {
      if (i)
        fputc(',', stream);
      float item = value.data.vector_val.ptr[i];
      if (isfinite(item))
        fprintf(stream, "%.9g", item);
      else
        fputs("null", stream);
    }
    fputc(']', stream);
    break;
  case LATTICE_VALUE_LIST:
    fputc('[', stream);
    for (size_t i = 0; i < value.data.list_val->len; i++) {
      if (i)
        fputc(',', stream);
      json_value(stream, value.data.list_val->items[i]);
    }
    fputc(']', stream);
    break;
  case LATTICE_VALUE_MAP:
    fputc('{', stream);
    for (size_t i = 0; i < value.data.map_val->len; i++) {
      if (i)
        fputc(',', stream);
      lattice_map_entry entry = value.data.map_val->entries[i];
      json_string(stream, entry.key, entry.key_len);
      fputc(':', stream);
      json_value(stream, entry.value);
    }
    fputc('}', stream);
    break;
  default:
    fputs("null", stream);
  }
}
static int32_t match_json_common(lattice_database *database,
                                 lattice_txn *borrowed, const char *cypher,
                                 const lattice_bridge_parameter *parameters,
                                 size_t parameter_count, char **out) {
  lattice_query *query = NULL;
  lattice_txn *txn = NULL;
  lattice_result *result = NULL;
  int32_t code = lattice_query_prepare(database, cypher, &query);
  if (code != LATTICE_OK)
    return code;
  if (lattice_query_writes(query)) {
    lattice_query_free(query);
    return LATTICE_ERROR_READ_ONLY;
  }
  for (size_t i = 0; i < parameter_count; i++) {
    lattice_bridge_parameter parameter = parameters[i];
    lattice_value value =
        scalar(parameter.type, parameter.integer, parameter.real,
               parameter.boolean, parameter.string);
    code = lattice_query_bind(query, parameter.name, &value);
    if (code != LATTICE_OK) {
      lattice_query_free(query);
      return code;
    }
  }
  if (borrowed)
    code = lattice_query_execute(query, borrowed, &result);
  else {
    code = lattice_begin(database, LATTICE_TXN_READ_ONLY, &txn);
    if (code == LATTICE_OK)
      code = lattice_query_execute(query, txn, &result);
  }
  if (code != LATTICE_OK) {
    if (result)
      lattice_result_free(result);
    if (txn)
      lattice_rollback(txn);
    lattice_query_free(query);
    return code;
  }
  char *buffer = NULL;
  size_t length = 0;
  FILE *stream = open_memstream(&buffer, &length);
  if (!stream) {
    lattice_result_free(result);
    if (txn)
      lattice_rollback(txn);
    lattice_query_free(query);
    return LATTICE_ERROR_OUT_OF_MEMORY;
  }
  fputc('[', stream);
  bool first_row = true;
  while (lattice_result_next(result)) {
    if (!first_row)
      fputc(',', stream);
    first_row = false;
    fputc('{', stream);
    uint32_t columns = lattice_result_column_count(result);
    for (uint32_t i = 0; i < columns; i++) {
      if (i)
        fputc(',', stream);
      const char *name = lattice_result_column_name(result, i);
      json_string(stream, name, strlen(name));
      fputc(':', stream);
      lattice_value value = {0};
      if (lattice_result_get(result, i, &value) == LATTICE_OK)
        json_value(stream, value);
      else
        fputs("null", stream);
    }
    fputc('}', stream);
  }
  fputc(']', stream);
  fclose(stream);
  lattice_result_free(result);
  if (txn)
    lattice_rollback(txn);
  lattice_query_free(query);
  *out = buffer;
  return LATTICE_OK;
}
int32_t
lattice_bridge_match_json_parameters(lattice_database *database,
                                     const char *cypher,
                                     const lattice_bridge_parameter *parameters,
                                     size_t parameter_count, char **out) {
  return match_json_common(database, NULL, cypher, parameters, parameter_count,
                           out);
}
int32_t
lattice_bridge_match_json_txn(lattice_database *database, lattice_txn *txn,
                              const char *cypher,
                              const lattice_bridge_parameter *parameters,
                              size_t parameter_count, char **out) {
  return match_json_common(database, txn, cypher, parameters, parameter_count,
                           out);
}
int32_t lattice_bridge_match_json(lattice_database *database,
                                  const char *cypher, char **out) {
  return lattice_bridge_match_json_parameters(database, cypher, NULL, 0, out);
}
void lattice_bridge_free_json(char *json) { free(json); }
void lattice_bridge_free_buffer(char *buffer) { free(buffer); }
int32_t lattice_bridge_node_property_json(lattice_txn *txn, uint64_t node,
                                          const char *key, char **out) {
  lattice_value value = {0};
  int32_t code = lattice_node_get_property(txn, node, key, &value);
  if (code != LATTICE_OK)
    return code;
  char *buffer = NULL;
  size_t length = 0;
  FILE *stream = open_memstream(&buffer, &length);
  if (!stream) {
    lattice_value_free(&value);
    return LATTICE_ERROR_OUT_OF_MEMORY;
  }
  json_value(stream, value);
  fclose(stream);
  lattice_value_free(&value);
  *out = buffer;
  return LATTICE_OK;
}
static int32_t copy_scalar(lattice_value value, int32_t *type_out,
                           int64_t *integer_out, double *real_out,
                           bool *boolean_out, char **string_out) {
  *type_out = (int32_t)value.type;
  *integer_out = 0;
  *real_out = 0;
  *boolean_out = false;
  *string_out = NULL;
  switch (value.type) {
  case LATTICE_VALUE_BOOL:
    *boolean_out = value.data.bool_val;
    break;
  case LATTICE_VALUE_INT:
    *integer_out = value.data.int_val;
    break;
  case LATTICE_VALUE_FLOAT:
    *real_out = value.data.float_val;
    break;
  case LATTICE_VALUE_STRING: {
    size_t length = value.data.string_val.len;
    char *copy = malloc(length + 1);
    if (!copy)
      return LATTICE_ERROR_OUT_OF_MEMORY;
    if (length)
      memcpy(copy, value.data.string_val.ptr, length);
    copy[length] = '\0';
    *string_out = copy;
    break;
  }
  default:
    break;
  }
  return LATTICE_OK;
}
int32_t lattice_bridge_node_property(lattice_txn *txn, uint64_t node,
                                     const char *key, int32_t *type_out,
                                     int64_t *integer_out, double *real_out,
                                     bool *boolean_out, char **string_out) {
  lattice_value value = {0};
  int32_t code = lattice_node_get_property(txn, node, key, &value);
  if (code != LATTICE_OK)
    return code;
  code = copy_scalar(value, type_out, integer_out, real_out, boolean_out,
                     string_out);
  lattice_value_free(&value);
  return code;
}
int32_t lattice_bridge_edge_property(lattice_txn *txn, uint64_t edge,
                                     const char *key, int32_t *type_out,
                                     int64_t *integer_out, double *real_out,
                                     bool *boolean_out, char **string_out) {
  lattice_value value = {0};
  int32_t code = lattice_edge_get_property(txn, edge, key, &value);
  if (code != LATTICE_OK)
    return code;
  code = copy_scalar(value, type_out, integer_out, real_out, boolean_out,
                     string_out);
  lattice_value_free(&value);
  return code;
}
int32_t lattice_bridge_edge_remove_property(lattice_txn *txn, uint64_t edge,
                                            const char *key) {
  return lattice_edge_remove_property(txn, edge, key);
}
int32_t lattice_bridge_nodes_find_by_property(
    lattice_txn *txn, const char *label, const char *property, int32_t type,
    int64_t integer, double real, bool boolean, const char *string,
    size_t limit, uint64_t **ids, size_t *count) {
  lattice_value value = scalar(type, integer, real, boolean, string);
  return lattice_nodes_find_by_label_property(txn, label, property, &value,
                                              limit, ids, count);
}
int32_t lattice_bridge_edges_json(lattice_txn *txn, uint64_t node,
                                  bool outgoing, const char *type, char **out) {
  lattice_edge_result *result = NULL;
  int32_t code;
  if (type)
    code = outgoing
               ? lattice_edge_get_outgoing_by_type(txn, node, type, 0, &result)
               : lattice_edge_get_incoming_by_type(txn, node, type, 0, &result);
  else
    code = outgoing ? lattice_edge_get_outgoing(txn, node, &result)
                    : lattice_edge_get_incoming(txn, node, &result);
  if (code != LATTICE_OK)
    return code;
  char *buffer = NULL;
  size_t length = 0;
  FILE *stream = open_memstream(&buffer, &length);
  if (!stream) {
    lattice_edge_result_free(result);
    return LATTICE_ERROR_OUT_OF_MEMORY;
  }
  fputc('[', stream);
  uint32_t count = lattice_edge_result_count(result);
  for (uint32_t i = 0; i < count; i++) {
    if (i)
      fputc(',', stream);
    uint64_t source, target, edge_id = 0;
    const char *edge_type;
    uint32_t edge_type_len;
    code = lattice_edge_result_get(result, i, &source, &target, &edge_type,
                                   &edge_type_len);
    if (code == LATTICE_OK)
      code = lattice_edge_result_get_id(result, i, &edge_id);
    if (code != LATTICE_OK) {
      fclose(stream);
      free(buffer);
      lattice_edge_result_free(result);
      return code;
    }
    fprintf(stream, "{\"id\":%llu,\"source\":%llu,\"target\":%llu,\"type\":",
            (unsigned long long)edge_id, (unsigned long long)source,
            (unsigned long long)target);
    json_string(stream, edge_type, edge_type_len);
    fputc('}', stream);
  }
  fputc(']', stream);
  fclose(stream);
  lattice_edge_result_free(result);
  *out = buffer;
  return LATTICE_OK;
}
int32_t lattice_bridge_node_index(lattice_database *database, const char *label,
                                  const char *property, bool create) {
  return create ? lattice_node_property_index_create(database, label, property)
                : lattice_node_property_index_drop(database, label, property);
}
int32_t lattice_bridge_edge_index(lattice_database *database, const char *type,
                                  const char *property, bool create) {
  return create ? lattice_edge_property_index_create(database, type, property)
                : lattice_edge_property_index_drop(database, type, property);
}
int32_t lattice_bridge_fts_index(lattice_database *database, const char *name,
                                 const char *property, bool create, bool node) {
  if (node)
    return create ? lattice_node_fts_index_create(database, name, property)
                  : lattice_node_fts_index_drop(database, name, property);
  return create ? lattice_edge_fts_index_create(database, name, property)
                : lattice_edge_fts_index_drop(database, name, property);
}
int32_t lattice_bridge_fts_index_exists(lattice_database *database,
                                        const char *name, const char *property,
                                        bool node, bool *out) {
  return node ? lattice_node_fts_index_exists(database, name, property, out)
              : lattice_edge_fts_index_exists(database, name, property, out);
}
/* Copies (id, score) pairs out of a result set so the caller never holds a
   native result handle. Frees the result either way. */
static int32_t drain_matches(uint32_t count,
                             int32_t (*get)(void *, uint32_t, uint64_t *,
                                            float *),
                             void *result, uint64_t **ids_out,
                             float **scores_out, size_t *count_out) {
  *ids_out = NULL;
  *scores_out = NULL;
  *count_out = 0;
  if (!count)
    return LATTICE_OK;
  uint64_t *ids = malloc(count * sizeof(uint64_t));
  float *scores = malloc(count * sizeof(float));
  if (!ids || !scores) {
    free(ids);
    free(scores);
    return LATTICE_ERROR_OUT_OF_MEMORY;
  }
  for (uint32_t i = 0; i < count; i++) {
    int32_t code = get(result, i, &ids[i], &scores[i]);
    if (code != LATTICE_OK) {
      free(ids);
      free(scores);
      return code;
    }
  }
  *ids_out = ids;
  *scores_out = scores;
  *count_out = count;
  return LATTICE_OK;
}
static int32_t fts_get(void *result, uint32_t index, uint64_t *id,
                       float *score) {
  return lattice_fts_result_get((lattice_fts_result *)result, index, id, score);
}
static int32_t vector_get(void *result, uint32_t index, uint64_t *id,
                          float *distance) {
  return lattice_vector_result_get((lattice_vector_result *)result, index, id,
                                   distance);
}
int32_t lattice_bridge_fts_search(lattice_database *database, lattice_txn *txn,
                                  const char *label, const char *property,
                                  const char *query, uint32_t limit, bool fuzzy,
                                  uint32_t max_distance,
                                  uint32_t min_term_length, uint64_t **ids,
                                  float **scores, size_t *count) {
  lattice_fts_result *result = NULL;
  size_t query_len = strlen(query);
  int32_t code;
  if (fuzzy)
    code = txn ? lattice_fts_search_fuzzy_txn(txn, label, property, query,
                                              query_len, limit, max_distance,
                                              min_term_length, &result)
               : lattice_fts_search_fuzzy(database, label, property, query,
                                          query_len, limit, max_distance,
                                          min_term_length, &result);
  else
    code = txn ? lattice_fts_search_txn(txn, label, property, query, query_len,
                                        limit, &result)
               : lattice_fts_search(database, label, property, query, query_len,
                                    limit, &result);
  if (code != LATTICE_OK)
    return code;
  code = drain_matches(lattice_fts_result_count(result), fts_get, result, ids,
                       scores, count);
  lattice_fts_result_free(result);
  return code;
}
int32_t lattice_bridge_node_set_vector(lattice_txn *txn, uint64_t node,
                                       const char *key, const float *vector,
                                       uint32_t dimensions) {
  return lattice_node_set_vector(txn, node, key, vector, dimensions);
}
int32_t lattice_bridge_vector_search(lattice_database *database,
                                     lattice_txn *txn, const float *vector,
                                     uint32_t dimensions, uint32_t k,
                                     uint16_t ef_search, uint64_t **ids,
                                     float **distances, size_t *count) {
  lattice_vector_result *result = NULL;
  int32_t code =
      txn ? lattice_vector_search_txn(txn, vector, dimensions, k, ef_search,
                                      &result)
          : lattice_vector_search(database, vector, dimensions, k, ef_search,
                                  &result);
  if (code != LATTICE_OK)
    return code;
  code = drain_matches(lattice_vector_result_count(result), vector_get, result,
                       ids, distances, count);
  lattice_vector_result_free(result);
  return code;
}
void lattice_bridge_free_matches(uint64_t *ids, float *scores, size_t count) {
  (void)count;
  free(ids);
  free(scores);
}
int32_t lattice_bridge_hash_embed(const char *text, uint16_t dimensions,
                                  float **vector, uint32_t *dimensions_out) {
  return lattice_hash_embed(text, strlen(text), dimensions, vector,
                            dimensions_out);
}
void lattice_bridge_free_vector(float *vector, uint32_t dimensions) {
  lattice_hash_embed_free(vector, dimensions);
}
int32_t lattice_bridge_embedding_client_create(
    const char *endpoint, const char *model, int32_t api_format,
    const char *api_key, uint32_t timeout_ms,
    lattice_embedding_client **out) {
  lattice_embedding_config config = {0};
  config.endpoint = endpoint;
  config.model = model;
  config.api_format = (lattice_embedding_api_format)api_format;
  config.api_key = api_key;
  config.timeout_ms = timeout_ms;
  return lattice_embedding_client_create(&config, out);
}
int32_t lattice_bridge_embedding_client_embed(lattice_embedding_client *client,
                                              const char *text, float **vector,
                                              uint32_t *dimensions) {
  return lattice_embedding_client_embed(client, text, strlen(text), vector,
                                        dimensions);
}
void lattice_bridge_embedding_client_free(lattice_embedding_client *client) {
  lattice_embedding_client_free(client);
}
int32_t lattice_bridge_stream_publish(lattice_txn *txn, const char *stream,
                                      const char *kind, int32_t type,
                                      int64_t integer, double real,
                                      bool boolean, const char *string,
                                      uint64_t *sequence) {
  lattice_value payload = scalar(type, integer, real, boolean, string);
  return lattice_stream_publish_get_sequence(
      txn, stream, strlen(stream), kind, kind ? strlen(kind) : 0, &payload,
      sequence);
}
int32_t lattice_bridge_stream_read(lattice_database *database,
                                   const char *stream, uint64_t after,
                                   size_t limit, uint32_t timeout_ms,
                                   lattice_stream_batch **batch,
                                   size_t *count) {
  int32_t code = lattice_stream_read(database, stream, strlen(stream), after,
                                     limit, timeout_ms, batch);
  if (code != LATTICE_OK)
    return code;
  *count = lattice_stream_batch_count(*batch);
  return LATTICE_OK;
}
int32_t lattice_bridge_stream_batch_get(lattice_stream_batch *batch,
                                        size_t index, uint64_t *sequence,
                                        char **kind_out, int32_t *type,
                                        int64_t *integer, double *real,
                                        bool *boolean, char **string) {
  const char *kind = NULL;
  size_t kind_len = 0;
  const lattice_value *payload = NULL;
  *kind_out = NULL;
  int32_t code = lattice_stream_batch_get(batch, index, sequence, &kind,
                                          &kind_len, &payload);
  if (code != LATTICE_OK)
    return code;
  char *copy = malloc(kind_len + 1);
  if (!copy)
    return LATTICE_ERROR_OUT_OF_MEMORY;
  if (kind_len)
    memcpy(copy, kind, kind_len);
  copy[kind_len] = '\0';
  /* A record published with a NULL payload reads back as a null value. */
  lattice_value value = {0};
  code = copy_scalar(payload ? *payload : value, type, integer, real, boolean,
                     string);
  if (code != LATTICE_OK) {
    free(copy);
    return code;
  }
  *kind_out = copy;
  return LATTICE_OK;
}
void lattice_bridge_stream_batch_free(lattice_stream_batch *batch) {
  lattice_stream_batch_free(batch);
}
int32_t lattice_bridge_stream_offset(lattice_database *database,
                                     const char *stream, const char *consumer,
                                     bool *exists, uint64_t *sequence) {
  return lattice_stream_get_offset(database, stream, strlen(stream), consumer,
                                   strlen(consumer), exists, sequence);
}
int32_t lattice_bridge_stream_last_sequence(lattice_database *database,
                                            const char *stream,
                                            uint64_t *out) {
  return lattice_stream_get_last_sequence(database, stream, strlen(stream),
                                          out);
}
int32_t lattice_bridge_stream_set_offset(lattice_txn *txn, const char *stream,
                                         const char *consumer,
                                         uint64_t sequence) {
  return lattice_stream_set_offset(txn, stream, strlen(stream), consumer,
                                   strlen(consumer), sequence);
}
int32_t lattice_bridge_stream_trim(lattice_txn *txn, const char *stream,
                                   uint64_t through) {
  return lattice_stream_trim(txn, stream, strlen(stream), through);
}
