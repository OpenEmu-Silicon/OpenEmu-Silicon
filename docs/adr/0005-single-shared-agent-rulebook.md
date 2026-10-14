# ADR-0005: One shared rulebook for agents, personal preferences kept local

## Status

Accepted. Supersedes ADR-0003.

## Context

ADR-0003 split agent instructions into `AGENTS.md`, `.claude/CLAUDE.md`, and `CONTEXT.md`. In practice `.claude/CLAUDE.md` filled up with the maintainer's own working preferences (how and when to verify, when to ask, what to say), and several of those contradicted `AGENTS.md`, the slash commands, and the git hook. Contributors who pointed an agent at the repo also inherited rules that were only ever one person's preferences. The result was a lot of ceremony (one PR per chore, a verify run after every edit, an approval question before every build) and no single place that said what the rules actually were.

## Decision

- `AGENTS.md` is the only shared rulebook: project facts and neutral advice for contributors and their agents.
- `.claude/CLAUDE.md` contains only a pointer to `AGENTS.md` and `CONTEXT.md`. No rules are added there.
- `CONTEXT.md` stays the domain glossary.
- Personal working preferences live in `CLAUDE.local.md` and `.claude/settings.local.json`, both gitignored.
- Maintainer-only workflows (releases, progress reports, triage) are kept outside the repo.
- The maintainer may push docs, scripts, chores, and tiny code fixes straight to `main`. CI builds direct pushes to `main` as well as pull requests. Everything else goes through a pull request.

## Consequences

**Easier:** one place to read and update; contributors get guidance without the maintainer's preferences; fewer pull requests for trivial changes.

**Harder:** personal rules are not versioned with the repo, so a new machine or worktree needs a copy of `CLAUDE.local.md`.
