#Requires -Version 7.0

[CmdletBinding()]
param(
    [switch]$Release,

    [switch]$FullTest,

    [switch]$CheckOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$expectedGoVersion = 'go1.26.5'

function Invoke-CommandChecked {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
    }
}

function Invoke-CommandCapture {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $output = @(& $FilePath @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath $($Arguments -join ' ') failed with exit code $LASTEXITCODE`n$($output -join "`n")"
    }
    return ($output -join "`n").Trim()
}

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$rootOutput = @(& git -C $repositoryRoot rev-parse --show-toplevel 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw "The script directory is not inside the expected Git repository: $repositoryRoot`n$($rootOutput -join "`n")"
}
$detectedRoot = [IO.Path]::GetFullPath(($rootOutput -join "`n").Trim())
if (-not $detectedRoot.Equals($repositoryRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Script root mismatch: expected '$repositoryRoot', Git reported '$detectedRoot'."
}
Push-Location -LiteralPath $repositoryRoot
try {
    $status = Invoke-CommandCapture -FilePath 'git' -Arguments @('status', '--porcelain=v1', '--untracked-files=all')
    if ($status) {
        if ($CheckOnly) {
            Write-Warning 'The worktree is not clean. A real build would stop here.'
        } else {
            throw "The worktree must be clean before building.`n$status"
        }
    }

    $goCommand = (Get-Command go -CommandType Application -ErrorAction Stop).Source
    $gofmtCommand = Join-Path (Split-Path -Parent $goCommand) 'gofmt.exe'
    if (-not (Test-Path -LiteralPath $gofmtCommand -PathType Leaf)) {
        throw "gofmt.exe was not found beside the selected Go toolchain: $gofmtCommand"
    }

    $goVersion = Invoke-CommandCapture -FilePath $goCommand -Arguments @('env', 'GOVERSION')
    if ($goVersion -ne $expectedGoVersion) {
        throw "Expected $expectedGoVersion, found $goVersion. Update the script pin intentionally before building."
    }

    $commit = Invoke-CommandCapture -FilePath 'git' -Arguments @('rev-parse', 'HEAD')
    $shortCommit = Invoke-CommandCapture -FilePath 'git' -Arguments @('rev-parse', '--short=8', 'HEAD')
    $commitEpochText = Invoke-CommandCapture -FilePath 'git' -Arguments @('show', '-s', '--format=%ct', 'HEAD')
    $commitEpoch = [long]::Parse($commitEpochText, [Globalization.CultureInfo]::InvariantCulture)
    $buildDate = [DateTimeOffset]::FromUnixTimeSeconds($commitEpoch).UtcDateTime.ToString(
        'yyyy-MM-ddTHH:mm:ssZ',
        [Globalization.CultureInfo]::InvariantCulture
    )

    $releaseTags = @(& git tag --points-at HEAD --list 'v*-local.*')
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to inspect release tags pointing at HEAD.'
    }
    $releaseTags = @($releaseTags | Where-Object { $_ -match '^v\d+\.\d+\.\d+-local\.\d+$' })
    $exactTag = if ($releaseTags.Count -eq 1) { [string]$releaseTags[0] } else { '' }

    if ($Release) {
        if ($releaseTags.Count -ne 1) {
            throw "Release builds require exactly one vX.Y.Z-local.N tag at HEAD; found $($releaseTags.Count)."
        }
        $tagType = Invoke-CommandCapture -FilePath 'git' -Arguments @('cat-file', '-t', "refs/tags/$exactTag")
        if ($tagType -ne 'tag') {
            throw "Release tag $exactTag must be annotated; object type is '$tagType'."
        }
        $version = $exactTag.Substring(1)
        $artifactVersion = $version
    } else {
        $version = "dev-$shortCommit"
        $artifactVersion = "candidate-$shortCommit"
    }

    $mainCommit = Invoke-CommandCapture -FilePath 'git' -Arguments @('rev-parse', 'main')
    $upstreamBase = Invoke-CommandCapture -FilePath 'git' -Arguments @('merge-base', 'HEAD', 'main')
    $upstreamTags = @(& git tag --points-at $upstreamBase --list 'v*')
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to inspect the upstream base tag.'
    }
    $upstreamTags = @($upstreamTags | Where-Object { $_ -match '^v\d+\.\d+\.\d+$' })
    $upstreamBaseTag = if ($upstreamTags.Count -eq 1) { [string]$upstreamTags[0] } else { $null }
    if ($Release) {
        if ($upstreamTags.Count -ne 1) {
            throw "Release builds require exactly one vX.Y.Z tag at the upstream base; found $($upstreamTags.Count)."
        }
        $expectedUpstreamTag = $exactTag -replace '-local\.\d+$', ''
        if ($upstreamBaseTag -ne $expectedUpstreamTag) {
            throw "Local release tag $exactTag does not match upstream base tag $upstreamBaseTag."
        }
    }
    $patchCommitsText = Invoke-CommandCapture -FilePath 'git' -Arguments @('rev-list', '--reverse', "$upstreamBase..HEAD")
    $patchCommits = if ($patchCommitsText) { @($patchCommitsText -split "`r?`n") } else { @() }

    $testPackages = if ($FullTest) {
        @('./...')
    } else {
        @(
            './internal/config',
            './internal/registry',
            './internal/client/codex/models',
            './internal/watcher',
            './cmd/server'
        )
    }

    $binRoot = Join-Path $repositoryRoot 'bin'
    $OutputRoot = Join-Path $binRoot 'local-release'
    foreach ($pathToCheck in @($binRoot, $OutputRoot)) {
        if (Test-Path -LiteralPath $pathToCheck) {
            $pathItem = Get-Item -LiteralPath $pathToCheck -Force
            if (($pathItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Build output path must not traverse a reparse point: $pathToCheck"
            }
        }
    }

    $repositoryFullPath = [IO.Path]::GetFullPath($repositoryRoot)
    $outputFullPath = [IO.Path]::GetFullPath($OutputRoot)
    $relativeOutputPath = [IO.Path]::GetRelativePath($repositoryFullPath, $outputFullPath)
    if ([IO.Path]::IsPathRooted($relativeOutputPath) -or $relativeOutputPath.StartsWith('..')) {
        throw "Build output escaped the repository: $OutputRoot"
    }
    $ignoreProbe = (Join-Path $relativeOutputPath '.gitignore-probe').Replace('\', '/')
    & git check-ignore --quiet --no-index -- $ignoreProbe
    if ($LASTEXITCODE -ne 0) {
        throw "OutputRoot is inside the repository but is not ignored by Git: $OutputRoot"
    }

    [pscustomobject]@{
        Mode            = if ($Release) { 'Release' } else { 'Candidate' }
        CheckOnly       = [bool]$CheckOnly
        Version         = $version
        Commit          = $commit
        UpstreamBase    = $upstreamBase
        MainCommit      = $mainCommit
        GoVersion       = $goVersion
        GOOS            = 'windows'
        GOARCH          = 'amd64'
        CGOEnabled      = '0'
        BuildDate       = $buildDate
        TestPackages    = ($testPackages -join ' ')
        OutputRoot      = $OutputRoot
    } | Format-List

    if ($CheckOnly) {
        Write-Host 'No tests, build, archive creation, or file writes were performed.'
        return
    }

    $oldCgo = [Environment]::GetEnvironmentVariable('CGO_ENABLED', 'Process')
    $oldGoos = [Environment]::GetEnvironmentVariable('GOOS', 'Process')
    $oldGoarch = [Environment]::GetEnvironmentVariable('GOARCH', 'Process')
    $oldSourceDateEpoch = [Environment]::GetEnvironmentVariable('SOURCE_DATE_EPOCH', 'Process')
    $env:CGO_ENABLED = '0'
    $env:GOOS = 'windows'
    $env:GOARCH = 'amd64'
    $env:SOURCE_DATE_EPOCH = [string]$commitEpoch
    try {
        Invoke-CommandChecked -FilePath 'git' -Arguments @('diff', '--check', "$upstreamBase...HEAD")

        $goFilesText = Invoke-CommandCapture -FilePath 'git' -Arguments @(
            'diff', '--name-only', '--diff-filter=ACMR', "$upstreamBase...HEAD", '--', '*.go'
        )
        $goFiles = @($goFilesText -split "`r?`n" | Where-Object { $_ })
        $unformatted = [Collections.Generic.List[string]]::new()
        for ($offset = 0; $offset -lt $goFiles.Count; $offset += 100) {
            $last = [Math]::Min($offset + 99, $goFiles.Count - 1)
            $batch = @($goFiles[$offset..$last])
            $batchOutput = @(& $gofmtCommand -l @batch)
            if ($LASTEXITCODE -ne 0) {
                throw "gofmt failed while checking locally changed Go files at offset $offset."
            }
            foreach ($path in $batchOutput) {
                if ($path) {
                    $unformatted.Add([string]$path)
                }
            }
        }
        if ($unformatted.Count -gt 0) {
            throw "Locally changed Go files require gofmt:`n$($unformatted -join "`n")"
        }

        Invoke-CommandChecked -FilePath $goCommand -Arguments (@('test', '-mod=readonly', '-count=1') + $testPackages)

        $artifactDirectory = Join-Path $OutputRoot $artifactVersion
        if (Test-Path -LiteralPath $artifactDirectory) {
            throw "Refusing to overwrite existing artifact directory: $artifactDirectory"
        }

        foreach ($pathToCreate in @($binRoot, $OutputRoot)) {
            if (-not (Test-Path -LiteralPath $pathToCreate)) {
                New-Item -ItemType Directory -Path $pathToCreate -Force:$false | Out-Null
            }
            $pathItem = Get-Item -LiteralPath $pathToCreate -Force
            if (($pathItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Build output path became a reparse point: $pathToCreate"
            }
        }

        $stagingDirectory = Join-Path $OutputRoot ('.staging-{0}-{1}' -f $artifactVersion, [guid]::NewGuid().ToString('N'))
        $packageDirectory = Join-Path $stagingDirectory 'package'
        New-Item -ItemType Directory -Path $packageDirectory -Force:$false | Out-Null

        $exePath = Join-Path $packageDirectory 'cli-proxy-api.exe'
        $ldflags = "-s -w -X main.Version=$version -X main.Commit=$shortCommit -X main.BuildDate=$buildDate"
        Invoke-CommandChecked -FilePath $goCommand -Arguments @(
            'build',
            '-mod=readonly',
            '-trimpath',
            '-buildvcs=true',
            "-ldflags=$ldflags",
            '-o',
            $exePath,
            './cmd/server/'
        )

        foreach ($publicFile in @('LICENSE', 'README.md', 'README_CN.md')) {
            Copy-Item -LiteralPath (Join-Path $repositoryRoot $publicFile) -Destination $packageDirectory
        }

        $exeHash = (Get-FileHash -LiteralPath $exePath -Algorithm SHA256).Hash
        $moduleInfo = @(& $goCommand version -m $exePath)
        if ($LASTEXITCODE -ne 0) {
            throw 'go version -m failed for the built executable.'
        }
    $moduleInfoText = $moduleInfo -join "`n"
    foreach ($requiredValue in @(
        $goVersion,
        'CGO_ENABLED=0',
        'GOARCH=amd64',
        'GOOS=windows',
        "vcs.revision=$commit",
        'vcs.modified=false',
        '-trimpath=true'
    )) {
        if (-not $moduleInfoText.Contains($requiredValue, [StringComparison]::Ordinal)) {
            throw "Built executable metadata is missing required value: $requiredValue"
        }
    }
    if ($moduleInfoText.Contains('vcs.modified=true', [StringComparison]::Ordinal)) {
        throw 'Built executable reports vcs.modified=true.'
    }
    $normalizedModuleInfo = @($moduleInfo | Select-Object -Skip 1 | ForEach-Object { ([string]$_).Trim() })

    $buildInfo = [ordered]@{
        schema_version = 1
        version = $version
        release_tag = if ($Release) { $exactTag } else { $null }
        commit = $commit
        short_commit = $shortCommit
        upstream_base = $upstreamBase
        upstream_base_tag = $upstreamBaseTag
        main_commit = $mainCommit
        patch_commits = $patchCommits
        commit_timestamp_utc = $buildDate
        go_version = $goVersion
        goos = 'windows'
        goarch = 'amd64'
        cgo_enabled = '0'
        trimpath = $true
        ldflags = $ldflags
        tests = $testPackages
        executable_sha256 = $exeHash
        go_version_m = $normalizedModuleInfo
    }

    $buildInfoPath = Join-Path $packageDirectory 'BUILDINFO.json'
    $buildInfo | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $buildInfoPath -Encoding utf8NoBOM

    $stableTimestamp = [DateTimeOffset]::FromUnixTimeSeconds($commitEpoch).UtcDateTime
    Get-ChildItem -LiteralPath $packageDirectory -File | ForEach-Object {
        $_.LastWriteTimeUtc = $stableTimestamp
    }

    $packageWhitelist = @('cli-proxy-api.exe', 'LICENSE', 'README.md', 'README_CN.md', 'BUILDINFO.json')
    $actualPackageFiles = @(Get-ChildItem -LiteralPath $packageDirectory -File | Select-Object -ExpandProperty Name)
    $packageDifference = @(Compare-Object -ReferenceObject $packageWhitelist -DifferenceObject $actualPackageFiles)
    if ($packageDifference.Count -ne 0) {
        throw "Package contents differ from the strict whitelist:`n$($packageDifference | Out-String)"
    }

    Add-Type -AssemblyName System.IO.Compression
    $archiveName = "CLIProxyAPI_${artifactVersion}_windows_amd64.zip"
    $archivePath = Join-Path $stagingDirectory $archiveName
    $archiveStream = [IO.File]::Open($archivePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $archive = $null
    try {
        $archive = [IO.Compression.ZipArchive]::new(
            $archiveStream,
            [IO.Compression.ZipArchiveMode]::Create,
            $false
        )
        foreach ($fileName in $packageWhitelist) {
            $entry = $archive.CreateEntry($fileName, [IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = [DateTimeOffset]$stableTimestamp
            $sourceStream = [IO.File]::OpenRead((Join-Path $packageDirectory $fileName))
            $entryStream = $entry.Open()
            try {
                $sourceStream.CopyTo($entryStream)
            } finally {
                $entryStream.Dispose()
                $sourceStream.Dispose()
            }
        }
    } finally {
        if ($archive) {
            $archive.Dispose()
        }
        $archiveStream.Dispose()
    }

    $readStream = [IO.File]::OpenRead($archivePath)
    $readArchive = $null
    try {
        $readArchive = [IO.Compression.ZipArchive]::new(
            $readStream,
            [IO.Compression.ZipArchiveMode]::Read,
            $false
        )
        $archiveEntries = @($readArchive.Entries | Select-Object -ExpandProperty FullName)
        $archiveDifference = @(Compare-Object -ReferenceObject $packageWhitelist -DifferenceObject $archiveEntries)
        if ($archiveDifference.Count -ne 0) {
            throw "Archive contents differ from the strict whitelist:`n$($archiveDifference | Out-String)"
        }
    } finally {
        if ($readArchive) {
            $readArchive.Dispose()
        }
        $readStream.Dispose()
    }
    $archiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash

    $checksumsPath = Join-Path $stagingDirectory 'checksums.txt'
    @(
        "$exeHash  package/cli-proxy-api.exe",
        "$archiveHash  $archiveName"
    ) | Set-Content -LiteralPath $checksumsPath -Encoding ascii

    $forbidden = Get-ChildItem -LiteralPath $packageDirectory -Recurse -Force | Where-Object {
        $_.Name -in @('config.yaml', '.env', 'auths', 'auth')
    }
    if ($forbidden) {
        throw "Forbidden runtime configuration or auth material entered the package: $($forbidden.FullName -join ', ')"
    }

    $postBuildStatus = Invoke-CommandCapture -FilePath 'git' -Arguments @('status', '--porcelain=v1', '--untracked-files=all')
    if ($postBuildStatus) {
        throw "The build changed the tracked worktree:`n$postBuildStatus"
    }

        Move-Item -LiteralPath $stagingDirectory -Destination $artifactDirectory
        $finalArchivePath = Join-Path $artifactDirectory $archiveName
        Write-Host "Build completed: $finalArchivePath"
        Write-Host "Executable SHA256: $exeHash"
        Write-Host "Archive SHA256:    $archiveHash"
    } finally {
        [Environment]::SetEnvironmentVariable('CGO_ENABLED', $oldCgo, 'Process')
        [Environment]::SetEnvironmentVariable('GOOS', $oldGoos, 'Process')
        [Environment]::SetEnvironmentVariable('GOARCH', $oldGoarch, 'Process')
        [Environment]::SetEnvironmentVariable('SOURCE_DATE_EPOCH', $oldSourceDateEpoch, 'Process')
    }
} finally {
    Pop-Location
}
