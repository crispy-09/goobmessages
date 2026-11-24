# Installs or updates Goob Messages for Windows 10/11 (x64) from the latest GitHub release.
# Run it again any time to update. In PowerShell:
#
#   irm https://raw.githubusercontent.com/crispy-09/goobmessages/main/scripts/install.ps1 | iex
#
# Downloads the setup .exe, checks it against the release's SHA256SUMS.txt, closes a running copy, runs the installer
# silently (Windows asks for admin permission) and starts the app. The builds aren't code-signed.
#
# Environment options (set before running, e.g. $env:GOOB_VERSION = '0.2.1'):
#   GOOB_VERSION    install that release instead of the latest
#   GOOB_FORCE=1    reinstall even if that version is already installed
#   GOOB_NO_LAUNCH=1  don't start the app afterwards
#   GOOB_GITHUB_TOKEN  token for the GitHub API lookup, only needed if you hit its rate limit

# Wrapped in a script block so a partial download can't run half an install, and errors never close your
# PowerShell window (no `exit`).
& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is very slow with the progress bar on PowerShell 5
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $Repo = 'crispy-09/goobmessages'
    $UninstKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\GoobMessagesGoobMessages'   # Wails NSIS default
    $Headers = @{ 'User-Agent' = 'goobmessages-installer'; 'Accept' = 'application/vnd.github+json' }
    if ($env:GOOB_GITHUB_TOKEN) { $Headers['Authorization'] = "Bearer $env:GOOB_GITHUB_TOKEN" }

    function Say($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

    if (-not [Environment]::Is64BitOperatingSystem) { throw 'Goob Messages needs 64-bit Windows.' }

    $version = $env:GOOB_VERSION
    if ($version) {
        $version = $version -replace '^desktop-v', '' -replace '^v', ''
    } else {
        $releases = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases?per_page=50" -Headers $Headers
        $rel = $releases | Where-Object { $_.tag_name -match '^desktop-v\d+\.\d+\.\d+$' -and -not $_.prerelease -and -not $_.draft } |
            Select-Object -First 1
        if (-not $rel) { throw 'Could not find the latest Windows release.' }
        $version = $rel.tag_name.Substring('desktop-v'.Length)
    }
    $tag = "desktop-v$version"

    # What's installed now (the installer may have written to the user or the machine hive).
    $installed = $null
    foreach ($hive in 'HKCU:', 'HKLM:') {
        $p = Get-ItemProperty -Path "$hive\$UninstKey" -ErrorAction SilentlyContinue
        if ($p) { $installed = $p; break }
    }
    $current = if ($installed) { $installed.DisplayVersion } else { $null }
    if ($current -eq $version.Split('-')[0] -and $env:GOOB_FORCE -ne '1') {
        Say "Goob Messages $version is already installed and up to date."
        return
    }
    if ($current) { Say "Updating Goob Messages $current -> $version" } else { Say "Installing Goob Messages $version" }

    $name = "goobmessages-$version-windows-amd64-setup.exe"
    $base = "https://github.com/$Repo/releases/download/$tag"
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('goobmessages-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $setup = Join-Path $tmp $name
        $sums = Join-Path $tmp 'SHA256SUMS.txt'
        Say "Downloading $tag"
        Invoke-WebRequest -Uri "$base/$name" -OutFile $setup -UseBasicParsing -Headers @{ 'User-Agent' = $Headers['User-Agent'] }
        Invoke-WebRequest -Uri "$base/SHA256SUMS.txt" -OutFile $sums -UseBasicParsing -Headers @{ 'User-Agent' = $Headers['User-Agent'] }

        $expected = $null
        foreach ($line in Get-Content -Path $sums) {
            $parts = $line.Trim() -split '\s+', 2
            if ($parts.Count -eq 2 -and ($parts[1].TrimStart('*') -replace '.*[\\/]', '') -eq $name) { $expected = $parts[0]; break }
        }
        if (-not $expected) { throw "No checksum for $name in release $tag; not installing an unverified download." }
        $actual = (Get-FileHash -Path $setup -Algorithm SHA256).Hash
        if ($actual -ne $expected) { throw "Checksum mismatch for $name (expected $expected, got $actual)." }
        Say 'Checksum OK'

        $running = Get-Process -Name 'goobmessages' -ErrorAction SilentlyContinue
        if ($running) {
            Say 'Closing the running app'
            $running | Stop-Process -Force
            $running | Wait-Process -Timeout 15 -ErrorAction SilentlyContinue
        }

        Say 'Running the installer (Windows may ask for permission)'
        $proc = Start-Process -FilePath $setup -ArgumentList '/S' -Wait -PassThru
        if ($proc.ExitCode -ne 0) { throw "The installer failed (exit code $($proc.ExitCode))." }

        $exe = $null
        foreach ($hive in 'HKCU:', 'HKLM:') {
            $p = Get-ItemProperty -Path "$hive\$UninstKey" -ErrorAction SilentlyContinue
            if ($p -and $p.DisplayIcon) { $exe = $p.DisplayIcon.Trim('"'); break }
        }
        Say "Installed Goob Messages $version$(if ($exe) { " ($exe)" })"
        if ($exe -and (Test-Path $exe) -and $env:GOOB_NO_LAUNCH -ne '1') { Start-Process -FilePath $exe }
        if (-not $current) {
            Write-Host 'Sign in with the Google account Google Messages uses on your phone, then tap the emoji shown.'
        }
    } finally {
        Remove-Item -Recurse -Force -Path $tmp -ErrorAction SilentlyContinue
    }
}
