<#
=====================================================================
 Preparar-Operador.ps1  -  Deja listo el PC de un operador
=====================================================================
 Requisito previo: el operador esta en el grupo de operadores de
 Entra ID (lo da de alta el propietario del grupo).

 Se ejecuta en PowerShell COMO ADMINISTRADOR pero con el usuario de
 Windows del propio operador (la clave queda solo para ese usuario).
 Se puede repetir sin problema.

 Que hace:
   1. Instala Azure CLI si no esta (MSI oficial, firma verificada).
   2. Instala la extension "ssh" de Azure CLI.
   3. Carpeta de scripts solo para este usuario y Administradores.
   4. Clave privada: la toma de Operador.config.local.ps1 (ClavePrivada)
      o de -ClavePrivada <fichero>, la guarda en terminus_ed25519 con
      permisos solo para este usuario y la borra de la configuracion y
      del historial de PowerShell.
   5. Herramientas externas de mRemoteNG (Terminus-Abrir / Terminus-Cerrar).
   6. Inicia sesion en Azure y comprueba que ve los equipos.

 Uso:
   .\Preparar-Operador.ps1
   .\Preparar-Operador.ps1 -ClavePrivada D:\terminus_ed25519
=====================================================================
#>

param([string]$ClavePrivada)

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"     # en PowerShell 5.1 la barra hace la descarga lentisima
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
Function Paso { param([string]$t) Write-Host "`n== $t ==" -ForegroundColor Cyan }

. (Join-Path $PSScriptRoot "Comun.ps1")
$Dir = $PSScriptRoot
$yo  = "$env:USERDOMAIN\$env:USERNAME"

if ($Dir -match '\s') { Write-Host "La carpeta no puede tener espacios (mRemoteNG no admite comillas): $Dir" -ForegroundColor Red; exit 1 }
if (-not $Op.SubscriptionId -or -not $Op.Tenant) {
    Write-Host "Falta Operador.config.local.ps1 (SubscriptionId y Tenant). Pegar antes el bloque de Bitwarden." -ForegroundColor Red; exit 1
}

# ------------------------------------------------------------------
# BLOQUE 1 - Azure CLI
# ------------------------------------------------------------------
Paso "1/6 Azure CLI"
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    $msi = "$env:TEMP\AzureCLI.msi"
    Write-Host "  Descargando Azure CLI..." -ForegroundColor Yellow
    Invoke-WebRequest -Uri "https://aka.ms/installazurecliwindowsx64" -OutFile $msi -UseBasicParsing
    $firma = Get-AuthenticodeSignature $msi
    if ($firma.Status -ne "Valid" -or $firma.SignerCertificate.Subject -notmatch "O=Microsoft Corporation") {
        Write-Host "  Firma del MSI no valida. Cancelado." -ForegroundColor Red; exit 1
    }
    Start-Process msiexec.exe -Wait -ArgumentList "/i `"$msi`" /qn"
    Remove-Item $msi -ErrorAction SilentlyContinue
    $env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User")
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) { Write-Host "  No se pudo instalar. Ejecutar como Administrador." -ForegroundColor Red; exit 1 }
    Write-Host "  Azure CLI instalado." -ForegroundColor Green
} else { Write-Host "  Ya instalado." -ForegroundColor DarkGray }

# ------------------------------------------------------------------
# BLOQUE 2 - Extension ssh
# ------------------------------------------------------------------
Paso "2/6 Extension ssh"
az extension add --name ssh --upgrade --only-show-errors 1>$null 2>$null
az config set extension.use_dynamic_install=yes_without_prompt --only-show-errors 1>$null 2>$null
# Este script corre como Administrador: lo que az crea en el perfil puede
# quedar con permisos de Administradores y luego, sin elevar (mRemoteNG),
# az falla con "Acceso denegado" al cargar la extension. Se devuelve al usuario.
$azDir = Join-Path $env:USERPROFILE ".azure"
if (Test-Path $azDir) {
    icacls $azDir /setowner "$env:USERDOMAIN\$env:USERNAME" /T /C /Q 1>$null 2>$null
    icacls $azDir /reset /T /C /Q 1>$null 2>$null
}
Write-Host "  Extension ssh $(az extension show --name ssh --query version -o tsv 2>$null)" -ForegroundColor Green

# ------------------------------------------------------------------
# BLOQUE 3 - Permisos de la carpeta
# ------------------------------------------------------------------
# Creada bajo C:\ hereda "Usuarios autenticados: modificar": otro usuario
# del PC podria cambiar los scripts. Se deja para este usuario + admins.
Paso "3/6 Carpeta $Dir"
$yoSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
icacls $Dir /inheritance:r /grant:r "*S-1-5-32-544:(OI)(CI)F" "*S-1-5-18:(OI)(CI)F" "*${yoSid}:(OI)(CI)M" /C /Q 1>$null 2>$null
foreach ($r in (Get-Acl $Dir).Access) {
    try { $sid = $r.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } catch { continue }
    if ($sid -notin "S-1-5-32-544", "S-1-5-18", $yoSid) { icacls $Dir /remove:g "*$sid" /C /Q 1>$null 2>$null }
}
Write-Host "  Solo $yo y Administradores." -ForegroundColor Green

# ------------------------------------------------------------------
# BLOQUE 4 - Clave privada (solo lectura para este usuario)
# ------------------------------------------------------------------
Paso "4/6 Clave privada"
$texto = $null
if ($ClavePrivada)     { $texto = Get-Content $ClavePrivada -Raw }
elseif ($Op.ClavePrivada) { $texto = $Op.ClavePrivada }

if ($texto) {
    if ($texto -notmatch 'BEGIN OPENSSH PRIVATE KEY') { Write-Host "  La clave no tiene formato OpenSSH. Cancelado." -ForegroundColor Red; exit 1 }
    # Saltos LF y salto final: ssh rechaza la clave si el formato no es exacto.
    $limpia = (($texto -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join "`n"
    if (Test-Path $Op.Clave) { icacls $Op.Clave /grant:r "${yo}:F" 1>$null 2>$null }
    [IO.File]::WriteAllText($Op.Clave, "$limpia`n", (New-Object Text.UTF8Encoding $false))
    # ssh rechaza claves con permisos abiertos ("UNPROTECTED PRIVATE KEY FILE").
    icacls $Op.Clave /setowner $yo 1>$null 2>$null
    icacls $Op.Clave /inheritance:r 1>$null
    icacls $Op.Clave /grant:r "${yo}:R" 1>$null
    Write-Host "  Clave guardada en $($Op.Clave) (solo $yo)." -ForegroundColor Green

    # Quitar la clave de la configuracion local (se reescribe sin ClavePrivada)
    if ($OperadorLocal -and $OperadorLocal.ContainsKey("ClavePrivada")) {
        $lineas = foreach ($k in $OperadorLocal.Keys) {
            if ($k -ne "ClavePrivada") { "    $k = '$(([string]$OperadorLocal[$k]) -replace "'", "''")'" }
        }
        Set-Content $OpConfigLocal ("`$OperadorLocal = @{`r`n" + ($lineas -join "`r`n") + "`r`n}") -Encoding ASCII
        Write-Host "  Clave eliminada de Operador.config.local.ps1" -ForegroundColor Green
    }
    # Y del historial de PowerShell (al pegar el bloque de Bitwarden se guarda alli)
    $hist = "$env:APPDATA\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt"
    if (Test-Path $hist) {
        $trozos = @($limpia -split "`n" | Where-Object { $_.Length -ge 20 })
        $h = Get-Content $hist
        # Tambien la linea de instalacion ($OperadorBloque='<base64>'), que lleva la clave codificada.
        $resto = $h | Where-Object { $l = $_.Trim(); -not ($l -match 'PRIVATE KEY|OperadorBloque' -or $trozos -contains $l) }
        if (@($resto).Count -ne @($h).Count) { $resto | Set-Content $hist -Encoding UTF8; Write-Host "  Clave eliminada del historial de PowerShell." -ForegroundColor Green }
    }
    $texto = $null; $limpia = $null
} elseif (Test-Path $Op.Clave) {
    Write-Host "  Ya existe $($Op.Clave)" -ForegroundColor DarkGray
} else {
    Write-Host "  Sin clave: el tunel pedira la contrasena del usuario del servidor." -ForegroundColor Yellow
}

# ------------------------------------------------------------------
# BLOQUE 5 - Herramientas externas de mRemoteNG
# ------------------------------------------------------------------
Paso "5/6 mRemoteNG"
& (Join-Path $PSScriptRoot "Configurar-mRemoteNG.ps1")

# ------------------------------------------------------------------
# BLOQUE 6 - Sesion y prueba
# ------------------------------------------------------------------
Paso "6/6 Sesion de Azure"
az account show --subscription $Op.SubscriptionId --only-show-errors 1>$null 2>$null
if ($LASTEXITCODE -ne 0) { az login --tenant $Op.Tenant --only-show-errors 1>$null }
az account set --subscription $Op.SubscriptionId 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "  Sin sesion en la suscripcion (login cancelado o cuenta equivocada)." -ForegroundColor Yellow
    Write-Host "  Ejecutar: az login --tenant $($Op.Tenant)   y elegir la cuenta de la empresa" -ForegroundColor Yellow
} else {
    Write-Host "  Sesion: $(az account show --query user.name -o tsv)" -ForegroundColor Green
    # Lista de nombres y se cuentan aqui (pasar "length(@)" por az.cmd falla).
    $nombres = @(az resource list --subscription $Op.SubscriptionId --resource-group $Op.ResourceGroup `
                 --resource-type "Microsoft.HybridCompute/machines" --query "[].name" -o tsv 2>$null |
                 Where-Object { $_ -match '^[A-Za-z0-9._-]+$' })
    if ($nombres.Count -gt 0) { Write-Host "  Ve $($nombres.Count) equipo(s): $($nombres -join ', ')" -ForegroundColor Green }
    else { Write-Host "  No ve equipos: revisar que esta en el grupo de operadores (puede tardar unos minutos)." -ForegroundColor Yellow }
}

Write-Host "`nListo. Cada manana: az login --tenant $($Op.Tenant)" -ForegroundColor Cyan
Write-Host "Conexion en mRemoteNG: Host 127.0.0.1, Puerto el del cliente, Campo de usuario = nombre del equipo en Azure," -ForegroundColor Cyan
Write-Host "herramienta antes Terminus-Abrir, despues Terminus-Cerrar." -ForegroundColor Cyan
