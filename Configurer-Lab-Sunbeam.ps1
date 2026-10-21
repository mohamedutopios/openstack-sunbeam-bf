#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
Preparation du poste Windows pour les OVA du lab Sunbeam. Version 1.1.
Placer le certificat PUBLIC ca.crt fourni par le formateur a cote du script.
Usage : powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Configurer-Lab-Sunbeam-v1.1.ps1
Option : -CaPath "C:\chemin\vers\ca.crt" si le certificat est ailleurs.
Relancable : remplace les associations des quatre noms du lab, sans doublons.
La CA est approuvee pour TOUS les utilisateurs de ce PC (LocalMachine\Root).
Les tests reseau ne prouvent pas que TLS, Horizon ou le SSO fonctionnent.
#>
[CmdletBinding()]
param(
    [string]$CaPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Dossier du script : $PSScriptRoot peut etre vide dans le bloc param() en 5.1,
# il est donc resolu ici, avec repli sur $PSCommandPath puis le dossier courant.
$ScriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ScriptDir) -and -not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
    $ScriptDir = Split-Path -Parent $PSCommandPath
}
if ([string]::IsNullOrWhiteSpace($ScriptDir)) {
    $ScriptDir = (Get-Location).Path
}
if ([string]::IsNullOrWhiteSpace($CaPath)) {
    $CaPath = Join-Path $ScriptDir 'ca.crt'
}

# Valider le certificat avant toute modification.
if (-not (Test-Path -LiteralPath $CaPath -PathType Leaf)) {
    throw "Certificat absent : $CaPath. Copier le ca.crt du formateur a cote du script."
}
$CaPath = (Resolve-Path -LiteralPath $CaPath).Path
$cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CaPath)
$bc = $cert.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.19' } | Select-Object -First 1
if ($null -eq $bc) { throw 'Le certificat ne contient pas les contraintes CA.' }
$constraints = New-Object System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension
$constraints.CopyFrom($bc)
if (-not $constraints.CertificateAuthority) { throw 'Le certificat fourni ne correspond pas a une autorite CA.' }
if ((Get-Date) -lt $cert.NotBefore -or (Get-Date) -gt $cert.NotAfter) {
    throw 'La CA est expiree ou pas encore valide. Verifier aussi la date du PC.'
}
Write-Host "CA du lab : $($cert.Subject)"
Write-Host "Empreinte : $($cert.Thumbprint)"

$entries = [ordered]@{
    'sso.lab.test'      = '192.168.56.20'
    'cloud.lab.test'    = '192.168.56.201'
    'internal.lab.test' = '192.168.56.202'
    'rgw.lab.test'      = '192.168.56.203'
}
$hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$lines = [System.IO.File]::ReadAllLines($hostsPath)
$result = New-Object 'System.Collections.Generic.List[string]'
foreach ($line in $lines) {
    $parts = @($line -split '#', 2)
    $body = $parts[0].Trim()
    if (-not $body) { $result.Add($line); continue }
    $tokens = @($body -split '\s+')
    if ($tokens.Count -lt 2) { $result.Add($line); continue }
    $names = @($tokens[1..($tokens.Count - 1)])
    $remaining = @($names | Where-Object { -not $entries.Contains($_.ToLowerInvariant()) })
    if ($remaining.Count -eq $names.Count) {
        $result.Add($line)
    } elseif ($remaining.Count -gt 0) {
        $rebuilt = $tokens[0] + "`t" + ($remaining -join ' ')
        if ($parts.Count -gt 1) { $rebuilt += ' #' + $parts[1] }
        $result.Add($rebuilt)
    } elseif ($parts.Count -gt 1) {
        $result.Add('#' + $parts[1])
    }
}
foreach ($entry in $entries.GetEnumerator()) {
    $result.Add("$($entry.Value)`t$($entry.Key)")
}
$newText = ($result -join "`r`n") + "`r`n"
$oldText = [System.IO.File]::ReadAllText($hostsPath)
if ($oldText -ne $newText) {
    $backup = $hostsPath + '.sunbeam-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.bak'
    Copy-Item -LiteralPath $hostsPath -Destination $backup
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($hostsPath, $newText, $utf8)
    Write-Host "Fichier hosts configure. Sauvegarde : $backup" -ForegroundColor Green
} else {
    Write-Host 'Fichier hosts deja configure.' -ForegroundColor Green
}

$storePath = 'Cert:\LocalMachine\Root'
if (-not (Test-Path -LiteralPath "$storePath\$($cert.Thumbprint)")) {
    Import-Certificate -FilePath $CaPath -CertStoreLocation $storePath | Out-Null
    Write-Host 'CA importee pour tous les utilisateurs du PC.' -ForegroundColor Green
} else {
    Write-Host 'CA deja presente.' -ForegroundColor Green
}
Clear-DnsClientCache

Write-Host "`nVerification de la resolution des noms :"
foreach ($entry in $entries.GetEnumerator()) {
    try {
        $resolved = @([System.Net.Dns]::GetHostAddresses($entry.Key) | ForEach-Object { $_.IPAddressToString })
    } catch {
        $resolved = @()
    }
    if ($resolved -contains $entry.Value) {
        Write-Host "OK : $($entry.Key) -> $($entry.Value)" -ForegroundColor Green
    } else {
        Write-Warning "Resolution inattendue pour $($entry.Key) : $($resolved -join ', ')"
    }
}
Write-Host "`nTests TCP (les VM doivent etre demarrees) :"
foreach ($target in @(
    @{ Name = 'Keycloak'; Address = '192.168.56.20'; Port = 8443 },
    @{ Name = 'OpenStack HTTPS'; Address = '192.168.56.201'; Port = 443 }
)) {
    $ok = Test-NetConnection -ComputerName $target.Address -Port $target.Port -InformationLevel Quiet -WarningAction SilentlyContinue
    if ($ok) {
        Write-Host "OK : $($target.Name), port $($target.Port) accessible." -ForegroundColor Green
    } else {
        Write-Warning "$($target.Name) inaccessible. Verifier les VM, leurs cartes host-only et le service. OpenStack 443 exige TLS actif et Vault deverrouille."
    }
}
Write-Host "`nConfiguration Windows terminee. Les tests ci-dessus portent sur le reseau, pas sur le SSO."
Write-Host 'Keycloak : https://sso.lab.test:8443/admin/'
Write-Host "Horizon : utiliser l'URL exacte fournie par le formateur (sunbeam dashboard url)."
Write-Host 'Fermer puis rouvrir le navigateur si necessaire.'
