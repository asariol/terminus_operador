<#
=====================================================================
 Iniciar-Dia.ps1  -  Inicio del dia: login y tuneles abiertos a la vez
=====================================================================
 1. Inicia sesion en Azure (MFA) si hace falta.
 2. Lee de mRemoteNG las conexiones que usan Terminus-Abrir.
 3. Pregunta cuales abrir (la primera vez, o si no se quieren las de ayer).
 4. Abre todos esos tuneles EN PARALELO y muestra como van.

 Despues, al abrir las conexiones en mRemoteNG, el tunel ya esta y
 conecta al momento. Al cerrar una pestana se cierra su tunel, como siempre.

 Uso (acceso directo "Terminus - Iniciar dia" del escritorio):
   .\Iniciar-Dia.ps1            -> pregunta (o repite la seleccion anterior)
   .\Iniciar-Dia.ps1 -Elegir    -> vuelve a elegir
=====================================================================
#>

param(
    [switch]$Elegir,
    [string]$Conexiones = "$env:APPDATA\mRemoteNG\confCons.xml",
    [int]   $TimeoutSeg = 40
)

. (Join-Path $PSScriptRoot "Comun.ps1")
$Host.UI.RawUI.WindowTitle = "Terminus - Iniciar dia"
$Seleccion = Join-Path $PSScriptRoot "iniciar_dia.seleccion"

# ------------------------------------------------------------------
# BLOQUE 1 - Sesion de Azure
# ------------------------------------------------------------------
Write-Host "Comprobando sesion de Azure..." -ForegroundColor Cyan
az account show --subscription $Op.SubscriptionId --only-show-errors 1>$null 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Sin sesion: se abre el login (cuenta de la empresa + MFA)." -ForegroundColor Yellow
    az login --tenant $Op.Tenant --only-show-errors 1>$null
    az account show --subscription $Op.SubscriptionId --only-show-errors 1>$null 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Host "No hay sesion. Cancelado." -ForegroundColor Red; Read-Host "Intro para salir"; exit 1 }
}
Write-Host "Sesion: $(az account show --query user.name -o tsv)" -ForegroundColor Green

# ------------------------------------------------------------------
# BLOQUE 2 - Conexiones Terminus de mRemoteNG
# ------------------------------------------------------------------
if (-not (Test-Path $Conexiones)) { Write-Host "No encuentro $Conexiones" -ForegroundColor Red; Read-Host "Intro para salir"; exit 1 }
$xml = New-Object Xml.XmlDocument
$xml.Load($Conexiones)
if ($xml.DocumentElement.GetAttribute("FullFileEncryption") -eq "true") {
    Write-Host "El fichero de mRemoteNG tiene cifrado completo: no se puede leer." -ForegroundColor Red; Read-Host "Intro para salir"; exit 1
}

# Valor de un campo teniendo en cuenta la herencia de carpetas de mRemoteNG
Function Get-Valor {
    param($Nodo, [string]$Campo)
    $n = $Nodo
    while ($n -and $n.LocalName -eq "Node") {
        if ($n.GetAttribute("Inherit$Campo") -ne "true") { return $n.GetAttribute($Campo) }
        $n = $n.ParentNode
    }
    return ""
}

$lista = foreach ($n in $xml.SelectNodes("//*[local-name()='Node' and @Type='Connection']")) {
    if ((Get-Valor $n "PreExtApp") -ne "Terminus-Abrir") { continue }
    $maq = Get-Valor $n "UserField"
    [pscustomobject]@{
        Conexion = $n.GetAttribute("Name")
        Equipo   = $maq
        Puerto   = [int](Get-Valor $n "Port")
        Valido   = (Test-NombreSeguro $maq)
    }
}
$lista = @($lista | Sort-Object Conexion)
$malas = @($lista | Where-Object { -not $_.Valido })
foreach ($m in $malas) { Write-Host "  Sin Campo de usuario valido: $($m.Conexion) (se ignora)" -ForegroundColor Yellow }
$lista = @($lista | Where-Object Valido)
if (-not $lista) { Write-Host "No hay conexiones con Terminus-Abrir en mRemoteNG." -ForegroundColor Red; Read-Host "Intro para salir"; exit 1 }

# ------------------------------------------------------------------
# BLOQUE 3 - Cuales abrir (se recuerda la ultima seleccion)
# ------------------------------------------------------------------
$anteriores = @()
if ((Test-Path $Seleccion) -and -not $Elegir) { $anteriores = @(Get-Content $Seleccion) }
$elegidas = @($lista | Where-Object { $anteriores -contains $_.Conexion })
if ($elegidas) {
    Write-Host "`nUltima seleccion: $($elegidas.Conexion -join ', ')" -ForegroundColor Cyan
    if ((Read-Host "Abrir las mismas? (S/N)") -notmatch '^[sS]') { $elegidas = @() }
}
if (-not $elegidas) {
    $elegidas = @($lista | Out-GridView -Title "Terminus: elige los clientes a abrir (Ctrl+clic para varios) y pulsa Aceptar" -PassThru)
    if (-not $elegidas) { Write-Host "Nada elegido." -ForegroundColor Yellow; exit 0 }
    $elegidas.Conexion | Set-Content $Seleccion -Encoding UTF8
}

# Dos conexiones con el mismo puerto no pueden estar abiertas a la vez
$dup = $elegidas | Group-Object Puerto | Where-Object Count -gt 1
foreach ($d in $dup) {
    Write-Host "  Puerto $($d.Name) repetido ($($d.Group.Conexion -join ', ')): solo se abre $($d.Group[0].Conexion)" -ForegroundColor Yellow
}
$elegidas = @($elegidas | Group-Object Puerto | ForEach-Object { $_.Group[0] })

# ------------------------------------------------------------------
# BLOQUE 4 - Abrir todos los tuneles a la vez
# ------------------------------------------------------------------
$tunelPs1 = Join-Path $PSScriptRoot "Tunnel-Open.ps1"
foreach ($c in $elegidas) {
    $c | Add-Member Proceso (Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $tunelPs1,
        "-Machine", $c.Equipo, "-Port", $c.Puerto, "-SinAvisos")) -Force
    $c | Add-Member Estado "Abriendo..." -Force
}

# Tabla que se va actualizando hasta que todos terminan
$inicio = Get-Date
do {
    foreach ($c in $elegidas) {
        if ($c.Estado -ne "Abriendo...") { continue }
        if (Get-NetTCPConnection -LocalPort $c.Puerto -State Listen -ErrorAction SilentlyContinue) { $c.Estado = "OK" }
        elseif ($c.Proceso.HasExited) {
            $m = Get-MotivoFallo (Join-Path $PSScriptRoot "tunnel_ssh_$($c.Equipo)_$($c.Puerto).log")
            $c.Estado = "ERROR: $(if ($m) { $m } else { 'ver tunnel.log' })"
        }
    }
    Clear-Host
    Write-Host "TERMINUS - Iniciar dia   ($([int]((Get-Date) - $inicio).TotalSeconds) s)`n" -ForegroundColor Cyan
    foreach ($c in $elegidas) {
        $color = switch -Wildcard ($c.Estado) { "OK" { "Green" } "ERROR*" { "Red" } default { "Yellow" } }
        Write-Host ("  {0,-28} {1,6}  {2}" -f $c.Conexion, $c.Puerto, $c.Estado) -ForegroundColor $color
    }
    $pendientes = @($elegidas | Where-Object Estado -eq "Abriendo...")
    if ($pendientes) { Start-Sleep -Milliseconds 700 }
} while ($pendientes -and ((Get-Date) - $inicio).TotalSeconds -lt $TimeoutSeg)
foreach ($c in $pendientes) { $c.Estado = "ERROR: no responde" }

$ok = @($elegidas | Where-Object Estado -eq "OK").Count
Write-Host "`n$ok de $($elegidas.Count) tuneles abiertos. Ya puedes conectar desde mRemoteNG." -ForegroundColor $(if ($ok -eq $elegidas.Count) { "Green" } else { "Yellow" })
Write-Host "(Para elegir otros clientes: Iniciar-Dia.ps1 -Elegir)" -ForegroundColor DarkGray
Read-Host "`nIntro para cerrar esta ventana"
