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
   tunnel_ssh_<Equipo>_<Port>.log  salida del ultimo tunel a ese equipo
=====================================================================
#>

param(
    [Parameter(Mandatory)][string]$Machine,         # nombre del equipo en Arc
    [Parameter(Mandatory)][int]   $Port,            # puerto local (unico por cliente)
    [string]$KeyFile        = "",
    [string]$Usuario        = "",                   # vacio = cache / etiqueta UsuarioTunel
    [string]$ResourceGroup  = "",
    [string]$SubscriptionId = "",
    [string]$Tenant         = "",
    [int]   $TimeoutSeg     = 30,      # un tunel normal tarda 5-10 s
    [int]   $AvisoSeg       = 30,      # el aviso de error se cierra solo
    [switch]$SinAvisos                 # sin ventanas (Iniciar-Dia muestra su propia tabla)
)

. (Join-Path $PSScriptRoot "Comun.ps1")
if (-not $ResourceGroup)  { $ResourceGroup  = $Op.ResourceGroup }
if (-not $SubscriptionId) { $SubscriptionId = $Op.SubscriptionId }
if (-not $Tenant)         { $Tenant         = $Op.Tenant }
$LogSsh = Join-Path $PSScriptRoot "tunnel_ssh_${Machine}_$Port.log"

# ------------------------------------------------------------------
# BLOQUE 0 - Registro, ventanas y salida
# ------------------------------------------------------------------
$Log = Join-Path $PSScriptRoot "tunnel.log"
Function Log { param([string]$t) try { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [${Machine}:${Port}] $t" | Out-File -Append $Log -Encoding UTF8 } catch { } }

# Lanza un trozo de PowerShell en un proceso aparte, oculto (ventanas que no
# deben bloquear a mRemoteNG, que espera a que este script termine).
Function Lanzar {
    param([string]$Codigo)
    try {
        Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList "-NoProfile", "-EncodedCommand",
            ([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Codigo)))
    } catch { $null }
}

# Ventanita "Abriendo tunel a X... N s", encima de todo, abajo a la derecha.
$script:Ventana = $null
if (-not $SinAvisos) {
    $script:Ventana = Lanzar @"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
`$f = New-Object Windows.Forms.Form
`$f.Text = 'Terminus'; `$f.TopMost = `$true; `$f.ShowInTaskbar = `$false
`$f.FormBorderStyle = 'FixedToolWindow'; `$f.StartPosition = 'Manual'; `$f.Size = New-Object Drawing.Size(360, 90)
`$wa = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
`$f.Location = New-Object Drawing.Point((`$wa.Right - 370), (`$wa.Bottom - 100))
`$l = New-Object Windows.Forms.Label; `$l.Dock = 'Fill'; `$l.TextAlign = 'MiddleCenter'
`$l.Font = New-Object Drawing.Font('Segoe UI', 10); `$f.Controls.Add(`$l)
`$t0 = Get-Date
`$l.Text = "Abriendo tunel a $Machine (puerto $Port)``n0 s"
`$tm = New-Object Windows.Forms.Timer; `$tm.Interval = 500
`$tm.Add_Tick({ `$l.Text = "Abriendo tunel a $Machine (puerto $Port)``n" + [int]((Get-Date) - `$t0).TotalSeconds + ' s'; if (((Get-Date) - `$t0).TotalSeconds -gt 60) { `$f.Close() } })
`$tm.Start(); [void]`$f.ShowDialog()
"@
}

Function Salir {
    param([int]$Codigo)
    if ($script:Ventana) { try { Stop-Process -Id $script:Ventana.Id -Force -ErrorAction SilentlyContinue } catch { } }
    exit $Codigo
}
Function Mostrar {
    param([string]$t)
    if ($SinAvisos) { return }
    $txt = $t -replace "'", "''"
    $null = Lanzar "(New-Object -ComObject WScript.Shell).Popup('$txt', $AvisoSeg, 'Terminus', 0x30 + 0x40000) | Out-Null"
}
Function Aviso {
    param([string]$t)
    Log "ERROR: $t"
    Mostrar $t
    Salir 1
}
Function Fallo {
    param([string]$t)
    Log "ERROR: $t. Ver $(Split-Path $LogSsh -Leaf)"
    $motivo = Get-MotivoFallo $LogSsh
    # Clave rechazada: puede que el usuario guardado ya no sea el bueno
    if ($motivo -match "clave|denied") { Set-UsuarioCache $Machine "" }
    Mostrar "No se pudo abrir el tunel a $Machine.`n`n$motivo`n`nDetalle: $LogSsh"
    Salir 1
}
Log "Inicio (usuario $env:USERNAME, PowerShell $($PSVersionTable.PSVersion))"

# ------------------------------------------------------------------
# BLOQUE 1 - Comprobaciones (locales, sin llamar a Azure: rapido)
# ------------------------------------------------------------------
# El nombre llega de mRemoteNG (%USERFIELD%) y acaba dentro de una orden.
if (-not (Test-NombreSeguro $Machine)) { Aviso "Nombre de equipo no valido: '$Machine'. Revisa el campo de usuario de la conexion en mRemoteNG." }
if (-not $SubscriptionId) { Aviso "Falta SubscriptionId en Operador.config.local.ps1." }
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { Aviso "No se encuentra Azure CLI (az). Cierra y vuelve a abrir mRemoteNG." }

# Ya hay tunel en ese puerto? Entonces nada que hacer
if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) { Log "Ya habia tunel en el puerto"; Salir 0 }

if (-not $KeyFile -and (Test-Path $Op.Clave)) { $KeyFile = $Op.Clave }

# ------------------------------------------------------------------
# BLOQUE 2 - Usuario del tunel (cache local; Azure solo la primera vez)
# ------------------------------------------------------------------
# La sesion de Azure no se comprueba aparte: si no hay, el tunel falla
# enseguida y el aviso lo dice (ahorra 2-3 s por conexion).
if (-not $Usuario) { $Usuario = Get-UsuarioCache $Machine }
if (-not $Usuario) {
    $Usuario = (az resource show --subscription $SubscriptionId --resource-group $ResourceGroup --name $Machine `
                --resource-type "Microsoft.HybridCompute/machines" --query "tags.UsuarioTunel" -o tsv 2>$null | Out-String).Trim()
    if (-not $Usuario) { $Usuario = $Op.UsuarioDefecto }
    if ($Usuario -and (Test-UsuarioSeguro $Usuario)) { Set-UsuarioCache $Machine $Usuario }
}
if (-not $Usuario) { Aviso "El equipo $Machine no tiene etiqueta UsuarioTunel y no hay UsuarioDefecto configurado (o no hay sesion de Azure: az login --tenant $Tenant)." }
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

# Con clave (oculto) la salida va al log de ssh: si falla, ahi esta el motivo.
# El del intento anterior se borra: si no, un error viejo cortaria este.
Remove-Item $LogSsh -Force -ErrorAction SilentlyContinue
$redir  = if ($KeyFile) { " *> '$LogSsh'" } else { "" }
$p = Start-Process powershell -PassThru -WindowStyle $estilo -ArgumentList @(
    "-NoProfile", "-Command",
    "`$Host.UI.RawUI.WindowTitle = 'Tunel $Machine ($Port)'; $orden$redir"
)
Log "Proceso del tunel lanzado (PID $($p.Id))"

# ------------------------------------------------------------------
# BLOQUE 5 - Esperar a que el puerto escuche (o cortar al primer error)
# ------------------------------------------------------------------
$inicio = Get-Date
while (((Get-Date) - $inicio).TotalSeconds -lt $TimeoutSeg) {
    if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) {
        Log "Tunel listo en $([int]((Get-Date) - $inicio).TotalSeconds) s"; Salir 0
    }
    if ($p.HasExited) { Fallo "el proceso del tunel se ha cerrado (codigo $($p.ExitCode))" }
    # Fallos que no cierran el proceso: pide contrasena (clave rechazada), error de az...
    if ((Test-Path $LogSsh) -and (Select-String -Path $LogSsh -Pattern "password:|Permission denied|^ERROR:|IDENTIFICATION HAS CHANGED" -CaseSensitive -Quiet -ErrorAction SilentlyContinue)) {
        taskkill /T /F /PID $p.Id 1>$null 2>$null
        Fallo "el tunel ha fallado"
    }
    Start-Sleep -Milliseconds 500
}
taskkill /T /F /PID $p.Id 1>$null 2>$null
Fallo "el tunel no escucha tras $TimeoutSeg s"
