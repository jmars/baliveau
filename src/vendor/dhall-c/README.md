# vendored dhall-c interpreter core

Snapshot of the dhall-c interpreter core (the internal library, NOT the CLI
`main.c`/LSP `json.c`/`lsp.c`/`wasm.c`), linked **in-process** by the
vibe-runtime daemon so config authored in Dhall can be typechecked, normalized,
and serialized to JSON at runtime — all inside the single APE binary.

- **Source:** https://github.com/<your>/dhall-c (local: `~/projects/dhall-c`)
- **Vendored from commit:** `a7451a2`
- **Included:** the `bench`/`lsp` link set minus `main.c`, `json.c`, `lsp.c`,
  `wasm.c`, `bench.c`: arena, lexer, parser, ast, normalize, typecheck,
  builtins, serialize, import, bignum, sha256, ssrf, http (+ dhall.h, ssrf.h).
- **Entry point used by the daemon:** `term_to_json(FILE*, Term*, DhallError*)`
  (serialize.c) after parse + typecheck + normalize.
- **To re-vendor:** `cd ~/projects/dhall-c && git rev-parse --short HEAD`, then
  copy the above `src/*.c`/`*.h` into this directory.
