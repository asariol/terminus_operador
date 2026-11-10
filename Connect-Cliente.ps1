<#
=====================================================================
 Connect-Cliente.ps1  -  Conexion RDP a un cliente via Azure Arc
 (alternativa sin mRemoteNG)
=====================================================================
 Uso:
   .\Connect-Cliente.ps1                          -> lista los clientes disponibles
   .\Connect-Cliente.ps1 C001-GestoriaPerez-SRV1  -> tunel + RDP a ese equipo
   .\Connect-Cliente.ps1 "Gestoria Perez"         -> tambien por la etiqueta Cliente
   .\Connect-Cliente.ps1 C001                     -> o por la etiqueta Codigo

 Que hace:
   1. Comprueba la sesion de Azure (si no hay, hace az login).
   2. Busca el equipo por nombre o etiquetas Cliente / Codigo.
   3. Elige un puerto local libre (desde 33400).
   4. Abre el tunel con Tunnel-Open.ps1 (mismo comportamiento que desde mRemoteNG).
   5. Abre mstsc y, al cerrarlo, cierra el tunel.
=====================================================================
#>

param(
    [string]$Cliente,
    [int]   $PortInicial = 33400
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Comun.ps1")

# ------------------------------------------------------------------
# BLOQUE 1 - Sesion de Azure
# ------------------------------------------------------------------
az account show --subscription $Op.SubscriptionId --only-show-errors 1>$null 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "No hay sesion de Azure. Iniciando sesion..." -ForegroundColor Yellow
    az login --tenant $Op.Tenant --only-show-errors 1>$null
    if ($LASTEXITCODE -ne 0) { throw "No se pudo iniciar sesion en Azure." }
}
Write-Host "Sesion: $(az account show --subscription $Op.SubscriptionId --query user.name -o tsv)" -ForegroundColor DarkGray

# ------------------------------------------------------------------
# BLOQUE 2 - Equipos visibles para este operador
# ------------------------------------------------------------------
$maquinas = az resource list --subscription $Op.SubscriptionId --resource-group $Op.ResourceGroup `
            --resource-type "Microsoft.HybridCompute/machines" `
            --query "[].{Nombre:name, Codigo:tags.Codigo, Cliente:tags.Cliente}" -o json | ConvertFrom-Json
if (-not $maquinas) { throw "No hay ningun equipo visible en $($Op.ResourceGroup)." }

if (-not $Cliente) {
    Write-Host "`nClientes disponibles:" -ForegroundColor Cyan
    $maquinas | Sort-Object Codigo, Nombre | Format-Table -AutoSize
    Write-Host "Uso: .\Connect-Cliente.ps1 <Nombre | Codigo | Cliente>"
    return
}

# ------------------------------------------------------------------
# BLOQUE 3 - Resolver el cliente pedido
# ------------------------------------------------------------------
$destino = @($maquinas | Where-Object { $_.Nombre -eq $Cliente -or $_.Codigo -eq $Cliente -or $_.Cliente -eq $Cliente })
if ($destino.Count -eq 0) { throw "No encuentro '$Cliente'." }
if ($destino.Count -gt 1) { $destino | Format-Table -AutoSize; throw "Hay varios equipos para '$Cliente'. Indica el nombre exacto." }
$nombre = $destino[0].Nombre
Write-Host "Equipo: $nombre" -ForegroundColor Green

# ------------------------------------------------------------------
# BLOQUE 4 - Puerto local libre
# ------------------------------------------------------------------
$port = $PortInicial
while (Get-NetTCPConnection -LocalPort $port -ErrorAction SilentlyContinue) { $port++ }

# ------------------------------------------------------------------
# BLOQUE 5 - Tunel (el mismo script que usa mRemoteNG)
# ------------------------------------------------------------------
Write-Host "Abriendo tunel en el puerto $port..." -ForegroundColor Yellow
& (Join-Path $PSScriptRoot "Tunnel-Open.ps1") -Machine $nombre -Port $port
if ($LASTEXITCODE -ne 0) { throw "El tunel no se abrio. Ver tunnel.log y tunnel_ssh_$port.log en $PSScriptRoot" }
Write-Host "Tunel listo." -ForegroundColor Green

# ------------------------------------------------------------------
# BLOQUE 6 - RDP y cierre
# ------------------------------------------------------------------
try { Start-Process mstsc -ArgumentList "/v:127.0.0.1:$port" -Wait }
finally {
    & (Join-Path $PSScriptRoot "Tunnel-Close.ps1") -Port $port
    Write-Host "Sesion cerrada. Tunel hacia $nombre cerrado." -ForegroundColor Cyan
}
