<#
=====================================================================
 Comun.ps1  -  Configuracion comun de los scripts de operador
=====================================================================
 Valores genericos aqui. Los del entorno (suscripcion, tenant...) van
 en Operador.config.local.ps1, junto a los scripts, que NO esta en el
 repositorio. Lo crea el bloque de Bitwarden al instalar:

   $OperadorLocal = @{
       SubscriptionId = "<guid>"
       Tenant         = "<dominio o guid del tenant>"
       UsuarioDefecto = "<usuario del tunel si el equipo no tiene etiqueta>"
       ClavePrivada   = @"
   -----BEGIN OPENSSH PRIVATE KEY-----
   ...
   -----END OPENSSH PRIVATE KEY-----
   "@
   }

 ClavePrivada solo se usa una vez: Preparar-Operador la guarda en
 terminus_ed25519 (solo para este usuario) y la borra de la config.
=====================================================================
#>

$Op = @{
    ResourceGroup  = "rg-acceso-clientes"
    SubscriptionId = ""
    Tenant         = ""
    UsuarioDefecto = ""
    Clave          = Join-Path $PSScriptRoot "terminus_ed25519"
}

$OpConfigLocal = Join-Path $PSScriptRoot "Operador.config.local.ps1"
if (Test-Path $OpConfigLocal) {
    . $OpConfigLocal
    if ($OperadorLocal) { foreach ($k in $OperadorLocal.Keys) { $Op[$k] = $OperadorLocal[$k] } }
}

# Nombres que llegan de mRemoteNG o de etiquetas de Azure y acaban dentro
# de una orden: solo caracteres seguros (evita inyeccion de comandos).
Function Test-NombreSeguro { param([string]$Valor) return ($Valor -match '^[A-Za-z0-9._-]+$') }
Function Test-UsuarioSeguro { param([string]$Valor) return ($Valor -match '^[A-Za-z0-9._-]+(@[A-Za-z0-9._-]+)?$') }

# Motivo legible de un tunel fallido, a partir de su log de ssh.
Function Get-MotivoFallo {
    param([string]$LogSsh)
    if (-not (Test-Path $LogSsh)) { return "" }
    $lineas = @(Get-Content $LogSsh -ErrorAction SilentlyContinue)
    $m = $lineas | Where-Object { $_ -cmatch '^ERROR:|denied|not found|refused|IDENTIFICATION' } | Select-Object -Last 1
    if ($m -match "az login|AADSTS|expired|re-authenticate") { return "No hay sesion de Azure: az login --tenant $($Op.Tenant)" }
    if (-not $m -and ($lineas -match 'password:')) { return "El servidor no acepta la clave (pide contrasena). Avisar al administrador." }
    if ($m -match "IDENTIFICATION") { return "Huella del servidor cambiada (reinstalado?): ssh-keygen -R <nombre-en-minusculas>" }
    return "$m".Trim()
}

# Usuario del tunel de cada equipo, guardado en este PC (evita preguntar a
# Azure en cada conexion). Se borra la entrada si el tunel falla por la clave.
$OpCacheUsuarios = Join-Path $PSScriptRoot "usuarios.cache"
Function Get-UsuarioCache {
    param([string]$Maquina)
    if (-not (Test-Path $OpCacheUsuarios)) { return "" }
    $l = Get-Content $OpCacheUsuarios -ErrorAction SilentlyContinue | Where-Object { $_ -like "$Maquina=*" } | Select-Object -Last 1
    if ($l) { return $l.Substring($Maquina.Length + 1) } else { return "" }
}
Function Set-UsuarioCache {
    param([string]$Maquina, [string]$Usuario)
    $resto = @()
    if (Test-Path $OpCacheUsuarios) { $resto = @(Get-Content $OpCacheUsuarios -ErrorAction SilentlyContinue | Where-Object { $_ -notlike "$Maquina=*" }) }
    if ($Usuario) { $resto += "$Maquina=$Usuario" }
    try { $resto | Set-Content $OpCacheUsuarios -Encoding ASCII -ErrorAction Stop } catch { }
}
