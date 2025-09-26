<#
Auto-Proof for pqc-ssh-pr-Anurag-Dongare-v3/v4
Author: Anurag Dongare
Date: Sept 2025
Purpose: Zero-touch validation: generate sshd_config from *supported* algos, validate, (re)start sshd, and run smoke tests.
#>

$ErrorActionPreference = "Stop"
$sshdCfg = "$env:ProgramData\ssh\sshd_config"
$sshdExe = "C:\Windows\System32\OpenSSH\sshd.exe"
$backup = "$sshdCfg.bak_$(Get-Date -Format yyyyMMddHHmmss)"

Write-Host "=== Auto-Proof PQC SSH (V4) ===" -ForegroundColor Cyan

# 1) Backup
if (Test-Path $sshdCfg) {
    Copy-Item $sshdCfg $backup -Force
    Write-Host "Backed up current config to $backup" -ForegroundColor Yellow
}

# 2) Detect supported algorithms
$kexList = & ssh -Q kex
$cipherList = & ssh -Q cipher
$macList = & ssh -Q mac

Write-Host "Detected KEX: $($kexList -join ', ')" -ForegroundColor Gray
Write-Host "Detected Ciphers: $($cipherList -join ', ')" -ForegroundColor Gray
Write-Host "Detected MACs: $($macList -join ', ')" -ForegroundColor Gray

# 3) Choose best KEX based on availability (mlkem > sntrup > curve25519)
if ($kexList -contains "mlkem768x25519-sha256") {
    $chosenKex = "mlkem768x25519-sha256"
} elseif ($kexList -contains "sntrup761x25519-sha512@openssh.com") {
    $chosenKex = "sntrup761x25519-sha512@openssh.com"
} elseif ($kexList -contains "curve25519-sha256") {
    $chosenKex = "curve25519-sha256"
} else {
    # last resort: pick first available from list
    $chosenKex = ($kexList | Select-Object -First 1)
}
Write-Host "Selected KEX: $chosenKex" -ForegroundColor Green

# 4) Choose conservative, widely supported ciphers/MACs present on this host
#    (one per line to avoid Win32-OpenSSH parsing quirks)
$preferredCiphers = @(
    "chacha20-poly1305@openssh.com",
    "aes256-gcm@openssh.com",
    "aes128-gcm@openssh.com",
    "aes256-ctr","aes192-ctr","aes128-ctr"
) | Where-Object { $cipherList -contains $_ }

if (-not $preferredCiphers) { $preferredCiphers = $cipherList | Select-Object -First 3 }

$preferredMACs = @(
    "hmac-sha2-512-etm@openssh.com",
    "hmac-sha2-256-etm@openssh.com",
    "hmac-sha2-512",
    "hmac-sha2-256"
) | Where-Object { $macList -contains $_ }

if (-not $preferredMACs) { $preferredMACs = $macList | Select-Object -First 2 }

# 5) Build config text
$config = @"
Port 22
Protocol 2
HostKey C:/ProgramData/ssh/ssh_host_ed25519_key
HostKey C:/ProgramData/ssh/ssh_host_rsa_key
PubkeyAuthentication yes
PasswordAuthentication no
PermitRootLogin prohibit-password
UseDNS no
AllowTcpForwarding yes
X11Forwarding no
AllowAgentForwarding yes
Subsystem sftp sftp-server.exe

KexAlgorithms $chosenKex
"@

foreach ($c in $preferredCiphers) { $config += "`r`nCiphers $c" }
foreach ($m in $preferredMACs) { $config += "`r`nMACs $m" }

# 6) Write config
$config | Out-File -FilePath $sshdCfg -Encoding ascii -Force
Write-Host "Generated sshd_config from supported algorithms" -ForegroundColor Green

# 7) Validate config
& $sshdExe -t -f $sshdCfg
if ($LASTEXITCODE -ne 0) {
    Write-Host $config
    Write-Error "Validation failed, rolling back..."
    if (Test-Path $backup) { Copy-Item $backup $sshdCfg -Force }
    exit 1
}
Write-Host "Config validation passed" -ForegroundColor Green

# 8) Start/restart sshd
try {
    $svc = Get-Service sshd -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") {
        Restart-Service sshd
        Write-Host "sshd service restarted" -ForegroundColor Green
    } else {
        Start-Service sshd
        Write-Host "sshd service started" -ForegroundColor Green
    }
} catch {
    Write-Error "Failed to start sshd. Rolling back..."
    if (Test-Path $backup) { Copy-Item $backup $sshdCfg -Force }
    try { Start-Service sshd } catch {}
    exit 1
}

# 9) Smoke tests
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$smoke = Join-Path $scriptDir "smoke-test.ps1"

Write-Host "Running smoke test: localhost" -ForegroundColor Cyan
& $smoke -Target localhost

Write-Host "Running smoke test: github.com" -ForegroundColor Cyan
& $smoke -Target github.com
