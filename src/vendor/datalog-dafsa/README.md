# vendored datalog-dafsa core

Snapshot of the datalog-dafsa fact-store core, linked **in-process** by the
vibe-runtime daemon so the run store (Slice 2) is a DAFSA-backed durable fact
store instead of a hand-rolled runs.json.

- **Source:** local `~/projects/datalog-dafsa`
- **Vendored from commit:** `3c557b9`
- **Included:** the datalog-dafsa Makefile's `LIB_OBJS` + `VENDOR_OBJS` (the
  full engine core). EXCLUDED: `dl_cli.c` (CLI main), `lsp.c`, `json.c`,
  `playground-wasm.c` (LSP/wasm/CLI only). All public headers copied.
- **Entry points used by the daemon:** the EDB fact API from `dl.h`
  (`dl_open2/dl_declare_relation/dl_add_fact/dl_delete_fact/dl_lookup/
  dl_prefix/dl_count/dl_intern_str/dl_intern_str_of`). No rules/VM/snapshots
  for v1.
- **Build needs:** `-D_POSIX_C_SOURCE=200809L` (getline/strndup/fsync) +
  `-Isrc/vendor/datalog-dafsa/src -Isrc/vendor/datalog-dafsa/vendor`.
- **Provenance:** `dl.h`, `relation.c`, `intern.c`, `dl.c`, `snapshot.c`,
  `vendor/dafsa*.c` verbatim from the source repo.
