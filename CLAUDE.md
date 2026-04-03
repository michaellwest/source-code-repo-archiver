# CLAUDE.md — source-code-repo-archiver

## Project Overview

PowerShell 7+ script (`Invoke-RepoArchiver.ps1`) that bulk-clones all visible repositories from self-hosted GitLab (API v4) and Bitbucket Server (REST API 1.0) as bare mirrors.

## Key Files

- `Invoke-RepoArchiver.ps1` — Main script (single file)
- `repo-archiver-config.sample.json` — Sample config with credential placeholders
- `repo-archiver-config.json` — Actual config (gitignored, contains secrets)
- Output artifacts: `repo-archiver-manifest.json`, `repo-inventory-wip.json`, `repo-duplicates.json`

## Architecture

- Single-file script organized with `#region` sections: Configuration, Manifest, API Helpers, GitLab Enumeration, Bitbucket Enumeration, Clone, WIP Inventory, Duplicate Detection
- Entry point: `Invoke-RepoArchiver` function called at bottom of script
- Parallel cloning via `ForEach-Object -Parallel` with function serialization (`$using:`)
- A slim manifest lookup (SourceUpdatedAt + RootCommits only) is passed to parallel runspaces to reduce memory
- GitLab enumeration returns `@{ Repos = ...; Skipped = ... }` hashtable (not a flat list)
- Duplicate detection uses root commit SHA comparison across platforms
- Default branch is resolved post-clone via `git symbolic-ref HEAD` (not from API)
- Timestamps are normalized to UTC ISO-8601 on ingest (`ConvertTo-Iso8601`)
- Config is validated by `Test-ArchiverConfig` before any API calls

## Config

- **GitLab:** PAT auth via `PRIVATE-TOKEN` header (API and git operations)
- **Bitbucket Server (v7.21.3):** HTTP Access Token with `Bearer` auth (API and git operations)
- Git clone/fetch uses `-c http.extraHeader=` to pass auth tokens; each repo carries its `AuthHeader` from enumeration (not persisted to manifest)
- Defaults for missing keys are applied in `Read-ArchiverConfig`
- Config validation rejects placeholder tokens and malformed URLs

## Commands

```powershell
# Standard run
./Invoke-RepoArchiver.ps1

# Dry run (enumerate only)
./Invoke-RepoArchiver.ps1 -DryRun

# Incremental update (fetch --prune existing mirrors)
./Invoke-RepoArchiver.ps1 -Update

# Create working copies alongside bare mirrors (for AI code analysis)
./Invoke-RepoArchiver.ps1 -Checkout

# Update + checkout combined
./Invoke-RepoArchiver.ps1 -Update -Checkout

# Force re-clone unchanged repos
./Invoke-RepoArchiver.ps1 -Force

# Custom config path
./Invoke-RepoArchiver.ps1 -ConfigPath "C:\configs\archiver.json"
```

## Important Notes

- No test suite exists yet
- `repo-archiver-config.json` contains secrets — never commit it
- Bare mirror clones are kept as-is (no zip/compression)
- Script exits with code 1 on config errors or clone failures
- RunHistory in manifest is capped at 50 entries
