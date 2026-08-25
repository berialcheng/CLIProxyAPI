#Requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^v\d+\.\d+\.\d+$')]
    [string]$UpstreamTag,

    [ValidatePattern('^[A-Za-z0-9._/-]+$')]
    [string]$CandidateBranch,

    [switch]$CheckOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$MainBranch = 'main'
$LocalBranch = 'local/main'
$OriginRemote = 'origin'
$UpstreamRemote = 'upstream'

function Invoke-GitCapture {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $output = @(& git @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed with exit code $LASTEXITCODE`n$($output -join "`n")"
    }
    return ($output -join "`n").Trim()
}

function Invoke-GitCommand {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    & git @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
    }
}

function Assert-RefMissing {
    param(
        [Parameter(Mandatory)]
        [string]$RefName
    )

    & git show-ref --verify --quiet $RefName
    if ($LASTEXITCODE -eq 0) {
        throw "Ref already exists: $RefName"
    }
    if ($LASTEXITCODE -ne 1) {
        throw "Unable to inspect ref: $RefName"
    }
}

function Assert-NoGitOperation {
    foreach ($operationName in @('rebase-merge', 'rebase-apply', 'MERGE_HEAD', 'CHERRY_PICK_HEAD', 'REVERT_HEAD', 'BISECT_LOG')) {
        $operationPath = Invoke-GitCapture -Arguments @('rev-parse', '--git-path', $operationName)
        if (Test-Path -LiteralPath $operationPath) {
            throw "A Git operation is already in progress ($operationName at $operationPath). Finish or abort it before syncing."
        }
    }
}

foreach ($value in @($MainBranch, $LocalBranch, $CandidateBranch)) {
    if ($value -and $value.StartsWith('-', [StringComparison]::Ordinal)) {
        throw "Branch names must not start with '-': $value"
    }
}

if (-not $CandidateBranch) {
    $CandidateBranch = "sync/$UpstreamTag"
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
    Assert-NoGitOperation

    $status = Invoke-GitCapture -Arguments @('status', '--porcelain=v1', '--untracked-files=all')
    if ($status) {
        if ($CheckOnly) {
            Write-Warning 'The worktree is not clean. A real sync would stop here.'
        } else {
            throw "The worktree must be clean before syncing.`n$status"
        }
    }

    [void](Invoke-GitCapture -Arguments @('check-ref-format', '--branch', $MainBranch))
    [void](Invoke-GitCapture -Arguments @('check-ref-format', '--branch', $LocalBranch))
    [void](Invoke-GitCapture -Arguments @('check-ref-format', '--branch', $CandidateBranch))

    $fetchUrl = Invoke-GitCapture -Arguments @('remote', 'get-url', $UpstreamRemote)
    if ($fetchUrl -ne 'https://github.com/router-for-me/CLIProxyAPI.git') {
        throw "The $UpstreamRemote fetch URL must be the official repository; found '$fetchUrl'."
    }

    $originUrl = Invoke-GitCapture -Arguments @('remote', 'get-url', $OriginRemote)
    if ($originUrl -notin @(
        'git@github.com:berialcheng/CLIProxyAPI.git',
        'https://github.com/berialcheng/CLIProxyAPI.git'
    )) {
        throw "The $OriginRemote URL must be the berialcheng fork; found '$originUrl'."
    }

    $pushUrl = Invoke-GitCapture -Arguments @('remote', 'get-url', '--push', $UpstreamRemote)
    if ($pushUrl -ne 'no_push') {
        throw "The $UpstreamRemote push URL must be 'no_push'; found '$pushUrl'."
    }

    $expectedRefspec = "+refs/heads/$MainBranch`:refs/remotes/$UpstreamRemote/$MainBranch"
    $fetchRefspec = Invoke-GitCapture -Arguments @('config', '--local', '--get', "remote.$UpstreamRemote.fetch")
    if ($fetchRefspec -ne $expectedRefspec) {
        throw "The $UpstreamRemote fetch refspec must be '$expectedRefspec'; found '$fetchRefspec'."
    }

    $preflightMainHead = Invoke-GitCapture -Arguments @('rev-parse', "refs/heads/$MainBranch")
    $preflightOriginMain = Invoke-GitCapture -Arguments @('rev-parse', "refs/remotes/$OriginRemote/$MainBranch")
    if ($preflightMainHead -ne $preflightOriginMain) {
        throw "$MainBranch ($preflightMainHead) differs from $OriginRemote/$MainBranch ($preflightOriginMain). Resolve that divergence first."
    }

    $preflightLocalHead = Invoke-GitCapture -Arguments @('rev-parse', "refs/heads/$LocalBranch")
    $preflightOriginLocal = Invoke-GitCapture -Arguments @('rev-parse', "refs/remotes/$OriginRemote/$LocalBranch")
    if ($preflightLocalHead -ne $preflightOriginLocal) {
        throw "$LocalBranch ($preflightLocalHead) differs from $OriginRemote/$LocalBranch ($preflightOriginLocal). Resolve that divergence first."
    }

    Assert-RefMissing -RefName "refs/heads/$CandidateBranch"
    Assert-RefMissing -RefName "refs/remotes/$OriginRemote/$CandidateBranch"

    if ($CheckOnly) {
        $tagCommit = Invoke-GitCapture -Arguments @('rev-parse', "${UpstreamTag}^{commit}")
        $upstreamHead = Invoke-GitCapture -Arguments @('rev-parse', "refs/remotes/$UpstreamRemote/$MainBranch")
        if ($tagCommit -ne $upstreamHead) {
            throw "Cached $UpstreamRemote/$MainBranch is $upstreamHead, not $UpstreamTag ($tagCommit). Run a real sync only after the requested tag is the exact upstream head."
        }
        $oldBase = Invoke-GitCapture -Arguments @('merge-base', $LocalBranch, $MainBranch)
        & git merge-base --is-ancestor $oldBase $tagCommit
        if ($LASTEXITCODE -ne 0) {
            throw "The previous patch base $oldBase is not an ancestor of $UpstreamTag."
        }
        & git merge-base --is-ancestor $preflightMainHead $tagCommit
        if ($LASTEXITCODE -ne 0) {
            throw "$MainBranch cannot fast-forward from $preflightMainHead to $UpstreamTag ($tagCommit)."
        }
        $mergeCommits = Invoke-GitCapture -Arguments @('rev-list', '--merges', "$oldBase..$LocalBranch")
        if ($mergeCommits) {
            throw "$LocalBranch is not a linear patch stack. Merge commits found:`n$mergeCommits"
        }
        $oldRemote = $preflightOriginLocal

        [pscustomobject]@{
            Mode                 = 'CheckOnly'
            UpstreamTag          = $UpstreamTag
            TagCommit            = $tagCommit
            CachedUpstreamHead   = $upstreamHead
            TagMatchesUpstream   = ($tagCommit -eq $upstreamHead)
            CurrentPatchBase     = $oldBase
            ExpectedRemoteLocal  = $oldRemote
            CandidateBranch      = $CandidateBranch
        } | Format-List

        Write-Host 'No fetch, branch update, rebase, or push was performed.'
        return
    }

    Invoke-GitCommand -Arguments @('fetch', $UpstreamRemote, '--prune', '--no-tags')
    Invoke-GitCommand -Arguments @('fetch', $UpstreamRemote, '--no-tags', "refs/tags/${UpstreamTag}:refs/tags/${UpstreamTag}")
    Invoke-GitCommand -Arguments @('fetch', $OriginRemote, '--prune', '--no-tags')

    $tagCommit = Invoke-GitCapture -Arguments @('rev-parse', "${UpstreamTag}^{commit}")
    $upstreamHead = Invoke-GitCapture -Arguments @('rev-parse', "refs/remotes/$UpstreamRemote/$MainBranch")
    if ($tagCommit -ne $upstreamHead) {
        throw "$UpstreamRemote/$MainBranch is $upstreamHead, not the requested release $UpstreamTag ($tagCommit). Refusing an untagged or stale base."
    }

    $localMainHead = Invoke-GitCapture -Arguments @('rev-parse', "refs/heads/$MainBranch")
    $originMainHead = Invoke-GitCapture -Arguments @('rev-parse', "refs/remotes/$OriginRemote/$MainBranch")
    if ($localMainHead -ne $originMainHead) {
        throw "$MainBranch ($localMainHead) differs from $OriginRemote/$MainBranch ($originMainHead). Resolve that divergence first."
    }

    $localPatchHead = Invoke-GitCapture -Arguments @('rev-parse', "refs/heads/$LocalBranch")
    $oldRemote = Invoke-GitCapture -Arguments @('rev-parse', "refs/remotes/$OriginRemote/$LocalBranch")
    if ($localPatchHead -ne $oldRemote) {
        throw "$LocalBranch ($localPatchHead) differs from $OriginRemote/$LocalBranch ($oldRemote). Resolve that divergence first."
    }

    Assert-RefMissing -RefName "refs/heads/$CandidateBranch"
    Assert-RefMissing -RefName "refs/remotes/$OriginRemote/$CandidateBranch"

    $oldBase = Invoke-GitCapture -Arguments @('merge-base', $LocalBranch, $MainBranch)
    & git merge-base --is-ancestor $oldBase $tagCommit
    if ($LASTEXITCODE -ne 0) {
        throw "The previous patch base $oldBase is not an ancestor of $UpstreamTag. Refusing a rewritten upstream history."
    }
    & git merge-base --is-ancestor $localMainHead $tagCommit
    if ($LASTEXITCODE -ne 0) {
        throw "$MainBranch cannot fast-forward from $localMainHead to $UpstreamTag ($tagCommit)."
    }

    $mergeCommits = Invoke-GitCapture -Arguments @('rev-list', '--merges', "$oldBase..$LocalBranch")
    if ($mergeCommits) {
        throw "$LocalBranch is not a linear patch stack. Merge commits found:`n$mergeCommits"
    }

    Invoke-GitCommand -Arguments @('switch', '-c', $CandidateBranch, $localPatchHead)
    try {
        Invoke-GitCommand -Arguments @('rebase', '--onto', $tagCommit, $oldBase)
    } catch {
        Write-Warning "Rebase stopped on $CandidateBranch. Resolve conflicts and run 'git rebase --continue', or abort with 'git rebase --abort'."
        throw
    }

    Write-Host "`nPatch-series comparison:"
    Invoke-GitCommand -Arguments @('range-diff', "$oldBase..$localPatchHead", "$tagCommit..$CandidateBranch")
    Invoke-GitCommand -Arguments @('diff', '--check', "$tagCommit...$CandidateBranch")

    $candidateHead = Invoke-GitCapture -Arguments @('rev-parse', $CandidateBranch)
    Invoke-GitCommand -Arguments @('update-ref', "refs/heads/$MainBranch", $tagCommit, $localMainHead)
    $mainLease = "--force-with-lease=refs/heads/$MainBranch`:$originMainHead"
    $localLease = "--force-with-lease=refs/heads/$LocalBranch`:$oldRemote"

    Write-Host "`nCandidate prepared successfully. No remote push was performed."
    [pscustomobject]@{
        CandidateBranch     = $CandidateBranch
        CandidateCommit     = $candidateHead
        UpstreamRelease     = $UpstreamTag
        NewMainCommit       = $tagCommit
        ExpectedRemoteMain  = $originMainHead
        PreviousPatchBase   = $oldBase
        ExpectedRemoteLocal = $oldRemote
    } | Format-List

    Write-Host 'After tests and review, atomically promote the exact reviewed commits:'
    Write-Host "git push --atomic $mainLease $localLease $OriginRemote ${tagCommit}:refs/heads/$MainBranch ${candidateHead}:refs/heads/$LocalBranch"
    Write-Host "git update-ref refs/heads/$LocalBranch $candidateHead $localPatchHead"
    Write-Host "git switch $LocalBranch"
} finally {
    Pop-Location
}
