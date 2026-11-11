<#
=====================================================================
 Tunnel-Open.ps1  -  Abre un tunel Azure Arc hacia un cliente
=====================================================================
 Pensado como "Herramienta externa antes" de mRemoteNG: mRemoteNG
 espera a que este script termine y luego conecta el RDP a
 127.0.0.1:<Port>.

 Uso manual:
   .\Tunnel-Open.ps1 -Machine C001-GestoriaPerez-SRV1 -Port 33401

 Comportamiento:
   - Si ya hay un tunel escuchando en ese puerto, no hace nada.
   - Clave: la de -KeyFile o, si no, terminus_ed25519 junto al script.
     Con clave el tunel se abre oculto; sin clave, ventana para la contrasena.
   - Usuario: el de -Usuario o, si no, la etiqueta UsuarioTunel del equipo
     en Azure (la pone el instalador del cliente); si no hay etiqueta,
     UsuarioDefecto de la configuracion local.
   - Codigo de salida 0 = OK, 1 = error.

 Registro (util cuando lo lanza mRemoteNG y no se ve nada):
   tunnel.log             cada intento, con el motivo si falla
   tunnel_ssh_<Port>.log  salida del ultimo tunel en ese puerto
=====================================================================
#>

param(
    [Parameter(Mandatory)][string]$Machine,         # nombre del equipo en Arc
    [Parameter(Mandatory)][int]   $Port,            # puerto local (unico por cliente)
    [string]$KeyFile        = "",
    [string]$Usuario        = "",                   # vacio = etiqueta UsuarioTunel
    [string]$ResourceGroup  = "",
    [string]$SubscriptionId = "",
    [string]$Tenant         = "",
    [int]   $TimeoutSeg     = 40,      # un tunel normal tarda 5-10 s
    [int]   $AvisoSeg       = 20       # el aviso se cierra solo (mRemoteNG espera a este script)
)

. (Join-Path $PSScriptRoot "Comun.ps1")
if (-not $ResourceGroup)  { $ResourceGroup  = $Op.ResourceGroup }
if (-not $SubscriptionId) { $SubscriptionId = $Op.SubscriptionId }
if (-not $Tenant)         { $Tenant         = $Op.Tenant }

# Registro de cada intento
$Log = Join-Path $PSScriptRoot "tunnel.log"
Function Log { param([string]$t) try { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [${Machine}:${Port}] $t" | Out-File -Append $Log -Encoding UTF8 } catch { } }
# Aviso por encima de todo (mRemoteNG queda delante) y que se cierra solo:
# mRemoteNG espera a que este script termine y un aviso escondido lo dejaria colgado.
Function Mostrar {
    param([string]$t)
    try { (New-Object -ComObject WScript.Shell).Popup($t, $AvisoSeg, "Terminus", 0x30 + 0x40000) | Out-Null } catch { }
}
Function Aviso {
    param([string]$t)
    Log "ERROR: $t"
    Mostrar $t
    exit 1
}
# Error del tunel: motivo = ultima linea con ERROR del log de ssh
Function Fallo {
    param([string]$t)
    Log "ERROR: $t. Ver tunnel_ssh_$Port.log"
    $motivo = ""
    if (Test-Path $LogSsh) { $motivo = (Get-Content $LogSsh | Where-Object { $_ -cmatch '^ERROR:|denied|not found|refused|IDENTIFICATION' } | Select-Object -Last 1) }
    Mostrar "No se pudo abrir el tunel a $Machine.`n`n$motivo`n`nDetalle: $LogSsh"
    exit 1
}
Log "Inicio (usuario $env:USERNAME, PowerShell $($PSVersionTable.PSVersion))"

# ------------------------------------------------------------------
# BLOQUE 1 - Comprobaciones
# ------------------------------------------------------------------
# El nombre llega de mRemoteNG (%USERFIELD%) y acaba dentro de una orden.
if (-not (Test-NombreSeguro $Machine)) { Aviso "Nombre de equipo no valido: '$Machine'. Revisa el campo de usuario de la conexion en mRemoteNG." }
if (-not $SubscriptionId) { Aviso "Falta SubscriptionId en Operador.config.local.ps1." }

# Ya hay tunel en ese puerto? Entonces nada que hacer
if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) { Log "Ya habia tunel en el puerto"; exit 0 }

if (-not $KeyFile -and (Test-Path $Op.Clave)) { $KeyFile = $Op.Clave }

# ------------------------------------------------------------------
# BLOQUE 2 - Sesion de Azure (si no hay, avisar y salir)
# ------------------------------------------------------------------
# Se comprueba la suscripcion configurada (no la que este por defecto).
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { Aviso "No se encuentra Azure CLI (az). Cierra y vuelve a abrir mRemoteNG." }
$resp = (az account show --subscription $SubscriptionId --query user.name -o tsv 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0) { Log "Sesion: $resp"; Aviso "No hay sesion de Azure.`nAbre PowerShell y ejecuta:`n`naz login --tenant $Tenant" }
Log "Sesion: $resp"

# Usuario del tunel: cada cliente puede tener uno distinto (etiqueta en Azure)
if (-not $Usuario) {
    $Usuario = (az resource show --subscription $SubscriptionId --resource-group $ResourceGroup --name $Machine `
                --resource-type "Microsoft.HybridCompute/machines" --query "tags.UsuarioTunel" -o tsv 2>$null | Out-String).Trim()
    if (-not $Usuario) { $Usuario = $Op.UsuarioDefecto }
}
if (-not $Usuario) { Aviso "El equipo $Machine no tiene etiqueta UsuarioTunel y no hay UsuarioDefecto configurado." }
if (-not (Test-UsuarioSeguro $Usuario)) { Aviso "Usuario del tunel no valido: '$Usuario'." }
Log "Usuario del tunel: $Usuario"

# ------------------------------------------------------------------
# BLOQUE 3 - Orden del tunel
# ------------------------------------------------------------------
$orden = "az ssh arc --subscription $SubscriptionId --resource-group $ResourceGroup --name $Machine --local-user '$Usuario'"
if ($KeyFile) { $orden += " --private-key-file '$KeyFile'" }
# accept-new: la primera vez acepta la clave del servidor (oculto no se
# puede contestar yes/no); si despues cambia, ssh se niega a conectar.
$orden += " -- -L ${Port}:localhost:3389 -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o StrictHostKeyChecking=accept-new"

# ------------------------------------------------------------------
# BLOQUE 4 - Lanzar el tunel en un proceso independiente
# ------------------------------------------------------------------
# El proceso sigue vivo cuando este script termina (mRemoteNG ya puede conectar).
$estilo = if ($KeyFile) { "Hidden" } else { "Normal" }

# Restos de un intento anterior en este puerto (tunel colgado que no llego a
# escuchar): se cierran, si no bloquean el log y el puerto.
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*Tunel * ($Port)'*" } |
    ForEach-Object { taskkill /T /F /PID $_.ProcessId 1>$null 2>$null; Log "Cerrado intento anterior (PID $($_.ProcessId))" }

# Con clave (oculto) la salida va a tunnel_ssh_<Port>.log: si falla, ahi esta
# el motivo. Un log por puerto: varios tuneles a la vez no chocan.
$LogSsh = Join-Path $PSScriptRoot "tunnel_ssh_$Port.log"
$redir  = if ($KeyFile) { " *> '$LogSsh'" } else { "" }
$p = Start-Process powershell -PassThru -WindowStyle $estilo -ArgumentList @(
    "-NoProfile", "-Command",
    "`$Host.UI.RawUI.WindowTitle = 'Tunel $Machine ($Port)'; $orden$redir"
)
Log "Proceso del tunel lanzado (PID $($p.Id))"

# ------------------------------------------------------------------
# BLOQUE 5 - Esperar a que el puerto escuche
# ------------------------------------------------------------------
$inicio = Get-Date
while (((Get-Date) - $inicio).TotalSeconds -lt $TimeoutSeg) {
    if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) {
        Log "Tunel listo en $([int]((Get-Date) - $inicio).TotalSeconds) s"; exit 0
    }
    if ($p.HasExited) { Fallo "el proceso del tunel se ha cerrado (codigo $($p.ExitCode))" }
    Start-Sleep -Milliseconds 500
}
taskkill /T /F /PID $p.Id 1>$null 2>$null
Fallo "el tunel no escucha tras $TimeoutSeg s"
