---
description: Token efficiency rules — keep context lean, prefer CLI and text tools over MCP
---

- **MCP tools are scoped to subagents.** Don't use browser/computer/preview/comms tools directly — spawn the appropriate agent from `~/.claude/agents/`.
- **Prefer text-based verification** over screenshots. See KB: `token-efficient-verification.md`.
- **Start fresh conversations** every 10-15 turns. Don't sprawl.
- **Convert documents to markdown** before ingesting. Never feed raw PDFs.
- **CLI over MCP** — prefer `gh`, `xcodebuild`, etc. directly; MCP adds schema overhead on both sides.
