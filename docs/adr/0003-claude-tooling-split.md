# ADR-0003: Three-file split for AI agent instructions

## Status

Superseded by [ADR-0005](0005-single-shared-agent-rulebook.md)

## Context

As Claude Code sessions accumulated over this project, the `.claude/CLAUDE.md` file grew to 566 lines mixing behavioral rules (what Claude should do), reference facts (file layout, build commands, license tables), and domain vocabulary. Every token in CLAUDE.md is read at the start of every Claude Code session — "always-on" context. At that size it was consuming a significant portion of the smart-zone context before any work began.

The risk: large, mixed always-on context degrades session quality. It also duplicates content already in `AGENTS.md` and in the slash commands, creating drift.

Separately, there was no shared domain glossary. Terms like `core`, `plugin`, `oecoreplugin`, `broker`, `appcast`, `libretro bridge`, and `hardcore mode` were used inconsistently across commits, issue titles, and PR descriptions.

## Decision

Agent instructions are split across three files with a clear purpose boundary:

| File | Purpose | Audience |
|---|---|---|
| `AGENTS.md` | Canonical project facts: build commands, branch/PR rules, file layout, supported cores, license, what NOT to do. Authoritative. | All agents and human contributors |
| `.claude/CLAUDE.md` | Claude-specific behavioral rules only: hard rules, verification workflow, autonomy guidance, issue-hygiene reminders, memory discipline. Target: under 200 lines. | Claude Code sessions only |
| `CONTEXT.md` | Domain glossary: terms used distinctively in this codebase with precise definitions. | All agents and human contributors |

**Rule:** If content belongs in `AGENTS.md` (a fact about the project) or `CONTEXT.md` (a vocabulary term), it must not be duplicated in `CLAUDE.md`. `CLAUDE.md` grows only when a new behavioral pattern is discovered — not when project facts change.

If `.claude/CLAUDE.md` ever exceeds ~200 lines, something has been added that belongs in one of the other two files.

## Consequences

**Easier:**
- Each session starts with ~1,000 words of always-on context instead of ~3,500
- Project facts live in one place (`AGENTS.md`) — when something changes, only one file needs updating
- Vocabulary questions have a single authoritative answer (`CONTEXT.md`)
- `/grill-with-docs` and `/improve-codebase-architecture` skills (which read `CONTEXT.md` and `docs/adr/`) now have accurate inputs

**Harder:**
- Three files to maintain instead of one
- Contributors (human and AI) must know which file to update for a given kind of change

**Maintenance rule:**
- New behavioral pattern discovered (how Claude should act) → `CLAUDE.md`
- New project fact (what the project does, how it's built) → `AGENTS.md`
- New domain term or renamed concept → `CONTEXT.md`
- Non-obvious architectural decision → new `docs/adr/NNNN-*.md`
