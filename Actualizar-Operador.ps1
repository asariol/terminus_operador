<#
=====================================================================
 Actualizar-Operador.ps1  -  Baja la ultima version de los scripts
=====================================================================
 Descarga el zip del repositorio publico y sustituye los scripts de
 esta carpeta. NO toca la configuracion local ni la clave privada.

 Uso:
   .\Actualizar-Operador.ps1
=====================================================================
#>

param([string]$Url = "https://github.com/asariol/terminus_operador/archive/refs/heads/main.zip")

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$tmp = Join-Path $env:TEMP "terminus_operador_$(Get-Random)"
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
try {
    Invoke-WebRequest -Uri $Url -OutFile "$tmp\o.zip" -UseBasicParsing
    Expand-Archive "$tmp\o.zip" $tmp -Force
    $origen = Get-ChildItem $tmp -Directory | Select-Object -First 1
    # Solo scripts y documentacion: config local y clave no vienen en el zip.
    $nuevos = Get-ChildItem $origen.FullName -File | Where-Object { $_.Extension -in ".ps1", ".md" }
    foreach ($f in $nuevos) { Copy-Item $f.FullName $PSScriptRoot -Force }
    Write-Host "Actualizados $($nuevos.Count) ficheros en $PSScriptRoot" -ForegroundColor Green
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
