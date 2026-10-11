# Find running Windows processes whose executable has Go's embedded build-info
# header. No Go installation is required. Run PowerShell as Administrator for
# the broadest process visibility.

$ErrorActionPreference = "SilentlyContinue"

function Test-GoBuildInfo {
    param([Parameter(Mandatory = $true)][string]$Path)

    # The Go build-info magic is: FF 20 "Go buildinf:"
    [byte[]]$needle = @(
        0xFF, 0x20, 0x47, 0x6F, 0x20, 0x62, 0x75,
        0x69, 0x6C, 0x64, 0x69, 0x6E, 0x66, 0x3A
    )

    $stream = $null
    try {
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        )

        $chunkSize = 1MB
        $buffer = New-Object byte[] ($chunkSize + $needle.Length)
        $carry = 0

        while (($read = $stream.Read($buffer, $carry, $chunkSize)) -gt 0) {
            $total = $carry + $read
            for ($i = 0; $i -le $total - $needle.Length; $i++) {
                $match = $true
                for ($j = 0; $j -lt $needle.Length; $j++) {
                    if ($buffer[$i + $j] -ne $needle[$j]) {
                        $match = $false
                        break
                    }
                }
                if ($match) { return $true }
            }

            $carry = [Math]::Min($needle.Length - 1, $total)
            [Array]::Copy($buffer, $total - $carry, $buffer, 0, $carry)
        }
        return $false
    }
    catch {
        return $false
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

$found = 0
$cache = @{}

Get-CimInstance Win32_Process | ForEach-Object {
    $process = $_
    $path = $process.ExecutablePath
    if ([string]::IsNullOrWhiteSpace($path)) { return }

    if (-not $cache.ContainsKey($path)) {
        $cache[$path] = Test-GoBuildInfo -Path $path
    }

    if ($cache[$path]) {
        [PSCustomObject]@{
            PID        = $process.ProcessId
            Name       = $process.Name
            Detection  = "BUILDINFO"
            Executable = $path
        }
        $found++
    }
} | Format-Table -AutoSize

Write-Host "Candidates detected: $found"
Write-Host "BUILDINFO is a strong Go signature, not an absolute proof."
