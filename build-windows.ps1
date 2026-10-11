param(
    [string]$Architecture = "amd64",
    [string]$OutputRoot = "bin"
)

$ErrorActionPreference = "Stop"

$supportedTargets = @(go tool dist list)
$target = "windows/$Architecture"
if ($supportedTargets -notcontains $target) {
    throw "Unsupported target: $target. Run 'go tool dist list' to see supported targets."
}

$outputDir = Join-Path $OutputRoot (Join-Path "windows" $Architecture)
New-Item -ItemType Directory -Force -Path $outputDir | Out-Null

function Build-Go {
    param(
        [string]$Output,
        [string[]]$Arguments = @()
    )

    & go build -buildvcs=false @Arguments -o $Output .
    if ($LASTEXITCODE -ne 0) {
        throw "go build failed for $Output"
    }
}

Write-Host "Building Windows/$Architecture variants..."

$oldGoOs = $env:GOOS
$oldGoArch = $env:GOARCH
$oldCgo = $env:CGO_ENABLED
$env:GOOS = "windows"
$env:GOARCH = $Architecture

try {
    Build-Go (Join-Path $outputDir "go-default.exe")
    Build-Go (Join-Path $outputDir "go-trimpath.exe") @("-trimpath")
    Build-Go (Join-Path $outputDir "go-stripped.exe") @("-ldflags=-s -w")

    $env:CGO_ENABLED = "0"
    Build-Go (Join-Path $outputDir "go-nocgo.exe")
    Build-Go (Join-Path $outputDir "go-minimal.exe") @(
        "-trimpath",
        "-ldflags=-s -w -buildid="
    )
    Build-Go (Join-Path $outputDir "go-no-buildid.exe") @("-ldflags=-buildid=")
}
finally {
    if ($null -eq $oldGoOs) {
        Remove-Item Env:GOOS -ErrorAction SilentlyContinue
    }
    else {
        $env:GOOS = $oldGoOs
    }
    if ($null -eq $oldGoArch) {
        Remove-Item Env:GOARCH -ErrorAction SilentlyContinue
    }
    else {
        $env:GOARCH = $oldGoArch
    }
    if ($null -eq $oldCgo) {
        Remove-Item Env:CGO_ENABLED -ErrorAction SilentlyContinue
    }
    else {
        $env:CGO_ENABLED = $oldCgo
    }
}

Write-Host ""
Write-Host "Build complete:"
Get-ChildItem $outputDir | Select-Object -ExpandProperty FullName
