<#
=====================================================================
 Tunnel-Close.ps1  -  Cierra el tunel Azure Arc de un puerto local
=====================================================================
 Pensado como "Herramienta externa despues" de mRemoteNG: al cerrar
 la pestana RDP se cierra el tunel.

 Uso manual:
   .\Tunnel-Close.ps1 -Port 33401
=====================================================================
#>

param([Parameter(Mandatory)][int]$Port)

# ------------------------------------------------------------------
# BLOQUE 1 - Proceso que escucha en ese puerto
# ------------------------------------------------------------------
# Ventana/proceso oculto del tunel (por si se quedo colgado sin escuchar)
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*Tunel * ($Port)'*" } |
    ForEach-Object { taskkill /T /F /PID $_.ProcessId 1>$null 2>$null }

$conns = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if (-not $conns) { exit 0 }

# ------------------------------------------------------------------
# BLOQUE 2 - Cerrar solo si es ssh (no matar otras cosas)
# ------------------------------------------------------------------
foreach ($procId in ($conns.OwningProcess | Select-Object -Unique)) {
    $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
    if ($p -and $p.ProcessName -eq "ssh") {
        taskkill /T /F /PID $procId 1>$null 2>$null     # /T: tambien el proxy de Arc
    }
}
exit 0
