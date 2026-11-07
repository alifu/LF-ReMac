# LF-ReMac

## Rules

- **Always use graphify.** Before answering any question about the codebase (architecture, file relationships, where something lives, how components connect), query the knowledge graph first, e.g. `graphify query "CaptureViewModel"`. Read `graphify-out/GRAPH_REPORT.md` for an overview. Only fall back to grep/file reads for details the graph doesn't cover.
- Use the `graphify` skill for graph queries, paths, and explanations. Rebuild the graph after significant code changes so `graphify-out/` stays current.
