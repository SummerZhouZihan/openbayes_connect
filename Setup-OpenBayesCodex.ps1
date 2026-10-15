param(
    [string]$SshCommand,
    [string]$ConfigPath = (Join-Path $env:USERPROFILE '.ssh\config'),
    [string]$IdentityPath = (Join-Path $env:USERPROFILE '.ssh\id_ed25519_openbayes'),
    [switch]$PrepareOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Update-OpenBayesCodex.ps1') -SshCommand $SshCommand -ConfigPath $ConfigPath

function Initialize-OpenBayesSshConfig {
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$IdentityPath,
        [Parameter(Mandatory)][ValidateRange(1, 65535)][int]$Port
    )
    $ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
    $IdentityPath = [IO.Path]::GetFullPath($IdentityPath)
    if ($IdentityPath -match '["\r\n]') { throw 'Invalid identity path.' }
    $original = if ([IO.File]::Exists($ConfigPath)) { [IO.File]::ReadAllText($ConfigPath) } else { '' }
    if ($original -match '(?im)^\s*Host(?:\s*=\s*|\s+)openbayes-codex\s*$') {
        # Preserve an existing identity and all other host options.
        return Set-OpenBayesSshPort -ConfigPath $ConfigPath -NewPort $Port
    }
    if ($original -match '(?im)^\s*Host(?:\s*=\s*|\s+)[^\r\n]*\bopenbayes-codex\b') {
        throw 'openbayes-codex exists in a multi-alias Host line; split it into a separate Host block first.'
    }
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($ConfigPath))
    $identity = $IdentityPath.Replace('\', '/')
    # Prepend before Host * / Match: OpenSSH uses the first obtained value.
    $block = @"
Host openbayes-codex
    HostName ssh.openbayes.com
    User root
    Port $Port
    IdentityFile "$identity"
    IdentitiesOnly yes
    ServerAliveInterval 30
    ServerAliveCountMax 3

"@
    $updated = $block.Replace("`r`n", "`n") + "`n" + $original
    $backupPath = $null
    $temporaryPath = Join-Path ([IO.Path]::GetDirectoryName($ConfigPath)) ([IO.Path]::GetRandomFileName())
    try {
        [IO.File]::WriteAllText($temporaryPath, $updated, [Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($ConfigPath)) {
            $backupPath = '{0}.{1}-{2}.bak' -f $ConfigPath, (Get-Date -Format 'yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N'))
            [IO.File]::Replace($temporaryPath, $ConfigPath, $backupPath)
        } else {
            [IO.File]::Move($temporaryPath, $ConfigPath)
        }
    } finally {
        if ([IO.File]::Exists($temporaryPath)) { [IO.File]::Delete($temporaryPath) }
    }
    return [pscustomobject]@{ OldPort = $null; NewPort = $Port; BackupPath = $backupPath; Changed = $true }
}

function New-OpenBayesIdentity {
    param([Parameter(Mandatory)][string]$IdentityPath)
    $IdentityPath = [IO.Path]::GetFullPath($IdentityPath)
    if ($IdentityPath -match '["\r\n]') { throw 'Invalid identity path.' }
    if ([IO.File]::Exists($IdentityPath)) {
        if (-not [IO.File]::Exists($IdentityPath + '.pub')) {
            throw 'Existing private key has no .pub file. Recover its public key with ssh-keygen -y; the private key will not be replaced.'
        }
        return
    }
    if ([IO.File]::Exists($IdentityPath + '.pub')) { throw 'Public key exists without its private key. Choose another IdentityPath.' }
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($IdentityPath))
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = (Get-Command ssh-keygen.exe -ErrorAction Stop).Source
    # ProcessStartInfo retains the empty passphrase argument on Windows PowerShell 5.1.
    $start.Arguments = '-q -t ed25519 -N "" -C "openbayes-codex" -f "' + $IdentityPath + '"'
    $start.UseShellExecute = $false
    $process = [Diagnostics.Process]::Start($start)
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { throw 'ssh-keygen failed.' }
    $process.Dispose()
}

function Get-AuthorizeKeyScript {
    param([Parameter(Mandatory)][string]$PublicKey)
    if ($PublicKey.Trim() -notmatch '^ssh-ed25519 [A-Za-z0-9+/=]+(?: [A-Za-z0-9_.@-]+)?$') {
        throw 'Expected an Ed25519 public key.'
    }
    return @'
set -eu
umask 077
mkdir -p "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys"
key='PUBLIC_KEY_PLACEHOLDER'
if ! grep -qxF "$key" "$HOME/.ssh/authorized_keys"; then
    printf '\n%s\n' "$key" >> "$HOME/.ssh/authorized_keys"
fi
chmod 700 "$HOME/.ssh"
chmod 600 "$HOME/.ssh/authorized_keys"
printf '%s\n' 'OPENBAYES_KEY_INSTALLED'
'@.Replace('PUBLIC_KEY_PLACEHOLDER', $PublicKey.Trim()).Replace("`r`n", "`n")
}

if ($MyInvocation.InvocationName -eq '.') { return }

try {
    if ([string]::IsNullOrWhiteSpace($SshCommand)) { $SshCommand = Get-Clipboard -Raw }
    $port = Get-OpenBayesPort $SshCommand
    $sshPath = (Get-Command ssh.exe -ErrorAction Stop).Source
    New-OpenBayesIdentity -IdentityPath $IdentityPath
    $result = Initialize-OpenBayesSshConfig -ConfigPath $ConfigPath -IdentityPath $IdentityPath -Port $port
    Write-Host "SSH config ready: $ConfigPath (openbayes-codex, port $port)"
    if ($result.BackupPath) { Write-Host "Backup: $($result.BackupPath)" }
    $authorize = Get-AuthorizeKeyScript -PublicKey ([IO.File]::ReadAllText($IdentityPath + '.pub'))
    $localDirectory = Join-Path $PSScriptRoot '.local'
    [void][IO.Directory]::CreateDirectory($localDirectory)
    $authorizePath = Join-Path $localDirectory 'authorize-key.sh'
    [IO.File]::WriteAllText($authorizePath, $authorize + "`n", [Text.UTF8Encoding]::new($false))
    Write-Host "Public-key install script: $authorizePath"
    if ($PrepareOnly) {
        Write-Host 'Paste this script into the OpenBayes web terminal, then run the update launcher.'
    } else {
        if (-not (Test-OpenBayesPublicKey -SshPath $sshPath -ConfigPath $ConfigPath)) {
            Write-Host 'ssh.exe will ask for the current OpenBayes password. Input is hidden.'
            $sshArguments = @(Get-SshArguments -RemoteCommand (ConvertTo-RemoteBashCommand $authorize) -PasswordMode -ConfigPath $ConfigPath)
            & $sshPath @sshArguments
            if ($LASTEXITCODE -ne 0) { throw 'Key installation failed. Alternatively paste .local/authorize-key.sh into the OpenBayes web terminal.' }
        }
        if (-not (Test-OpenBayesPublicKey -SshPath $sshPath -ConfigPath $ConfigPath)) {
            throw 'Public-key login failed. Check the IdentityFile in the existing Host block and authorized_keys.'
        }
        & (Join-Path $PSScriptRoot 'Update-OpenBayesCodex.ps1') -SshCommand $SshCommand -ConfigPath $ConfigPath
        exit $LASTEXITCODE
    }
} catch {
    Write-Host ('SETUP FAILED: ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
