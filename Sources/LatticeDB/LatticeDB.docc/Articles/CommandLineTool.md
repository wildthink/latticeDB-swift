# The lattice Command

Create, inspect, and query a graph file from a terminal.

## Overview

The package ships an executable, `lattice`, that exposes the same engine as the
library. It is the fastest way to look at a database your app wrote, to seed
fixtures, or to try a Cypher query before embedding it in Swift.

```sh
swift build
swift run lattice version        # the pinned native engine version
```

Or through the Makefile: `make build`, then `make run ARGS="version"`.

### A graph to play with

`lattice demo` writes a small dataset — three people, three places, two events,
joined by `KNOWS`, `FREQUENTS`, `CARES_FOR`, `ATTENDS`, and `HAPPENS_AT`. It
refuses to overwrite an existing file, so name a fresh path:

```sh
swift run lattice demo --database demo.db
```

```sh
swift run lattice match --database demo.db --format table \
  "MATCH (p:Person) RETURN p.name, p.role"
```

### Choosing the database

Every data command takes `--database <path>`. Outside the REPL that option is
required, because each invocation is a fresh process.

Inside `lattice repl` a session persists, so open a database once and drop the
option:

```sh
swift run lattice repl
lattice > database open demo.db
lattice > node list --label Person
lattice > match "MATCH (p:Person) RETURN p.name"
lattice > database status
lattice > .exit
```

Tab completes commands and options, `.form <command>` fills one in
interactively, `.help` lists the meta commands, and Ctrl-D quits. History is
kept in `~/.lattice_history`. Pass `--read-only` to `repl` (or to
`database open`) for a session that cannot write.

### Commands

**`database`** — session state, meaningful inside the REPL.

| Command | Effect |
| --- | --- |
| `database open <path> [--read-only]` | Make it the session default |
| `database close` | Drop the default |
| `database status` | Print the current default |

**`node`** — one node at a time.

| Command | Effect |
| --- | --- |
| `node create [--label L]` | Create a node; prints its id |
| `node list --label L` | Print every node id carrying `L` |
| `node show <id>` | JSON: labels plus incoming and outgoing edges |
| `node labels <id>` | The node's labels |
| `node property <id> <key>` | One property, JSON-encoded |
| `node set <id> <key> --value V [--type T]` | Set a property |
| `node types` | Every label currently in use |
| `node delete <id>` | Delete the node and its graph state |

**`edge`** — edges are identified by source, target, and type.

| Command | Effect |
| --- | --- |
| `edge create --source S --target T --type TYPE` | Create an edge; prints its id |
| `edge outgoing <id> [--type TYPE]` | Outgoing edges as JSON |
| `edge incoming <id> [--type TYPE]` | Incoming edges as JSON |
| `edge set <edge-id> <key> --value V [--type T]` | Set an edge property |
| `edge delete --source S --target T --type TYPE` | Delete the edge |

**`index`** — equality indexes; see <doc:IndexingAndPerformance>.

| Command | Effect |
| --- | --- |
| `index node create --label L --property P` | Index a node property |
| `index node drop --label L --property P` | Drop it |
| `index edge create --type T --property P` | Index an edge property |
| `index edge drop --type T --property P` | Drop it |

**`match`** — read-only Cypher.

| Option | Effect |
| --- | --- |
| `<cypher>` | The query text, as one argument |
| `--file <path>` | Read the query from a file instead |
| `--param name=value` | Bind a parameter; repeatable |
| `--format json\|table\|csv` | Output shape; defaults to `json` |

`match` opens the database read-only, so it is safe to point at a file another
process is using.

### Property types

`--value` is typed by inspection unless you say otherwise: `true` and `false`
become booleans, digits become integers, a decimal point makes a double, and
anything else is a string. Force a type with `--type string|int|double|bool|null`
— which is how you store `"42"` or `"true"` as text:

```sh
swift run lattice node set 1 zip --value 02139 --type string
swift run lattice node set 1 retired --value x --type null
```

The same inference applies to `--param name=value`.

### Recipes

Run a saved query and get a spreadsheet:

```sh
swift run lattice match --database demo.db --file Examples/people-names.cypher --format csv > people.csv
```

Bind a parameter instead of quoting a value into the query:

```sh
swift run lattice match --database demo.db --param name="Ada Chen" \
  "MATCH (p:Person) WHERE p.name = \$name RETURN p.name, p.role"
```

Inspect a node written by your app:

```sh
swift run lattice node show --database social.db 1 | jq
```

Install the binary so the `swift run` prefix goes away:

```sh
swift build -c release
cp .build/release/lattice /usr/local/bin/
```

## See Also

- <doc:GettingStarted>
- <doc:CypherAndJSON>
