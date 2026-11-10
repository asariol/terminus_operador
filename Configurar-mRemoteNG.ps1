<#
=====================================================================
 Configurar-mRemoteNG.ps1  -  Herramientas externas de Terminus
=====================================================================
 Crea (o corrige) en mRemoteNG las herramientas externas:
   Terminus-Abrir   antes de conectar: abre el tunel (espera a que acabe)
   Terminus-Cerrar  al desconectar: cierra el tunel

 Lo llama Preparar-Operador.ps1. Se puede ejecutar solo. mRemoteNG
 tiene que estar CERRADO (al salir guarda su copia y pisaria el cambio).

 Despues, en cada conexion de cliente:
   Host 127.0.0.1 | Puerto: el del cliente | Campo de usuario: nombre
   del equipo en Azure | Herramienta antes: Terminus-Abrir |
   Herramienta despues: Terminus-Cerrar
=====================================================================
#>

param([string]$DirMremote = "$env:APPDATA\mRemoteNG")   # datos de mRemoteNG de este usuario (version instalada)

$Dir = $PSScriptRoot
# Sin comillas en los argumentos: mRemoteNG las pasa literalmente.
if ($Dir -match '\s') { Write-Host "  La carpeta no puede tener espacios: $Dir" -ForegroundColor Red; exit 1 }

# ------------------------------------------------------------------
# BLOQUE 1 - mRemoteNG cerrado
# ------------------------------------------------------------------
if (Get-Process mRemoteNG -ErrorAction SilentlyContinue) {
    Write-Host "  mRemoteNG esta abierto. Cierralo y pulsa Intro." -ForegroundColor Yellow
    Read-Host | Out-Null
    if (Get-Process mRemoteNG -ErrorAction SilentlyContinue) { Write-Host "  Sigue abierto: no se configuran las herramientas." -ForegroundColor Red; exit 1 }
}

# ------------------------------------------------------------------
# BLOQUE 2 - Herramientas en extApps.xml
# ------------------------------------------------------------------
$fApps = Join-Path $DirMremote "extApps.xml"
New-Item -ItemType Directory -Path $DirMremote -Force | Out-Null
$apps = New-Object Xml.XmlDocument
if (Test-Path $fApps) { $apps.Load($fApps); Copy-Item $fApps "$fApps.bak" -Force }
else { $apps.LoadXml('<?xml version="1.0" encoding="utf-8"?><Apps />') }

$ps = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File"
$herramientas = @(
    @{ DisplayName = "Terminus-Abrir";  Arguments = "$ps $Dir\Tunnel-Open.ps1 -Machine %USERFIELD% -Port %PORT%"; WaitForExit = "True" },
    @{ DisplayName = "Terminus-Cerrar"; Arguments = "$ps $Dir\Tunnel-Close.ps1 -Port %PORT%";                     WaitForExit = "False" }
)
$cambio = $false
foreach ($h in $herramientas) {
    $app = $apps.SelectSingleNode("/Apps/App[@DisplayName='$($h.DisplayName)']")
    if (-not $app) { $app = $apps.CreateElement("App"); [void]$apps.DocumentElement.AppendChild($app) }
    $valores = [ordered]@{
        DisplayName = $h.DisplayName; FileName = "powershell.exe"; Arguments = $h.Arguments; WorkingDir = ""
        WaitForExit = $h.WaitForExit; TryToIntegrate = "False"; RunElevated = "False"; ShowOnToolbar = "False"
    }
    foreach ($k in $valores.Keys) {
        if ($app.GetAttribute($k) -ne $valores[$k]) { $app.SetAttribute($k, $valores[$k]); $cambio = $true }
    }
}
if ($cambio) { $apps.Save($fApps); Write-Host "  Herramientas Terminus-Abrir / Terminus-Cerrar configuradas en $fApps" -ForegroundColor Green }
else         { Write-Host "  Herramientas ya configuradas." -ForegroundColor DarkGray }
