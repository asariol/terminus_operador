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
