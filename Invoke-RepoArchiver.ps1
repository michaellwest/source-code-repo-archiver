#Requires -Version 7.0
<#
.SYNOPSIS
    Bulk clone and archive all visible repositories from self-hosted GitLab and Bitbucket Server.

.DESCRIPTION
    Invoke-RepoArchiver enumerates all repositories visible to the configured accounts on a
    self-hosted GitLab instance and Bitbucket Server/Data Center, clones them as bare mirrors,
    and organises output by Platform/Namespace/Repo.git.

    Features:
      - Parallel cloning with configurable throttle
      - Retry logic on transient failures
      - Dry-run mode (enumerate only)
      - JSON manifest for progress tracking and incremental updates

.PARAMETER ConfigPath
    Path to the JSON configuration file. Defaults to ./repo-archiver-config.json.

.PARAMETER DryRun
    Enumerate repositories and update manifest without cloning.

.PARAMETER Force
    Re-clone repos even if they haven't changed since last run.

.EXAMPLE
    ./Invoke-RepoArchiver.ps1
    ./Invoke-RepoArchiver.ps1 -ConfigPath "C:\configs\archiver.json" -DryRun
    ./Invoke-RepoArchiver.ps1 -Force

.NOTES
    Author  : Generated for repo archival project
    Requires: git, PowerShell 7+
    License : MIT
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'repo-archiver-config.json'),

    [Parameter()]
    [switch]$DryRun,

    [Parameter()]
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region ── Configuration ──────────────────────────────────────────────────────

function Read-ArchiverConfig {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        Write-Error "Config file not found at '$Path'. Run with -WhatIf to generate a template."
        return $null
    }

    $raw = Get-Content -Path $Path -Raw | ConvertFrom-Json -AsHashtable
    # Defaults
    $defaults = @{
        OutputDirectory    = (Join-Path $PSScriptRoot 'RepoArchive')
        ManifestPath       = (Join-Path $PSScriptRoot 'repo-archiver-manifest.json')
        MaxParallel        = 4
        RetryCount         = 3
        RetryDelaySeconds  = 5
        GitLab             = $null
        Bitbucket          = $null
    }

    foreach ($key in $defaults.Keys) {
        if (-not $raw.ContainsKey($key)) {
            $raw[$key] = $defaults[$key]
        }
    }
    return $raw
}

function New-TemplateConfig {
    param([string]$Path)

    $template = [ordered]@{
        OutputDirectory    = './RepoArchive'
        ManifestPath       = './repo-archiver-manifest.json'
        MaxParallel        = 4
        RetryCount         = 3
        RetryDelaySeconds  = 5
        GitLab             = [ordered]@{
            BaseUrl          = 'https://gitlab.yourcompany.com'
            PersonalAccessToken = 'glpat-xxxxxxxxxxxxxxxxxxxx'
            Enabled          = $true
        }
        Bitbucket          = [ordered]@{
            BaseUrl             = 'https://bitbucket.yourcompany.com'
            HttpAccessToken     = 'xxxxxxxxxxxxxxxxxxxx'
            Enabled             = $true
        }
    }

    $template | ConvertTo-Json -Depth 5 | Set-Content -Path $Path -Encoding utf8
    Write-Host "Template config written to '$Path'. Edit it with your credentials and run again." -ForegroundColor Cyan
}

function Test-ArchiverConfig {
    param([hashtable]$Config)

    $errors = [System.Collections.Generic.List[string]]::new()

    if ($Config.GitLab -and $Config.GitLab.Enabled) {
        $gl = $Config.GitLab
        if (-not $gl.BaseUrl -or $gl.BaseUrl -notmatch '^https?://') {
            $errors.Add("GitLab.BaseUrl must start with http:// or https:// (got '$($gl.BaseUrl)')")
        }
        if (-not $gl.PersonalAccessToken -or $gl.PersonalAccessToken -eq 'glpat-xxxxxxxxxxxxxxxxxxxx') {
            $errors.Add("GitLab.PersonalAccessToken is missing or still set to the placeholder value")
        }
    }

    if ($Config.Bitbucket -and $Config.Bitbucket.Enabled) {
        $bb = $Config.Bitbucket
        if (-not $bb.BaseUrl -or $bb.BaseUrl -notmatch '^https?://') {
            $errors.Add("Bitbucket.BaseUrl must start with http:// or https:// (got '$($bb.BaseUrl)')")
        }
        if (-not $bb.HttpAccessToken -or $bb.HttpAccessToken -eq 'xxxxxxxxxxxxxxxxxxxx') {
            $errors.Add("Bitbucket.HttpAccessToken is missing or still set to the placeholder value")
        }
    }

    if ($errors.Count -gt 0) {
        foreach ($e in $errors) {
            Write-Error $e
        }
        return $false
    }
    return $true
}

#endregion

#region ── Manifest ───────────────────────────────────────────────────────────

function Read-Manifest {
    param([string]$Path)

    if (Test-Path $Path) {
        return (Get-Content -Path $Path -Raw | ConvertFrom-Json -AsHashtable)
    }
    return @{ Repositories = @{}; LastRunUtc = $null; RunHistory = @() }
}

function Save-Manifest {
    param([hashtable]$Manifest, [string]$Path)

    $Manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $Path -Encoding utf8
}

#endregion

#region ── API Helpers ────────────────────────────────────────────────────────

function Invoke-ApiWithRetry {
    param(
        [string]$Uri,
        [hashtable]$Headers,
        [int]$RetryCount = 3,
        [int]$RetryDelay = 5
    )

    for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
        try {
            $response = Invoke-RestMethod -Uri $Uri -Headers $Headers -Method Get `
                -ResponseHeadersVariable 'respHeaders' -StatusCodeVariable 'statusCode' `
                -FollowRelLink:$false
            return @{ Body = $response; Headers = $respHeaders; StatusCode = $statusCode }
        }
        catch {
            $status = $_.Exception.Response.StatusCode.value__
            if ($attempt -eq $RetryCount -or $status -in @(401, 403, 404)) {
                throw
            }
            Write-Warning "  Request to '$Uri' failed (HTTP $status). Retry $attempt/$RetryCount in ${RetryDelay}s..."
            Start-Sleep -Seconds $RetryDelay
        }
    }
}

function ConvertTo-Iso8601 {
    param([object]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) {
        return ([DateTimeOffset]::Parse($Value)).ToUniversalTime().ToString('o')
    }
    if ($Value -is [long] -or $Value -is [int]) {
        return ([DateTimeOffset]::FromUnixTimeMilliseconds($Value)).ToString('o')
    }
    return $Value.ToString()
}

#endregion

#region ── GitLab Enumeration ─────────────────────────────────────────────────

function Get-GitLabRepositories {
    param([hashtable]$GitLabConfig, [int]$RetryCount, [int]$RetryDelay)

    $baseUrl = $GitLabConfig.BaseUrl.TrimEnd('/')
    $headers = @{ 'PRIVATE-TOKEN' = $GitLabConfig.PersonalAccessToken }
    $repos   = [System.Collections.Generic.List[hashtable]]::new()
    $skipped = [System.Collections.Generic.List[hashtable]]::new()
    $page    = 1
    $perPage = 100

    # GitLab access levels: 10=Guest, 20=Reporter, 30=Developer, 40=Maintainer, 50=Owner
    # Clone requires Developer (30) or higher via project/group membership,
    # OR the project is public/internal with repo access enabled.
    $minCloneLevel = 20  # Reporter can clone; Guest (10) cannot

    Write-Host "`n[GitLab] Enumerating projects from $baseUrl ..." -ForegroundColor Magenta

    do {
        # Remove simple=true so we get the permissions block
        $uri = "$baseUrl/api/v4/projects?membership=false&per_page=$perPage&page=$page&order_by=id&sort=asc"
        $result = Invoke-ApiWithRetry -Uri $uri -Headers $headers -RetryCount $RetryCount -RetryDelay $RetryDelay
        $projects = $result.Body

        if ($null -eq $projects -or $projects.Count -eq 0) { break }

        foreach ($p in $projects) {
            # Determine effective access level from project or group membership
            $projectAccess = $p.permissions.project_access.access_level
            $groupAccess   = $p.permissions.group_access.access_level
            $accessLevel   = [math]::Max([int]($projectAccess ?? 0), [int]($groupAccess ?? 0))

            # Public/internal repos are cloneable even without explicit membership
            $isPublicOrInternal = $p.visibility -in @('public', 'internal')

            $canClone = $isPublicOrInternal -or ($accessLevel -ge $minCloneLevel)

            if ($canClone) {
                $repos.Add(@{
                    Platform      = 'GitLab'
                    Id            = "gitlab:$($p.id)"
                    FullName      = $p.path_with_namespace
                    CloneUrl      = $p.http_url_to_repo
                    DefaultBranch = $p.default_branch
                    UpdatedAt     = ConvertTo-Iso8601 $p.last_activity_at
                    Description   = $p.description
                    AccessLevel   = $accessLevel
                    Visibility    = $p.visibility
                })
            }
            else {
                $skipped.Add(@{
                    Id           = "gitlab:$($p.id)"
                    FullName     = $p.path_with_namespace
                    AccessLevel  = $accessLevel
                    Visibility   = $p.visibility
                    Reason       = "Insufficient access (level $accessLevel, need $minCloneLevel+)"
                })
            }
        }

        Write-Host "  Fetched page $page ($($projects.Count) projects, cloneable: $($repos.Count), skipped: $($skipped.Count))" -ForegroundColor DarkGray
        $page++
    } while ($projects.Count -eq $perPage)

    if ($skipped.Count -gt 0) {
        Write-Host "[GitLab] Skipped $($skipped.Count) projects (insufficient clone access):" -ForegroundColor Yellow
        foreach ($s in $skipped) {
            Write-Host "  NOACCESS  $($s.FullName) (level=$($s.AccessLevel), visibility=$($s.Visibility))" -ForegroundColor DarkYellow
        }
    }

    Write-Host "[GitLab] Found $($repos.Count) cloneable projects (skipped $($skipped.Count))." -ForegroundColor Green
    return , @{ Repos = $repos; Skipped = $skipped }
}

#endregion

#region ── Bitbucket Server Enumeration ───────────────────────────────────────

function Get-BitbucketRepositories {
    param([hashtable]$BitbucketConfig, [int]$RetryCount, [int]$RetryDelay)

    $baseUrl = $BitbucketConfig.BaseUrl.TrimEnd('/')
    $headers = @{ Authorization = "Bearer $($BitbucketConfig.HttpAccessToken)" }
    $repos   = [System.Collections.Generic.List[hashtable]]::new()

    Write-Host "`n[Bitbucket] Enumerating projects from $baseUrl ..." -ForegroundColor Magenta

    # Step 1: Get all projects (paged via start parameter)
    $projects = [System.Collections.Generic.List[hashtable]]::new()
    $start    = 0
    $limit    = 100

    do {
        $uri    = "$baseUrl/rest/api/1.0/projects?start=$start&limit=$limit"
        $result = Invoke-ApiWithRetry -Uri $uri -Headers $headers -RetryCount $RetryCount -RetryDelay $RetryDelay
        $page   = $result.Body

        foreach ($p in $page.values) {
            $projects.Add(@{ Key = $p.key; Name = $p.name })
        }

        Write-Host "  Fetched projects (start=$start, count=$($page.values.Count), running total: $($projects.Count))" -ForegroundColor DarkGray
        $isLast = [bool]($page.isLastPage)
        $start  = if ($isLast) { 0 } else { [int]$page.nextPageStart }
    } while (-not $isLast)

    Write-Host "[Bitbucket] Found $($projects.Count) projects." -ForegroundColor Green

    # Step 2: Get repos per project
    foreach ($proj in $projects) {
        Write-Host "  Enumerating repos in project '$($proj.Key)' ..." -ForegroundColor DarkGray
        $start = 0

        do {
            $uri    = "$baseUrl/rest/api/1.0/projects/$($proj.Key)/repos?start=$start&limit=$limit"
            $result = Invoke-ApiWithRetry -Uri $uri -Headers $headers -RetryCount $RetryCount -RetryDelay $RetryDelay
            $page   = $result.Body

            foreach ($r in $page.values) {
                # Build HTTPS clone URL from the clone links array
                $cloneLink = ($r.links.clone | Where-Object { $_.name -eq 'http' }).href

                # Fallback: construct it manually if not present
                if (-not $cloneLink) {
                    $cloneLink = "$baseUrl/scm/$($proj.Key.ToLower())/$($r.slug).git"
                }

                # Default branch: Bitbucket Server doesn't return it in the list endpoint;
                # use the repo's default branch endpoint or fall back to $null
                $defaultBranch = $null
                try {
                    $branchUri = "$baseUrl/rest/api/1.0/projects/$($proj.Key)/repos/$($r.slug)/default-branch"
                    $brResult  = Invoke-ApiWithRetry -Uri $branchUri -Headers $headers -RetryCount 1 -RetryDelay 0
                    $defaultBranch = $brResult.Body.displayId
                }
                catch {
                    # Non-fatal; repo may be empty or branch endpoint unavailable
                }

                # Updated timestamp: not always present in Bitbucket Server repo list response
                $updatedAt = $null
                if ($r.PSObject.Properties['updatedDate']) {
                    $updatedAt = ConvertTo-Iso8601 $r.updatedDate
                }

                $repos.Add(@{
                    Platform      = 'Bitbucket'
                    Id            = "bitbucket:$($proj.Key)/$($r.slug)"
                    FullName      = "$($proj.Key)/$($r.slug)"
                    CloneUrl      = $cloneLink
                    DefaultBranch = $defaultBranch
                    UpdatedAt     = $updatedAt
                    Description   = if ($r.PSObject.Properties['description']) { $r.description } else { $null }
                })
            }

            $isLast = [bool]($page.isLastPage)
            $start  = if ($isLast) { 0 } else { [int]$page.nextPageStart }
        } while (-not $isLast)
    }

    Write-Host "[Bitbucket] Found $($repos.Count) total repositories." -ForegroundColor Green
    return $repos
}

#endregion

#region ── Clone ───────────────────────────────────────────────────────────────

function Invoke-RepoClone {
    param(
        [hashtable]$Repo,
        [string]$OutputDirectory,
        [hashtable]$Manifest,
        [int]$RetryCount,
        [int]$RetryDelay,
        [switch]$Force,
        [int]$TotalCount = 0
    )

    $platform  = $Repo.Platform
    $fullName  = $Repo.FullName
    $repoId    = $Repo.Id
    $cloneUrl  = $Repo.CloneUrl
    $updatedAt = $Repo.UpdatedAt
    $progress  = if ($TotalCount -gt 0 -and $Repo._Index) { "[$($Repo._Index)/$TotalCount] " } else { '' }

    # Build output path: OutputDir/Platform/namespace/repo.git
    $segments  = $fullName -split '/'
    $repoName  = $segments[-1]
    $namespace = ($segments[0..($segments.Length - 2)]) -join [IO.Path]::DirectorySeparatorChar
    $repoDir   = Join-Path $OutputDirectory $platform $namespace "$repoName.git"

    # Check manifest for skip logic
    $existing = $Manifest.Repositories[$repoId]
    if ($existing -and -not $Force) {
        if ($existing.SourceUpdatedAt -eq $updatedAt -and (Test-Path $repoDir)) {
            Write-Host "  ${progress}SKIP  $platform/$fullName (unchanged)" -ForegroundColor DarkGray
            return @{
                Status      = 'Skipped'
                RepoId      = $repoId
                RootCommits = if ($existing.RootCommits) { $existing.RootCommits } else { @() }
            }
        }
    }

    # Ensure parent directory exists
    $parentDir = Split-Path $repoDir -Parent
    if (-not (Test-Path $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }

    # Remove existing clone if re-cloning
    if (Test-Path $repoDir) {
        Remove-Item -Path $repoDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    $cloneSuccess = $false
    for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
        try {
            Write-Host "  ${progress}CLONE $platform/$fullName (attempt $attempt) ..." -ForegroundColor Yellow
            $stderrLog = Join-Path ([IO.Path]::GetTempPath()) "git_err_$([Guid]::NewGuid().ToString('N')).log"
            $gitArgs = @('clone', '--mirror', $cloneUrl, $repoDir)
            $proc = Start-Process -FilePath 'git' -ArgumentList $gitArgs -Wait -PassThru `
                -RedirectStandardError $stderrLog -NoNewWindow

            if ($proc.ExitCode -ne 0) {
                $gitError = if (Test-Path $stderrLog) { Get-Content $stderrLog -Raw } else { 'unknown error' }
                $exitCode = $proc.ExitCode

                $hint = switch ($exitCode) {
                    128 {
                        if ($gitError -match 'Authentication|403|401') { 'Token may be expired or lack read permissions' }
                        elseif ($gitError -match 'not found|does not exist|404') { 'Repository may have been deleted or moved' }
                        elseif ($gitError -match 'SSL|certificate') { 'SSL certificate validation failed; check GIT_SSL_NO_VERIFY or CA bundle' }
                        elseif ($gitError -match 'already exists') { 'Target directory collision; stale temp directory' }
                        else { 'Fatal git error; see stderr below' }
                    }
                    default { "git exited with code $exitCode" }
                }
                throw "git clone exit code $exitCode — $hint`nstderr: $($gitError.Trim())"
            }
            $cloneSuccess = $true
            break
        }
        catch {
            if ($attempt -eq $RetryCount) {
                Write-Warning "  ${progress}FAIL  $platform/$fullName after $RetryCount attempts:`n    $_"
                return @{ Status = 'Failed'; RepoId = $repoId; Error = $_.ToString(); RootCommits = @() }
            }
            Write-Warning "  Clone failed (attempt $attempt/$RetryCount). Retrying in ${RetryDelay}s ..."
            Start-Sleep -Seconds $RetryDelay
        }
        finally {
            if (Test-Path $stderrLog -ErrorAction SilentlyContinue) {
                Remove-Item $stderrLog -Force -ErrorAction SilentlyContinue
            }
            if (-not $cloneSuccess -and (Test-Path $repoDir)) {
                Remove-Item -Path $repoDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # ── Extract root commit SHAs for duplicate detection ──
    $rootCommits = @()
    try {
        $gitOut = & git -C $repoDir rev-list --max-parents=0 --all 2>$null
        if ($LASTEXITCODE -eq 0 -and $gitOut) {
            $rootCommits = @($gitOut | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        }
    }
    catch {
        Write-Warning "  WARN  Could not extract root commits for $platform/$fullName"
    }

    # Calculate size of the bare repo
    $repoBytes = (Get-ChildItem -Path $repoDir -Recurse -File | Measure-Object -Property Length -Sum).Sum

    Write-Host "  ${progress}OK    $platform/$fullName -> $repoDir ($([math]::Round($repoBytes / 1MB, 1)) MB)" -ForegroundColor Green

    return @{
        Status      = 'Archived'
        RepoId      = $repoId
        RepoPath    = $repoDir
        RepoBytes   = $repoBytes
        RootCommits = $rootCommits
    }
}

#endregion

#region ── WIP / Inventory File ───────────────────────────────────────────────

function Save-WipInventory {
    param(
        [hashtable]$Manifest,
        [System.Collections.Generic.List[hashtable]]$AllRepos,
        [System.Collections.Generic.List[hashtable]]$InaccessibleRepos,
        [string]$OutputDirectory
    )

    $wipPath = Join-Path $OutputDirectory 'repo-inventory-wip.json'
    $entries = [System.Collections.Generic.List[ordered]]::new()

    foreach ($repo in $AllRepos) {
        $manifestEntry = $Manifest.Repositories[$repo.Id]
        $entry = [ordered]@{
            Platform      = $repo.Platform
            RepoId        = $repo.Id
            FullName      = $repo.FullName
            CloneUrl      = $repo.CloneUrl
            DefaultBranch = $repo.DefaultBranch
            Description   = $repo.Description
            SourceUpdatedAt = $repo.UpdatedAt
            Status        = if ($manifestEntry) { $manifestEntry.LastStatus } else { 'Pending' }
            RepoPath      = if ($manifestEntry) { $manifestEntry.RepoPath } else { $null }
            RepoBytes     = if ($manifestEntry) { $manifestEntry.RepoBytes } else { $null }
            RootCommits   = if ($manifestEntry -and $manifestEntry.RootCommits) { $manifestEntry.RootCommits } else { @() }
            LastArchivedUtc = if ($manifestEntry) { $manifestEntry.LastArchivedUtc } else { $null }
        }
        $entries.Add($entry)
    }

    $inaccessibleEntries = [System.Collections.Generic.List[ordered]]::new()
    if ($InaccessibleRepos) {
        foreach ($skip in $InaccessibleRepos) {
            $inaccessibleEntries.Add([ordered]@{
                Platform    = 'GitLab'
                RepoId      = $skip.Id
                FullName    = $skip.FullName
                AccessLevel = $skip.AccessLevel
                Visibility  = $skip.Visibility
                Reason      = $skip.Reason
                Status      = 'Inaccessible'
            })
        }
    }

    $wip = [ordered]@{
        GeneratedUtc        = [DateTimeOffset]::UtcNow.ToString('o')
        TotalCloneable      = $entries.Count
        TotalInaccessible   = $inaccessibleEntries.Count
        Repositories        = $entries
        InaccessibleRepos   = $inaccessibleEntries
    }

    $wip | ConvertTo-Json -Depth 10 | Set-Content -Path $wipPath -Encoding utf8
    Write-Host "[WIP] Inventory written to $wipPath ($($entries.Count) cloneable, $($inaccessibleEntries.Count) inaccessible)" -ForegroundColor Cyan
    return $wipPath
}

#endregion

#region ── Duplicate Detection ────────────────────────────────────────────────

function Find-DuplicateRepos {
    param([hashtable]$Manifest)

    # Build lookup: rootCommitSHA -> list of repo IDs that share it
    $rootIndex = @{}

    foreach ($kvp in $Manifest.Repositories.GetEnumerator()) {
        $repoId = $kvp.Key
        $entry  = $kvp.Value
        $roots  = $entry.RootCommits
        if (-not $roots -or $roots.Count -eq 0) { continue }

        foreach ($sha in $roots) {
            if (-not $rootIndex.ContainsKey($sha)) {
                $rootIndex[$sha] = [System.Collections.Generic.List[string]]::new()
            }
            $rootIndex[$sha].Add($repoId)
        }
    }

    # Find groups where repos from different platforms share a root commit
    $duplicateGroups = [System.Collections.Generic.List[ordered]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($kvp in $rootIndex.GetEnumerator()) {
        $sha     = $kvp.Key
        $repoIds = $kvp.Value
        if ($repoIds.Count -lt 2) { continue }

        # Check if at least two different platforms are represented
        $platforms = $repoIds | ForEach-Object {
            $Manifest.Repositories[$_].Platform
        } | Select-Object -Unique

        if ($platforms.Count -lt 2) { continue }

        # Create a stable group key to avoid reporting the same pair twice
        $groupKey = ($repoIds | Sort-Object) -join '|'
        if (-not $seen.Add($groupKey)) { continue }

        $members = $repoIds | ForEach-Object {
            $e = $Manifest.Repositories[$_]
            [ordered]@{
                RepoId   = $_
                Platform = $e.Platform
                FullName = $e.FullName
                CloneUrl = $e.CloneUrl
            }
        }

        $duplicateGroups.Add([ordered]@{
            SharedRootCommit = $sha
            Repositories     = @($members)
        })
    }

    return $duplicateGroups
}

#endregion

function Invoke-RepoArchiver {
    $script:exitCode = 0
    $startTime = [DateTimeOffset]::UtcNow

    Write-Host '╔══════════════════════════════════════════════╗' -ForegroundColor White
    Write-Host '║         Invoke-RepoArchiver v1.0.0          ║' -ForegroundColor White
    Write-Host '╚══════════════════════════════════════════════╝' -ForegroundColor White

    # ── Load config ──
    if (-not (Test-Path $ConfigPath)) {
        Write-Warning "Config not found at '$ConfigPath'. Generating template..."
        New-TemplateConfig -Path $ConfigPath
        $script:exitCode = 1
        return
    }

    $config = Read-ArchiverConfig -Path $ConfigPath
    if ($null -eq $config) { $script:exitCode = 1; return }

    # ── Validate config ──
    if (-not (Test-ArchiverConfig -Config $config)) {
        $script:exitCode = 1
        return
    }

    # ── Validate git ──
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Error "git executable not found in PATH. Install git and try again."
        return
    }

    # ── Load manifest ──
    $manifest = Read-Manifest -Path $config.ManifestPath

    # ── Enumerate repos ──
    $allRepos       = [System.Collections.Generic.List[hashtable]]::new()
    $inaccessible   = [System.Collections.Generic.List[hashtable]]::new()

    if ($config.GitLab -and $config.GitLab.Enabled) {
        $glResult = Get-GitLabRepositories -GitLabConfig $config.GitLab `
            -RetryCount $config.RetryCount -RetryDelay $config.RetryDelaySeconds
        if ($glResult) {
            if ($glResult.Repos -and $glResult.Repos.Count -gt 0) {
                $allRepos.AddRange([hashtable[]]@($glResult.Repos))
            }
            if ($glResult.Skipped -and $glResult.Skipped.Count -gt 0) {
                $inaccessible.AddRange([hashtable[]]@($glResult.Skipped))
            }
        }
    }

    if ($config.Bitbucket -and $config.Bitbucket.Enabled) {
        $bbRepos = Get-BitbucketRepositories -BitbucketConfig $config.Bitbucket `
            -RetryCount $config.RetryCount -RetryDelay $config.RetryDelaySeconds
        if ($bbRepos) { $allRepos.AddRange([hashtable[]]@($bbRepos)) }
    }

    Write-Host "`nTotal cloneable repositories: $($allRepos.Count)" -ForegroundColor White
    if ($inaccessible.Count -gt 0) {
        Write-Host "Inaccessible (view-only):     $($inaccessible.Count)" -ForegroundColor Yellow
    }

    # Update manifest with discovered repos (metadata always refreshed)
    foreach ($repo in $allRepos) {
        if (-not $manifest.Repositories.ContainsKey($repo.Id)) {
            $manifest.Repositories[$repo.Id] = @{}
        }
        $entry = $manifest.Repositories[$repo.Id]
        $entry.Platform       = $repo.Platform
        $entry.FullName       = $repo.FullName
        $entry.CloneUrl       = $repo.CloneUrl
        $entry.DefaultBranch  = $repo.DefaultBranch
        $entry.Description    = $repo.Description
        $entry.SourceUpdatedAt = $repo.UpdatedAt
        $entry.LastEnumeratedUtc = [DateTimeOffset]::UtcNow.ToString('o')
    }

    # Track inaccessible repos in manifest
    if (-not $manifest.ContainsKey('Inaccessible')) {
        $manifest.Inaccessible = @{}
    }
    foreach ($skip in $inaccessible) {
        $manifest.Inaccessible[$skip.Id] = @{
            FullName    = $skip.FullName
            AccessLevel = $skip.AccessLevel
            Visibility  = $skip.Visibility
            Reason      = $skip.Reason
            LastSeenUtc = [DateTimeOffset]::UtcNow.ToString('o')
        }
    }

    if ($DryRun) {
        Write-Host "`n[DryRun] Enumeration complete. No cloning performed." -ForegroundColor Yellow
        $manifest.LastRunUtc = [DateTimeOffset]::UtcNow.ToString('o')
        $manifest.RunHistory += @{
            TimestampUtc = [DateTimeOffset]::UtcNow.ToString('o')
            Mode         = 'DryRun'
            ReposFound   = $allRepos.Count
            Inaccessible = $inaccessible.Count
        }
        if ($manifest.RunHistory.Count -gt 50) {
            $manifest.RunHistory = @($manifest.RunHistory | Select-Object -Last 50)
        }
        Save-Manifest -Manifest $manifest -Path $config.ManifestPath
        Write-Host "Manifest saved to $($config.ManifestPath)" -ForegroundColor Green
        return
    }

    # ── Ensure output directory ──
    if (-not (Test-Path $config.OutputDirectory)) {
        New-Item -ItemType Directory -Path $config.OutputDirectory -Force | Out-Null
    }

    # ── Clone in parallel ──
    $totalCount = $allRepos.Count
    for ($i = 0; $i -lt $allRepos.Count; $i++) {
        $allRepos[$i]._Index = $i + 1
    }

    Write-Host "`nCloning ($($config.MaxParallel) parallel) ..." -ForegroundColor White

    # Serialize function body as string — $using: can't pass function references
    $repoCloneDef = ${function:Invoke-RepoClone}.ToString()

    $results = $allRepos | ForEach-Object -ThrottleLimit $config.MaxParallel -Parallel {
        # Reconstitute function inside the parallel runspace
        ${function:Invoke-RepoClone} = $using:repoCloneDef

        $repo            = $_
        $outputDir       = $using:config.OutputDirectory
        $manifest        = $using:manifest
        $retryCount      = $using:config.RetryCount
        $retryDelay      = $using:config.RetryDelaySeconds
        $forceSwitch     = $using:Force
        $total           = $using:totalCount

        Invoke-RepoClone -Repo $repo -OutputDirectory $outputDir `
            -Manifest $manifest -RetryCount $retryCount -RetryDelay $retryDelay `
            -Force:$forceSwitch -TotalCount $total
    }

    # ── Process results & update manifest ──
    $archived = 0; $skipped = 0; $failed = 0

    foreach ($r in $results) {
        if ($null -eq $r) { continue }

        switch ($r.Status) {
            'Archived' {
                $archived++
                $entry = $manifest.Repositories[$r.RepoId]
                $entry.LastArchivedUtc = [DateTimeOffset]::UtcNow.ToString('o')
                $entry.RepoPath        = $r.RepoPath
                $entry.RepoBytes       = $r.RepoBytes
                $entry.LastStatus      = 'Archived'
                $entry.RootCommits     = $r.RootCommits
            }
            'Skipped'  {
                $skipped++
                if ($r.RootCommits -and $r.RootCommits.Count -gt 0) {
                    $manifest.Repositories[$r.RepoId].RootCommits = $r.RootCommits
                }
            }
            'Failed'   {
                $failed++
                if ($manifest.Repositories.ContainsKey($r.RepoId)) {
                    $manifest.Repositories[$r.RepoId].LastStatus = "Failed: $($r.Error)"
                }
            }
        }
    }

    if ($failed -gt 0) { $script:exitCode = 1 }

    # ── Save manifest ──
    $manifest.LastRunUtc = [DateTimeOffset]::UtcNow.ToString('o')
    $manifest.RunHistory += @{
        TimestampUtc = [DateTimeOffset]::UtcNow.ToString('o')
        Mode         = 'Full'
        ReposFound   = $allRepos.Count
        Archived     = $archived
        Skipped      = $skipped
        Failed       = $failed
        DurationSec  = [math]::Round(([DateTimeOffset]::UtcNow - $startTime).TotalSeconds, 1)
    }
    if ($manifest.RunHistory.Count -gt 50) {
        $manifest.RunHistory = @($manifest.RunHistory | Select-Object -Last 50)
    }
    Save-Manifest -Manifest $manifest -Path $config.ManifestPath

    # ── WIP Inventory ──
    Save-WipInventory -Manifest $manifest -AllRepos $allRepos -InaccessibleRepos $inaccessible -OutputDirectory $config.OutputDirectory

    # ── Duplicate Detection ──
    $duplicates = Find-DuplicateRepos -Manifest $manifest
    if ($duplicates.Count -gt 0) {
        $dupePath = Join-Path $config.OutputDirectory 'repo-duplicates.json'
        [ordered]@{
            GeneratedUtc    = [DateTimeOffset]::UtcNow.ToString('o')
            DuplicateGroups = @($duplicates)
        } | ConvertTo-Json -Depth 10 | Set-Content -Path $dupePath -Encoding utf8

        Write-Host "`n[Duplicates] Found $($duplicates.Count) cross-platform duplicate group(s):" -ForegroundColor Yellow
        foreach ($group in $duplicates) {
            $names = ($group.Repositories | ForEach-Object { "$($_.Platform)/$($_.FullName)" }) -join '  <->  '
            Write-Host "  Root $($group.SharedRootCommit.Substring(0,10))... : $names" -ForegroundColor Yellow
        }
        Write-Host "  Full details: $dupePath" -ForegroundColor Yellow
    }
    else {
        Write-Host "`n[Duplicates] No cross-platform duplicates detected." -ForegroundColor DarkGray
    }

    # ── Summary ──
    $duration = [math]::Round(([DateTimeOffset]::UtcNow - $startTime).TotalSeconds, 1)
    Write-Host "`n── Run Summary ───────────────────────────────" -ForegroundColor White
    Write-Host "  Discovered    : $($allRepos.Count)" -ForegroundColor White
    Write-Host "  Inaccessible  : $($inaccessible.Count)" -ForegroundColor $(if ($inaccessible.Count -gt 0) { 'Yellow' } else { 'DarkGray' })
    Write-Host "  Archived      : $archived" -ForegroundColor Green
    Write-Host "  Skipped       : $skipped" -ForegroundColor DarkGray
    Write-Host "  Failed        : $failed" -ForegroundColor $(if ($failed -gt 0) { 'Red' } else { 'DarkGray' })
    Write-Host "  Duplicates    : $($duplicates.Count) group(s)" -ForegroundColor $(if ($duplicates.Count -gt 0) { 'Yellow' } else { 'DarkGray' })
    Write-Host "  Duration    : ${duration}s" -ForegroundColor White
    Write-Host "  Manifest    : $($config.ManifestPath)" -ForegroundColor White
    Write-Host "──────────────────────────────────────────────`n" -ForegroundColor White
}

# ── Entry Point ──
Invoke-RepoArchiver
exit $script:exitCode
