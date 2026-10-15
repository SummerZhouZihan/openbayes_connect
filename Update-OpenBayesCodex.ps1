param(
    [string]$SshCommand,
    [string]$ConfigPath = (Join-Path $env:USERPROFILE '.ssh\config'),
    [switch]$SkipRemoteCheck,
    [string]$LogPath = (Join-Path $PSScriptRoot 'last-run.log')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:RunLogActive = $false

function Write-RunLog {
    param(
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][string]$Message,
        [ConsoleColor]$Color
    )

    if (-not $script:RunLogActive) { return }
    $line = '[{0:yyyy-MM-dd HH:mm:ss.fff}] [{1}] {2}' -f (Get-Date), $Stage, $Message
    if ($PSBoundParameters.ContainsKey('Color')) {
        Write-Host $line -ForegroundColor $Color
    } else {
        Write-Host $line
    }
}

function Remove-TranscriptHostApplication {
    param([Parameter(Mandatory)][string]$Path)

    if (-not [IO.File]::Exists($Path)) { return }
    $safeLines = @([IO.File]::ReadAllLines($Path) | Where-Object { $_ -notmatch '^(?i:Host Application):' })
    [IO.File]::WriteAllLines($Path, $safeLines, [Text.UTF8Encoding]::new($false))
}

function Get-OpenBayesPort {
    param([string]$SshCommand)

    $invalidCommand = 'Invalid OpenBayes SSH command.'
    if ([string]::IsNullOrWhiteSpace($SshCommand)) { throw $invalidCommand }

    $normalized = [Net.WebUtility]::HtmlDecode($SshCommand)
    $normalized = $normalized.Replace([char]0x00A0, ' ').Replace('\@', '@').Trim()
    $match = [regex]::Match(
        $normalized,
        '^(?i:ssh(?:\.exe)?)\s+root@ssh\.openbayes\.com\s+-p\s*([0-9]{1,5})$'
    )
    if (-not $match.Success) { throw $invalidCommand }

    $port = [int]$match.Groups[1].Value
    if ($port -lt 1 -or $port -gt 65535) { throw $invalidCommand }
    return $port
}

function Set-OpenBayesSshPort {
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][int]$NewPort
    )

    if ($NewPort -lt 1 -or $NewPort -gt 65535) {
        throw 'Invalid SSH port.'
    }
    if (-not [IO.File]::Exists($ConfigPath)) {
        throw 'SSH config file does not exist. Run Setup-OpenBayesCodex.ps1 first.'
    }

    $config = [IO.File]::ReadAllText($ConfigPath)
    $lines = [regex]::Matches($config, '(?m)^[^\r\n]*(?:\r\n|\n|$)')
    $aliasIndexes = [Collections.Generic.List[int]]::new()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i].Value -replace '\r?\n$', ''
        if ($line -match '^\s*Host(?:\s*=\s*|\s+)openbayes-codex\s*$') {
            $aliasIndexes.Add($i)
        }
    }
    if ($aliasIndexes.Count -ne 1) {
        throw 'SSH config must contain exactly one Host openbayes-codex block.'
    }

    $portLines = [Collections.Generic.List[object]]::new()
    for ($i = $aliasIndexes[0] + 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i].Value -replace '\r?\n$', ''
        if ($line -match '^\s*(?:Host|Match)(?:\s+|\s*=\s*)') { break }
        if ($line -match '^\s*Port(?:\s+|\s*=\s*)') {
            $portLines.Add([pscustomobject]@{ Line = $lines[$i]; Text = $line })
        }
    }
    if ($portLines.Count -ne 1) {
        throw 'Host openbayes-codex must contain exactly one Port directive.'
    }
    $portMatch = [regex]::Match($portLines[0].Text, '^(\s*Port(?:\s*=\s*|\s+))([0-9]+)([ \t]*(?:#.*)?)$', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $portMatch.Success) { throw 'Host openbayes-codex contains an invalid Port.' }

    $oldPortText = $portMatch.Groups[2].Value
    $oldPortValue = 0
    if (-not [int]::TryParse($oldPortText, [ref]$oldPortValue) -or $oldPortValue -lt 1 -or $oldPortValue -gt 65535) {
        throw 'Host openbayes-codex contains an invalid Port.'
    }
    if ($oldPortValue -eq $NewPort) {
        return [pscustomobject]@{ OldPort = $oldPortValue; NewPort = $NewPort; BackupPath = $null; Changed = $false }
    }

    $number = $portMatch.Groups[2]
    $offset = $portLines[0].Line.Index + $number.Index
    $updated = $config.Remove($offset, $number.Length).Insert($offset, [string]$NewPort)
    $directory = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ConfigPath))
    $temporaryPath = [IO.Path]::Combine($directory, ([IO.Path]::GetRandomFileName() + '.tmp'))
    $backupPath = '{0}.{1}-{2}.bak' -f $ConfigPath, (Get-Date -Format 'yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($temporaryPath, $updated, [Text.UTF8Encoding]::new($false))
        [IO.File]::Replace($temporaryPath, $ConfigPath, $backupPath)
    } finally {
        if ([IO.File]::Exists($temporaryPath)) { [IO.File]::Delete($temporaryPath) }
    }

    return [pscustomobject]@{ OldPort = $oldPortValue; NewPort = $NewPort; BackupPath = $backupPath; Changed = $true }
}

function Get-RemoteCheckScript {
    return @'
set -eu
MIHOMO_DIR=/openbayes/home/mihomo
MIHOMO_BIN=$MIHOMO_DIR/mihomo
MIHOMO_LOG=/openbayes/home/mihomo.log

# Existing containers keep using their persistent proxy. A new container may
# connect directly and does not need to install Mihomo just to pass this check.
if [ -d "$MIHOMO_DIR" ]; then
if [ ! -x "$MIHOMO_BIN" ]; then
    echo "Mihomo binary is missing or not executable: $MIHOMO_BIN" >&2
    exit 1
fi

if ! (echo > /dev/tcp/127.0.0.1/7890) 2>/dev/null; then
    cd "$MIHOMO_DIR"
    nohup "$MIHOMO_BIN" -d "$MIHOMO_DIR" >> "$MIHOMO_LOG" 2>&1 < /dev/null &
fi

waited=0
until (echo > /dev/tcp/127.0.0.1/7890) 2>/dev/null; do
    if [ "$waited" -ge 15 ]; then
        echo 'Mihomo did not open 127.0.0.1:7890 within 15 seconds.' >&2
        exit 1
    fi
    sleep 1
    waited=$((waited + 1))
done

"$MIHOMO_BIN" -t -d "$MIHOMO_DIR"
else
    echo 'Mihomo not configured; using the existing network environment.'
fi
export PATH="/openbayes/home/.codex-connect/bin:$PATH"
if ! command -v codex >/dev/null 2>&1; then
    echo 'Codex executable is unavailable.' >&2
    exit 1
fi
codex --version
codex login status
printf '%s\n' 'OPENBAYES_CODEX_READY'
'@
}

function ConvertTo-RemoteBashCommand {
    param([Parameter(Mandatory)][string]$Script)

    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Script.Replace("`r`n", "`n")))
    return "printf '%s' '$encoded' | base64 -d | bash"
}

function Get-SshArguments {
    param(
        [Parameter(Mandatory)][string]$RemoteCommand,
        [switch]$BatchMode,
        [switch]$PasswordMode,
        [string]$ConfigPath
    )

    if ($BatchMode -and $PasswordMode) { throw 'SSH authentication modes conflict.' }

    $arguments = @('-o', 'ConnectTimeout=15', '-o', 'StrictHostKeyChecking=accept-new')
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
        $arguments += @('-F', [IO.Path]::GetFullPath($ConfigPath))
    }
    if ($BatchMode) {
        $arguments += @('-o', 'BatchMode=yes')
    }
    if ($PasswordMode) {
        $arguments += @('-o', 'PubkeyAuthentication=no', '-o', 'PreferredAuthentications=password,keyboard-interactive')
    }
    $arguments += @('openbayes-codex', $RemoteCommand)
    return $arguments
}

function Test-OpenBayesPublicKey {
    param([Parameter(Mandatory)][string]$SshPath, [string]$ConfigPath)

    $sshArguments = @(Get-SshArguments -RemoteCommand 'true' -BatchMode -ConfigPath $ConfigPath)
    [void](Get-Command -Name $SshPath -ErrorAction Stop)
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $probeOutput = @(& $SshPath @sshArguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    foreach ($line in $probeOutput) {
        if (-not [string]::IsNullOrWhiteSpace([string]$line)) {
            Write-RunLog -Stage 'SSH-KEY' -Message ([string]$line)
        }
    }
    Write-RunLog -Stage 'SSH-KEY' -Message "Exit code: $exitCode"
    return ($exitCode -eq 0)
}

function Invoke-OpenBayesRemoteCheck {
    param(
        [Parameter(Mandatory)][string]$SshPath,
        [switch]$PasswordMode,
        [string]$ConfigPath
    )

    $remoteCommand = ConvertTo-RemoteBashCommand -Script (Get-RemoteCheckScript)
    $sshArguments = @(Get-SshArguments -RemoteCommand $remoteCommand -BatchMode:(!$PasswordMode) -PasswordMode:$PasswordMode -ConfigPath $ConfigPath)
    $mode = if ($PasswordMode) { 'interactive password fallback' } else { 'public key batch mode' }
    Write-RunLog -Stage 'REMOTE' -Message "Starting remote checks using $mode."
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $SshPath @sshArguments
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    Write-RunLog -Stage 'REMOTE' -Message "Exit code: $exitCode"
    if ($exitCode -ne 0) { throw "Remote check failed (exit code $exitCode)." }
}

function Invoke-OpenBayesUpdate {
    param(
        [string]$Command,
        [Parameter(Mandatory)][string]$ConfigPath,
        [switch]$SkipRemoteCheck
    )

    if ([string]::IsNullOrWhiteSpace($Command)) {
        $Command = Get-Clipboard -Raw
    }
    $port = Get-OpenBayesPort -SshCommand $Command
    Write-RunLog -Stage 'INPUT' -Message "SSH command parsed. Port: $port"

    $update = Set-OpenBayesSshPort -ConfigPath $ConfigPath -NewPort $port
    if ($update.Changed) {
        Write-RunLog -Stage 'CONFIG' -Message "SSH port updated from $($update.OldPort) to $($update.NewPort)."
        Write-RunLog -Stage 'CONFIG' -Message "Backup: $($update.BackupPath)"
    } else {
        Write-RunLog -Stage 'CONFIG' -Message "SSH port unchanged: $($update.NewPort)"
    }

    if ($SkipRemoteCheck) {
        Write-RunLog -Stage 'REMOTE' -Message 'Remote checks skipped.'
        return
    }

    $sshPath = (Get-Command -Name 'ssh.exe' -ErrorAction Stop).Source
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $effectiveConfig = @(& $sshPath -F ([IO.Path]::GetFullPath($ConfigPath)) -G openbayes-codex 2>&1)
        $effectiveConfigExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    foreach ($line in $effectiveConfig) {
        $text = [string]$line
        if ($text -match '^(?i:hostname|user|port|identityfile)\s+') {
            Write-RunLog -Stage 'SSH-CONFIG' -Message $text
        }
    }
    Write-RunLog -Stage 'SSH-CONFIG' -Message "ssh -G exit code: $effectiveConfigExitCode"
    if ($effectiveConfigExitCode -ne 0) { throw "ssh -G failed (exit code $effectiveConfigExitCode)." }

    Write-RunLog -Stage 'SSH-KEY' -Message 'Testing SSH public-key login...'
    if (Test-OpenBayesPublicKey -SshPath $sshPath -ConfigPath $ConfigPath) {
        Write-RunLog -Stage 'SSH-KEY' -Message 'Public-key login succeeded.' -Color Green
        Invoke-OpenBayesRemoteCheck -SshPath $sshPath -ConfigPath $ConfigPath
    } else {
        Write-RunLog -Stage 'SSH-PASSWORD' -Message 'Public-key login failed. ssh.exe will request this session password. Typed or pasted characters will not be displayed or saved.' -Color Yellow
        Invoke-OpenBayesRemoteCheck -SshPath $sshPath -PasswordMode -ConfigPath $ConfigPath
    }
    Write-RunLog -Stage 'SUCCESS' -Message 'OpenBayes SSH and Codex checks passed.' -Color Green
}

if ($MyInvocation.InvocationName -eq '.') { return }

$finalExitCode = 1
$transcriptStarted = $false
$resolvedLogPath = [IO.Path]::GetFullPath($LogPath)
try {
    $logDirectory = [IO.Path]::GetDirectoryName($resolvedLogPath)
    if (-not [IO.Directory]::Exists($logDirectory)) {
        [void][IO.Directory]::CreateDirectory($logDirectory)
    }
    Start-Transcript -LiteralPath $resolvedLogPath -Force | Out-Null
    $transcriptStarted = $true
    $script:RunLogActive = $true
    Write-RunLog -Stage 'START' -Message "PowerShell $($PSVersionTable.PSVersion); script: $PSCommandPath"
    Write-RunLog -Stage 'START' -Message "Log: $resolvedLogPath"
    Invoke-OpenBayesUpdate -Command $SshCommand -ConfigPath $ConfigPath -SkipRemoteCheck:$SkipRemoteCheck
    $finalExitCode = 0
} catch {
    if ($script:RunLogActive) {
        Write-RunLog -Stage 'ERROR' -Message $_.Exception.Message -Color Red
        $errorFile = if ([string]::IsNullOrWhiteSpace($_.InvocationInfo.ScriptName)) { $PSCommandPath } else { $_.InvocationInfo.ScriptName }
        Write-RunLog -Stage 'ERROR' -Message "Location: $errorFile line $($_.InvocationInfo.ScriptLineNumber)"
    } else {
        Write-Host ("FAILED before logging started: {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
} finally {
    if ($script:RunLogActive) {
        Write-RunLog -Stage 'END' -Message "Exit code: $finalExitCode"
    }
    if ($transcriptStarted) {
        Stop-Transcript | Out-Null
        $script:RunLogActive = $false
        Remove-TranscriptHostApplication -Path $resolvedLogPath
    }
}
exit $finalExitCode
