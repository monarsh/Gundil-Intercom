# Starts the update server's web portal afresh on Windows: the admin
# account is replaced by a new one with a one-time password, which must be
# changed at the first sign-in. Run in PowerShell as Administrator:
#   .\reset-portal.ps1            new admin account (devices, versions kept)
#   .\reset-portal.ps1 -All       also forget devices, policy and versions
#   .\reset-portal.ps1 -All -NewKey   ...and a new server key (every app must
#                                 get the new server code)
param([switch]$All, [switch]$NewKey)
$ErrorActionPreference = 'Stop'
$exe = Join-Path $PSScriptRoot 'gundil-update-server.exe'
if ($NewKey) {
  $a = Read-Host 'A new server key cuts off every installed app until it gets the new server code. Continue? [y/N]'
  if ($a -ne 'y') { exit 1 }
}
$svc = Get-Service GundilUpdateServer -ErrorAction SilentlyContinue
if ($svc) { Stop-Service GundilUpdateServer }
$args = @()
if ($All) { $args += '--all' }
if ($NewKey) { $args += '--new-key' }
$args += 'reset-admin'
& $exe @args
if ($svc) { Start-Service GundilUpdateServer; Start-Sleep 2 }
$pw = Join-Path $env:ProgramData 'Gundil\update-server\initial-password.txt'
if (Test-Path $pw) { Write-Host "One-time password: $(Get-Content $pw)" }
Write-Host 'Sign in as "admin" with it; you will be asked to choose a new password.'
