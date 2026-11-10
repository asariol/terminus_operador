# Terminus (operador)

Scripts para que un operador de soporte se conecte por RDP a servidores de clientes a traves de **Azure Arc** (tunel SSH), desde mRemoteNG o desde la linea de comandos.

Este repositorio es generico: no contiene datos de ningun entorno ni claves. Los datos del entorno y la clave privada se entregan aparte (gestor de contrasenas) y se quedan solo en el PC del operador.

## Requisitos

- Windows 10/11 con PowerShell 5.1.
- Cuenta de Entra ID dentro del grupo de operadores (la da de alta el propietario del grupo).
- mRemoteNG instalado (opcional: tambien se puede conectar con `Connect-Cliente.ps1`).

## Instalacion (5 minutos)

Abrir **PowerShell como Administrador** con el usuario de Windows del propio operador.

**1. Descargar los scripts** en `C:\Terminus\operador`:

```powershell
[Net.ServicePointManager]::SecurityProtocol=3072; $ProgressPreference='SilentlyContinue'; iwr https://github.com/asariol/terminus_operador/archive/refs/heads/main.zip -OutFile $env:TEMP\to.zip -UseBasicParsing; Expand-Archive $env:TEMP\to.zip $env:TEMP\to -Force; New-Item C:\Terminus\operador -ItemType Directory -Force | Out-Null; Copy-Item $env:TEMP\to\terminus_operador-main\* C:\Terminus\operador -Force; Remove-Item $env:TEMP\to, $env:TEMP\to.zip -Recurse -Force
```

**2. Pegar el bloque de configuracion** que entrega el administrador (por ejemplo un *Send* de Bitwarden de un solo uso). Tiene esta forma:

```powershell
@'
$OperadorLocal = @{
    SubscriptionId = "<guid de la suscripcion>"
    Tenant         = "<dominio del tenant>"
    UsuarioDefecto = "<usuario del tunel si el equipo no tiene etiqueta>"
    ClavePrivada   = @"
-----BEGIN OPENSSH PRIVATE KEY-----
...
-----END OPENSSH PRIVATE KEY-----
"@
}
'@ | Set-Content C:\Terminus\operador\Operador.config.local.ps1 -Encoding ASCII; powershell -NoProfile -ExecutionPolicy Bypass -File C:\Terminus\operador\Preparar-Operador.ps1
```

`Preparar-Operador.ps1` hace el resto: Azure CLI + extension ssh, permisos de la carpeta, guarda la clave solo para este usuario (y la borra de la configuracion y del historial de PowerShell), crea las herramientas externas de mRemoteNG e inicia sesion en Azure.

## Uso diario

- Cada manana: `az login --tenant <tenant>` (MFA).
- En mRemoteNG, cada conexion de cliente:
  - **Host**: `127.0.0.1`
  - **Puerto**: el del cliente (uno distinto por cliente)
  - **Campo de usuario**: nombre del equipo en Azure (ej. `C001-GestoriaPerez-SRV1`)
  - **Herramienta externa antes**: `Terminus-Abrir` / **despues**: `Terminus-Cerrar`
  - Usuario y contrasena RDP: los del servidor, como siempre.
- Sin mRemoteNG: `C:\Terminus\operador\Connect-Cliente.ps1` lista los equipos y conecta.

## Ficheros

| Fichero | Que hace |
|---|---|
| `Preparar-Operador.ps1` | Instalacion del PC (se puede repetir). |
| `Tunnel-Open.ps1` / `Tunnel-Close.ps1` | Abren y cierran el tunel (los llama mRemoteNG). |
| `Connect-Cliente.ps1` | Tunel + RDP sin mRemoteNG. |
| `Configurar-mRemoteNG.ps1` | Crea las herramientas externas Terminus-Abrir / Terminus-Cerrar. |
| `Actualizar-Operador.ps1` | Baja la ultima version de los scripts (no toca configuracion ni clave). |
| `Comun.ps1` | Configuracion comun; lee `Operador.config.local.ps1`. |

## Diagnostico

En `C:\Terminus\operador`:

- `tunnel.log`: cada intento de tunel, con el motivo si falla.
- `tunnel_ssh_<puerto>.log`: salida del ultimo tunel en ese puerto.

Errores tipicos: *No hay sesion de Azure* (hacer `az login --tenant ...` con la cuenta de la empresa), *Permission denied* (clave o usuario del servidor), *not found* (el equipo no esta habilitado todavia).

## Seguridad

- La clave privada solo la puede leer el usuario de Windows del operador. Nunca va en este repositorio.
- Para entrar hacen falta las dos cosas: la clave **y** una cuenta de la empresa con MFA dentro del grupo de operadores. Sacar a alguien del grupo le quita el acceso a todos los clientes.
- En el servidor, la clave solo vale para conexiones que llegan por Arc y solo permite redirigir al RDP.
- Los nombres de equipo y usuario que llegan de mRemoteNG o de Azure se validan antes de usarlos en una orden.
