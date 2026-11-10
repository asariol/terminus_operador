<#
=====================================================================
 Habilitar-Acceso.ps1  -  Activa el acceso SSH por Arc en los equipos
=====================================================================
 Despues de instalar Terminus en un cliente ([I] del menu), hay que
 crear UNA vez su "endpoint" de conectividad y la configuracion SSH
 (puerto 22). Lo hace el operador que ha instalado el cliente (rol
 "Terminus - Habilitar acceso" del grupo de operadores).

 Uso:
   .\Habilitar-Acceso.ps1                    -> revisa TODOS los equipos y habilita los que falten
   .\Habilitar-Acceso.ps1 -Maquina C001-GestoriaPerez-SRV1
   .\Habilitar-Acceso.ps1 -SoloRevisar       -> no cambia nada, solo informa
   .\Habilitar-Acceso.ps1 -Maquina <equipo> -Usuario "usuario@DOMINIO"
        -> corrige la etiqueta UsuarioTunel (usuario con el que entra el tunel).
           Normalmente la pone el instalador; sin ella se usa UsuarioDefecto.
=====================================================================
#>

param(
    [string]$Maquina,
    [string]$ResourceGroup = "",
    [int]   $Puerto        = 22,
    [string]$Usuario,                       # opcional: fija la etiqueta UsuarioTunel
    [switch]$SoloRevisar
)

$ErrorActionPreference = "Continue"
$API = "2023-03-15"

. (Join-Path $PSScriptRoot "Comun.ps1")
if (-not $ResourceGroup) { $ResourceGroup = $Op.ResourceGroup }

# ------------------------------------------------------------------
# BLOQUE 1 - Sesion (la suscripcion configurada, no la de por defecto)
# ------------------------------------------------------------------
$sub = $Op.SubscriptionId
if (-not $sub) { Write-Host "Falta SubscriptionId en Operador.config.local.ps1." -ForegroundColor Red; exit 1 }
az account show --subscription $sub --only-show-errors 1>$null 2>$null
if ($LASTEXITCODE -ne 0) { az login --tenant $Op.Tenant --only-show-errors 1>$null }
az account set --subscription $sub 2>$null
if ($LASTEXITCODE -ne 0) { Write-Host "Sin sesion de Azure: az login --tenant $($Op.Tenant)" -ForegroundColor Red; exit 1 }

# ------------------------------------------------------------------
# BLOQUE 2 - Equipos a revisar
# ------------------------------------------------------------------
$todas = az resource list --subscription $sub --resource-group $ResourceGroup --resource-type "Microsoft.HybridCompute/machines" `
         --query "[].{Nombre:name, Cliente:tags.Cliente, Usuario:tags.UsuarioTunel, Id:id}" -o json | ConvertFrom-Json
if ($Maquina) { $todas = @($todas | Where-Object { $_.Nombre -eq $Maquina }) }
if (-not $todas) { Write-Host "No hay equipos que revisar." -ForegroundColor Yellow; exit 0 }

# Etiqueta UsuarioTunel (solo con -Maquina, para no cambiar todos a la vez)
if ($Usuario) {
    if (-not $Maquina) { Write-Host "-Usuario solo se puede usar junto con -Maquina." -ForegroundColor Red; exit 1 }
    # Lo usa luego el operador dentro de una orden: solo caracteres seguros, sin "\".
    if (-not (Test-UsuarioSeguro $Usuario)) { Write-Host "Usuario no valido. Formato: usuario o usuario@DOMINIO" -ForegroundColor Red; exit 1 }
    az tag update --resource-id $todas[0].Id --operation Merge --tags "UsuarioTunel=$Usuario" --only-show-errors 1>$null
    if ($LASTEXITCODE -eq 0) { $todas[0].Usuario = $Usuario; Write-Host "Etiqueta UsuarioTunel=$Usuario" -ForegroundColor Green }
    else { Write-Host "No se pudo poner la etiqueta." -ForegroundColor Red }
}

# Cuerpos JSON en fichero temporal: evita problemas de comillas con az.cmd.
$tmpEp  = New-TemporaryFile
$tmpSsh = New-TemporaryFile
Set-Content $tmpEp  '{"properties":{"type":"default"}}' -Encoding ASCII
Set-Content $tmpSsh ('{"properties":{"serviceName":"SSH","port":' + $Puerto + '}}') -Encoding ASCII

# ------------------------------------------------------------------
# BLOQUE 3 - Revisar / crear endpoint y servicio SSH
# ------------------------------------------------------------------
$informe = foreach ($m in $todas) {
    $base = "https://management.azure.com/subscriptions/$sub/resourceGroups/$ResourceGroup" +
            "/providers/Microsoft.HybridCompute/machines/$($m.Nombre)" +
            "/providers/Microsoft.HybridConnectivity/endpoints/default"

    # Se pide solo el dato que interesa (--query): no depende de como
    # llega el JSON completo a PowerShell.
    $tipo = (az rest --method get --uri "$base`?api-version=$API" --query "properties.type" -o tsv 2>$null | Out-String).Trim()
    $tieneEp = ($LASTEXITCODE -eq 0 -and $tipo -eq "default")
    $puertoActual = (az rest --method get --uri "$base/serviceconfigurations/SSH`?api-version=$API" --query "properties.port" -o tsv 2>$null | Out-String).Trim()
    $tieneSsh = ($LASTEXITCODE -eq 0 -and $puertoActual -eq "$Puerto")

    $accion = "Ya estaba"
    if (-not ($tieneEp -and $tieneSsh)) {
        if ($SoloRevisar) { $accion = "FALTA" }
        else {
            if (-not $tieneEp) { az rest --method put --uri "$base`?api-version=$API" --body "@$tmpEp" 1>$null }
            az rest --method put --uri "$base/serviceconfigurations/SSH`?api-version=$API" --body "@$tmpSsh" 1>$null
            $accion = if ($LASTEXITCODE -eq 0) { "Habilitado" } else { "ERROR" }
        }
    }
    $usr = if ($m.Usuario) { $m.Usuario } else { "$($Op.UsuarioDefecto) (sin etiqueta)" }
    [pscustomobject]@{ Equipo = $m.Nombre; Cliente = $m.Cliente; Usuario = $usr; Acceso = $accion }
}

Remove-Item $tmpEp, $tmpSsh -ErrorAction SilentlyContinue
$informe | Sort-Object Cliente, Equipo | Format-Table -AutoSize
if ($informe | Where-Object Acceso -eq "ERROR") {
    Write-Host "Sin permisos para habilitar: el grupo de operadores necesita el rol 'Terminus - Habilitar acceso' (avisar al administrador)." -ForegroundColor Yellow
}
