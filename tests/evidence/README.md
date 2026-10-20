# tests/evidence — recorded gate output

These files are **recordings**, written by the qemu gates (`cp … $EVID/…`), not fixtures: no gate
compares them. They exist so a reader can see what a run actually printed.

**REDACTED FOR PUBLICATION.** Every recorded occurrence of a developer-machine home directory was
rewritten to `$HOME/` (the tree's own convention for sibling paths), and the private endpoint that one
live-lane fixture was recorded from appears as `<host>:<port>`. The recorded *content* is otherwise
unchanged: the stores, the verdicts, the refusals and the hashes are what the run produced.

**THE REDACTION IS NOT DURABLE, and that is worth knowing rather than discovering.** These files are
re-written by the gates that own them, so the next run of `tests/qemu-agent-observe.sh` (or the other four
gates that write here) will re-record the absolute path from whatever machine runs it. Making it durable
means redacting at the capture site — one helper applied at the `cp … $EVID` boundary in each of those
gates — which is a deliberate change to the qemu harnesses, not something to bolt on while publishing.
Until then: **re-redact before any future publication**, and prefer a publication step that redacts over
trusting the working tree.
