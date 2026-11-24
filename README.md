# bash-sysadmin-toolkit

![Licencia: MIT](https://img.shields.io/badge/licencia-MIT-green)

Colección de **8 scripts de Bash** para las tareas del día a día de un administrador de sistemas Linux:
vigilar disco, servicios y puertos, limpiar logs, hacer copias rotativas y auditar usuarios y SSH.
Todos comparten una librería común, usan los mismos códigos de salida que los plugins de **Nagios**
(así se pueden enchufar a cron, systemd o a un sistema de monitorización) y tienen **129 tests** con bats.

## Por qué existe

Son las pequeñas herramientas que se acaban escribiendo en cualquier puesto de sistemas o soporte N2,
pero hechas con cuidado:

- **Seguras por defecto**: lo destructivo (`clean-logs`) simula salvo que se pida `--apply`, y rechaza rutas peligrosas.
- **Predecibles**: `set -euo pipefail`, argumentos validados, ayuda con `-h` y códigos de salida documentados.
- **Automatizables**: salida legible por personas y por máquinas, ejemplos de `systemd` y `cron` incluidos.
- **Probadas**: cada script tiene tests que nunca tocan ficheros reales del sistema (stubs en el `PATH` y directorios temporales).

## Requisitos

Bash 4.4 o superior (probado con Bash 5) y las utilidades habituales de una distribución Linux:
`coreutils`, `findutils`, `util-linux` (`flock`), `iproute2` (`ss`), `tar`, `gzip` y `systemd` (solo para `check-services`).
Para desarrollar: [`shellcheck`](https://www.shellcheck.net/) y [`bats`](https://github.com/bats-core/bats-core).

## Instalación

```bash
git clone https://github.com/dgr-devops/bash-sysadmin-toolkit.git
cd bash-sysadmin-toolkit
make install                     # enlaces en ~/.local/bin
# o, para todo el sistema:
sudo make install PREFIX=/usr/local
```

`make install` crea un enlace simbólico por script, sin la extensión (`check-disk`, `clean-logs`...).
Los scripts localizan su librería a través del enlace, así que funcionan desde cualquier directorio.
`make uninstall` elimina solo los enlaces que apuntan a este repositorio. `make help` lista todos los objetivos.

### Configuración (opcional)

```bash
cp config/toolkit.conf.example ~/.config/toolkit.conf   # o /etc/toolkit.conf
```

El fichero guarda valores por defecto (puertos permitidos, días de retención, destino de copias...).
Prioridad: **opciones de la línea de comandos > variables de entorno > fichero**.
Se lee como datos (`TOOLKIT_NOMBRE=valor`), nunca se ejecuta como shell. No debe contener secretos.

## Uso

Todas las salidas de esta sección son **reales**: se capturaron ejecutando los scripts del repositorio.
Los ejemplos que modifican ficheros se ejecutaron en un directorio temporal (abreviado como `<demo>`).

### Códigos de salida

| Código | Significado |
|-------:|-------------|
| `0` | Todo correcto |
| `1` | Aviso (WARNING) |
| `2` | Crítico (CRITICAL) o fallo de una operación |
| `3` | Desconocido: no se pudo comprobar |
| `64` | Uso incorrecto (argumentos o rutas no válidos) |

Cada script documenta en `-h` qué códigos puede devolver.

### `sysinfo.sh` — resumen del sistema

```console
$ sysinfo
Host:      cachyos
SO:        CachyOS
Kernel:    7.3.4-1-cachyos
CPU:       Intel(R) Core(TM) Ultra 7 155H (22 núcleos)
Memoria:   13720 / 31643 MiB (43%)
Carga:     6.03 (1 min)
Uptime:    up 22 minutes
```

### `check-disk.sh` — umbrales de uso de disco

```console
$ check-disk -w 80 -c 90 / /boot
OK         31%  /
OK         10%  /boot
$ echo $?
0

$ check-disk -w 30 -c 50 /          # umbral bajo para forzar el aviso
WARNING    31%  /
$ echo $?
1
```

Sin rutas revisa todos los sistemas de ficheros reales (ignora `tmpfs`, `overlay`, `squashfs`...).

### `check-services.sh` — servicios de systemd

```console
$ check-services bluetooth sshd
OK        bluetooth
CRITICAL  sshd (inactive)
$ echo $?
2

$ check-services bluetooth servicio-inventado
OK        bluetooth
UNKNOWN   servicio-inventado (no existe)
$ echo $?
3
```

Con `-r` (solo root) reinicia los servicios caídos y vuelve a comprobarlos.
Si hay a la vez servicios caídos e inexistentes, gana el `2`.

### `check-ports.sh` — puertos en escucha frente a una lista permitida

Lee `ss -tulnp` y marca los puertos expuestos que no están en la lista. Por defecto ignora los que solo
escuchan en loopback (no son accesibles desde fuera) y agrupa IPv4 e IPv6 del mismo puerto.
Ejemplo ejecutado en un espacio de red aislado (`unshare -rn`) con dos servidores HTTP de prueba:

```console
$ check-ports -a 22,8080
OK        tcp  8080   0.0.0.0              python3
WARNING   tcp  9090   0.0.0.0              python3
2026-11-24 09:24:42 [WARN] 1 puerto(s) en escucha que no están en la lista de permitidos
$ echo $?
1
```

Opciones: `-a 22,80,443` (lista), `-f fichero` (un puerto por línea, admite `#`), `-i` (incluir loopback).
Sin lista de permitidos solo informa y devuelve `0`.

### `clean-logs.sh` — comprimir y borrar logs antiguos

Comprime con gzip los `*.log` de más de `-c` días (7 por defecto) y borra los de más de `-d` días (30).
**Por defecto solo simula**; hay que pasar `--apply` para actuar.

```console
$ clean-logs logs
2026-11-24 09:24:56 [INFO] Directorio: <demo>/logs (modo dry-run; comprimir > 7 d, borrar > 30 d)
[dry-run] DELETE <demo>/logs/viejo.log
[dry-run] COMPRESS <demo>/logs/error.log.1
[dry-run] COMPRESS <demo>/logs/access.log
[dry-run] Resumen: 2 comprimidos, 1 borrados, 4 KiB liberados por el borrado
2026-11-24 09:24:56 [INFO] Simulación: no se ha modificado nada. Usa --apply para ejecutar.

$ clean-logs --apply logs
2026-11-24 09:24:56 [INFO] Directorio: <demo>/logs (modo apply; comprimir > 7 d, borrar > 30 d)
DELETE    <demo>/logs/viejo.log
COMPRESS  <demo>/logs/error.log.1
COMPRESS  <demo>/logs/access.log
Resumen: 2 comprimidos, 1 borrados, 4 KiB liberados por el borrado
```

Se niega a trabajar con rutas vacías o peligrosas (código `64`):

```console
$ clean-logs --apply /etc
2026-11-24 09:24:56 [ERROR] Directorio protegido, no se limpia: /etc
$ clean-logs ""
2026-11-24 09:24:56 [ERROR] La ruta del directorio está vacía
```

Solo toca ficheros regulares `*.log` y `*.log.*`; no sigue enlaces simbólicos, no sale del sistema de
ficheros y no entra en subdirectorios salvo con `-r`.

### `backup-rotate.sh` — copias tar.gz rotativas con checksum

Crea `NOMBRE-AAAAMMDD-HHMMSS.tar.gz` y su `.sha256`, verifica el checksum, conserva solo las últimas `-k`
copias y usa `flock` para que dos ejecuciones simultáneas no se pisen (la segunda sale con código `1`).
Ejemplo con `-k 2`, ejecutado tres veces seguidas:

```console
$ backup-rotate -d <demo>/copias -k 2 -n datos datos
OK        <demo>/copias/datos-20261124-092456.tar.gz (0 KiB)
OK        checksum SHA-256 verificado: <demo>/copias/datos-20261124-092456.tar.gz.sha256
...
OK        <demo>/copias/datos-20261124-092458.tar.gz (0 KiB)
OK        checksum SHA-256 verificado: <demo>/copias/datos-20261124-092458.tar.gz.sha256
DELETE    <demo>/copias/datos-20261124-092456.tar.gz

$ ls <demo>/copias
datos-20261124-092457.tar.gz
datos-20261124-092457.tar.gz.sha256
datos-20261124-092458.tar.gz
datos-20261124-092458.tar.gz.sha256

$ cd <demo>/copias && sha256sum --check datos-*.tar.gz.sha256
datos-20261124-092457.tar.gz: La suma coincide
datos-20261124-092458.tar.gz: La suma coincide
```

La rotación borró la copia más antigua junto con su `.sha256`. Con `--dry-run` muestra qué crearía y
borraría sin tocar nada. Rechaza orígenes inexistentes, `/` y un destino dentro del origen.

### `user-audit.sh` — auditoría de cuentas

Muestra cuentas con UID 0, usuarios con shell de login, miembros de `sudo`/`wheel`/`admin`, reglas de
`sudoers`, contraseñas vacías y últimos accesos. **Solo lee**. Con `-r RAIZ` audita otro árbol
(una copia montada o, aquí, ficheros de ejemplo sintéticos del repositorio):

```console
$ user-audit -r tests/fixtures/rootfs
== Cuentas con UID 0 ==
CRITICAL  Cuenta 'toor' con UID 0 (equivale a root)

== Usuarios con shell de login ==
INFO      root (uid 0) shell /bin/bash
WARNING   backup (uid 34) es cuenta de sistema con shell /bin/bash
INFO      alice (uid 1000) shell /bin/bash
INFO      bob (uid 1001) shell /bin/zsh
WARNING   toor (uid 0) es cuenta de sistema con shell /bin/sh

== Privilegios (sudo/wheel/admin y sudoers) ==
INFO      grupo sudo: alice,carol
INFO      grupo wheel: bob
INFO      sudoers (sudoers): root ALL=(ALL:ALL) ALL
INFO      sudoers (sudoers): %sudo ALL=(ALL:ALL) ALL
WARNING   sudoers NOPASSWD (deploy): bob ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart app

== Contraseñas vacías ==
CRITICAL  La cuenta 'guest' no tiene contraseña

== Últimos accesos ==

wtmp empieza Tue Nov 24 09:20:15 2026
$ echo $?
2
```

`/etc/sudoers` y `/etc/shadow` solo los puede leer root. Si no se pueden leer, el script lo indica
(`UNKNOWN`) y devuelve `3` en lugar de dar por buena una auditoría incompleta.

### `ssh-hardening-check.sh` — revisión de `sshd_config`

Compara un `sshd_config` con las buenas prácticas. Acepta una ruta (por defecto `/etc/ssh/sshd_config`),
sigue los `Include`, aplica la regla de sshd «gana la primera aparición» y para en el primer bloque `Match`.
Cuando una directiva no está escrita evalúa el valor por defecto de OpenSSH y lo indica.

```console
$ ssh-hardening-check tests/fixtures/sshd_config.insecure
Fichero: tests/fixtures/sshd_config.insecure
CRITICAL  PermitRootLogin = yes — recomendado: no
WARNING   PasswordAuthentication = yes — recomendado: no (usar claves públicas)
OK        PermitEmptyPasswords = no
OK        PubkeyAuthentication = yes (por defecto)
WARNING   X11Forwarding = yes — recomendado: no
WARNING   MaxAuthTries = 10 — recomendado: 4 o menos
WARNING   KbdInteractiveAuthentication = yes (por defecto) — recomendado: no (si no se usa 2FA)
OK        PermitUserEnvironment = no (por defecto)
INFO      Sin AllowUsers/AllowGroups: cualquier cuenta válida puede intentar entrar
INFO      Port = 2222
$ echo $?
2
```

## Automatización

- [`systemd/`](systemd): unidades `service` + `timer` de ejemplo para la copia diaria y la comprobación horaria de disco.
- [`cron/toolkit.cron`](cron/toolkit.cron): crontab de ejemplo para `/etc/cron.d` con todos los scripts.

## Tests

```bash
make test      # bats tests/
make lint      # shellcheck
make check     # ambos
```

129 tests en 9 ficheros `.bats`, uno por script más la librería. Los tests nunca tocan el sistema real:

- `systemctl`, `df`, `ss`, `last` y `tar` se sustituyen por **stubs en el `PATH`** del test.
- `clean-logs` y `backup-rotate` trabajan en **directorios temporales** de bats.
- `user-audit` y `ssh-hardening-check` leen **ficheros sintéticos** de [`tests/fixtures/`](tests/fixtures).

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) define la integración continua: shellcheck y bats
en cada push y pull request.

## Estructura

```text
bash-sysadmin-toolkit/
├── scripts/                 # los 8 scripts
│   ├── sysinfo.sh
│   ├── check-disk.sh
│   ├── check-services.sh
│   ├── check-ports.sh
│   ├── clean-logs.sh
│   ├── backup-rotate.sh
│   ├── user-audit.sh
│   └── ssh-hardening-check.sh
├── lib/common.sh            # códigos de salida, logging, validación y load_config
├── config/toolkit.conf.example
├── systemd/                 # service + timer de ejemplo
├── cron/toolkit.cron        # crontab de ejemplo
├── tests/                   # bats, helpers y fixtures sintéticos
├── docs/decisiones.md       # decisiones de diseño y límites conocidos
├── Makefile                 # install, uninstall, lint, test
└── .github/workflows/ci.yml
```

## Verificación

Lo que se ha ejecutado de verdad (el detalle y los límites están en [`docs/decisiones.md`](docs/decisiones.md#11-qué-se-ha-verificado-y-qué-no)):

- `shellcheck` sin avisos y `bats tests/` con 129 tests correctos en Arch/CachyOS (Bash 5).
- Los mismos 129 tests en un contenedor Ubuntu 18.04 (**Bash 4.4**), como usuario normal y como root.
- `check-services -r`, `user-audit` y `ssh-hardening-check` ejecutados como root en un contenedor.
- `make install` / `make uninstall`, `systemd-analyze verify` de los units y `actionlint` del workflow.

Sin verificar: timers de systemd activados en un sistema en marcha, validación del crontab (no hay `cron` en
la máquina de desarrollo), reinicio contra un systemd real y otras distribuciones distintas de las dos anteriores.

## Licencia

[MIT](LICENSE) © 2026 Daniel García Rodríguez
