# CLAUDE.md — source-code-repo-archiver

## Project Overview

PowerShell 7+ script (`Invoke-RepoArchiver.ps1`) that bulk-clones all visible repositories from self-hosted GitLab (API v4) and Bitbucket Server (REST API 1.0) as bare mirrors.

## Key Files

- `Invoke-RepoArchiver.ps1` — Main script (single file, ~780 lines)
- `repo-archiver-config.sample.json` — Sample config with credential placeholders
- `repo-archiver-config.json` — Actual config (gitignored, contains secrets)
- Output artifacts: `repo-archiver-manifest.json`, `repo-inventory-wip.json`, `repo-duplicates.json`

## Architecture

- Single-file script organized with `#region` sections: Configuration, Manifest, API Helpers, GitLab Enumeration, Bitbucket Enumeration, Clone, WIP Inventory, Duplicate Detection
- Entry point: `Invoke-RepoArchiver` function called at bottom of script
- Parallel cloning via `ForEach-Object -Parallel` with function serialization (`$using:`)
- GitLab enumeration returns `@{ Repos = ...; Skipped = ... }` hashtable (not a flat list)
- Duplicate detection uses root commit SHA comparison across platforms

## Config

- **GitLab:** PAT auth via `PRIVATE-TOKEN` header
- **Bitbucket Server (v7.21.3):** HTTP Access Token with `Bearer` auth
- Defaults for missing keys are applied in `Read-ArchiverConfig`

## Commands

```powershell
# Standard run
./Invoke-RepoArchiver.ps1

# Dry run (enumerate only)
./Invoke-RepoArchiver.ps1 -DryRun

# Force re-clone unchanged repos
./Invoke-RepoArchiver.ps1 -Force

# Custom config path
./Invoke-RepoArchiver.ps1 -ConfigPath "C:\configs\archiver.json"
```

## Important Notes

- No test suite exists yet
- `repo-archiver-config.json` contains secrets — never commit it
- Bare mirror clones are kept as-is (no zip/compression)
