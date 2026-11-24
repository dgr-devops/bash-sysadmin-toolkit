# Decisiones de diseño

Por qué los scripts son como son, y qué se ha verificado de verdad. Está pensado para quien quiera
revisar el código o ampliarlo.

## 1. Bash, y solo Bash

Son tareas de «pegamento» sobre herramientas que ya existen en cualquier servidor (`ss`, `find`, `tar`,
`systemctl`, `flock`). Bash no añade dependencias ni un intérprete que instalar. El coste es la fragilidad
con comillas, espacios y errores silenciosos, y se compensa con tres reglas:

- `set -euo pipefail` en todos los scripts.
- Todo se pasa a `shellcheck`; las pocas deshabilitaciones llevan un comentario con el motivo.
- Los argumentos se validan antes de hacer nada, y los nombres de usuario, servicio o fichero nunca se interpretan como opciones (`--`).

## 2. Códigos de salida al estilo Nagios

`0` OK, `1` aviso, `2` crítico, `3` desconocido, más `64` para uso incorrecto (el `EX_USAGE` de `sysexits.h`).

- Cron, systemd, un monitor o un `if` en otro script entienden el resultado sin parsear texto.
- `64` separa «has llamado mal al script» de «el sistema tiene un problema».
- Cuando varios resultados conviven, gana el más grave. En `check-services`, un servicio caído (`2`) pesa más
  que uno inexistente (`3`). En `user-audit`, un hallazgo (`1` o `2`) pesa más que una auditoría incompleta (`3`).

Las constantes viven en `lib/common.sh` para que ningún script escriba números sueltos.

## 3. Librería común y configuración como datos

`lib/common.sh` reúne logging, `die`, `require_cmd`, `is_uint` y `load_config`.

`load_config` **no hace `source`** del fichero de configuración: lo lee línea a línea y solo acepta
`TOOLKIT_NOMBRE=valor`. Un fichero en `/etc` o `~` que se ejecutase como shell sería una vía de ejecución de
código; así no lo es (hay un test que lo comprueba). Una variable de entorno ya definida gana al fichero, y
una opción de línea de comandos gana a ambos.

## 4. Enlaces simbólicos (`make install`)

Con `dirname "${BASH_SOURCE[0]}"` un script enlazado en `~/.local/bin` buscaba `lib/common.sh` junto al enlace y fallaba.
Se descubrió al preparar el `Makefile`; la solución es resolver el enlace con `readlink -f` antes de calcular el directorio.
Hay un test que ejecuta un script a través de un enlace.

`make uninstall` solo borra un enlace si apunta a este repositorio: no elimina ficheros ajenos con el mismo nombre.

## 5. `clean-logs`: lo destructivo, seguro por defecto

- **Simula salvo `--apply`.** Olvidarse de una opción nunca borra nada.
- **Rutas rechazadas** (código `64`): vacías, inexistentes, `/`, `/etc`, `/usr`, `/var`, `/home`, `/tmp`, `/boot`..., cualquier cosa bajo
  `/etc`, `/usr`, `/proc`, `/sys`..., y el `HOME` del usuario. La ruta se resuelve con `realpath` antes de comprobarla,
  así que un enlace simbólico a `/etc` tampoco pasa. `/var/log` y sus subdirectorios sí están permitidos: es el uso previsto.
- **Alcance mínimo**: solo ficheros regulares (`-type f`) llamados `*.log` o `*.log.*`; sin seguir enlaces, sin cruzar sistemas de
  ficheros (`-xdev`), sin recursión salvo `-r`.
- **Orden**: primero borra lo más viejo y luego comprime lo intermedio, para no comprimir ficheros que van a desaparecer.
  `gzip` conserva la fecha de modificación, así que un `.gz` envejece y acaba borrándose en la fase de borrado.
- **No pisa un `.gz` existente.**
- Usa la fecha de modificación (`mtime`): un log que se está escribiendo se ve «reciente» y no se toca.
  Para logs que el servicio mantiene abiertos, `logrotate` sigue siendo la herramienta adecuada.

## 6. `backup-rotate`: copias que se pueden creer

- **Escritura atómica**: `tar` escribe en `*.partial` y solo se renombra al terminar. Si falla, el `trap` lo borra: nunca queda una copia a medias con aspecto de buena.
- **Checksum**: se guarda un `.sha256` con el nombre sin ruta (se verifica con `sha256sum -c` desde su carpeta) y el propio script lo verifica nada más crearlo.
- **`flock`**: un fichero de cerrojo por destino y nombre; una segunda ejecución simultánea sale con `1` sin hacer nada. El cerrojo lo libera el sistema operativo al morir el proceso, así que no puede quedar «atascado».
- **Rotación estricta**: solo cuenta ficheros que cumplen `NOMBRE-AAAAMMDD-HHMMSS.tar.gz`; los ficheros ajenos del directorio no se tocan. La marca de hora ordena igual alfabética que cronológicamente. `-k` incluye la copia recién creada.
- **Salvaguardas**: no admite `/` como origen y rechaza un destino dentro del origen (la copia se incluiría a sí misma).
- Dos copias del mismo nombre en el mismo segundo no se pisan: el script falla con un error claro.

## 7. `check-ports`: qué se considera «expuesto»

Un puerto que solo escucha en `127.0.0.0/8` o `::1` no es accesible desde fuera, así que por defecto no se evalúa (`-i` lo incluye).
El mismo puerto en IPv4 e IPv6 se agrupa en una línea. Un puerto fuera de la lista da `1` (aviso): es un hallazgo a revisar, no una caída.
Sin lista de permitidos, el script informa pero no juzga: evita que una instalación sin configurar dispare avisos permanentes.

## 8. `user-audit`: solo lectura y auditoría honesta

- Nunca modifica nada. El parámetro `-r RAIZ` permite auditar otro árbol (una copia montada) y es lo que hace los tests posibles sin tocar `/etc`.
- Lo que no se puede leer sin ser root (`sudoers`, `shadow`) se informa como `UNKNOWN` y devuelve `3`: es preferible decir «no he podido comprobarlo» que dar un `0` engañoso.
- Las cuentas de sistema (UID < 1000) con shell de login se marcan como aviso: es una señal clásica de cuenta mal configurada o de persistencia.
- Los miembros de `sudo`/`wheel`/`admin` incluyen a quien tiene ese grupo como primario, no solo a los listados en `/etc/group`.
- `sudoers.d` sigue la regla de sudo: se ignoran los ficheros con punto o terminados en `~`.

## 9. `ssh-hardening-check`: leer como lo haría sshd

- **Gana la primera aparición** de cada directiva, igual que en `sshd`.
- **Se deja de leer en el primer `Match`**: lo que viene después solo aplica a ciertas conexiones, no a la configuración global.
- **Sigue `Include`** (con rutas relativas al fichero y un límite de profundidad contra ciclos).
- Cuando no hay valor escrito se evalúa el **valor por defecto** de OpenSSH y se marca «por defecto». Esos valores cambian entre versiones y distribuciones; el script los asume, no los consulta con `sshd -T`.
- `PermitRootLogin yes` y `PermitEmptyPasswords yes` son críticos; `prohibit-password` y `PasswordAuthentication yes` son avisos.

## 10. Estrategia de tests

- Cada script tiene su `.bats`, más uno para la librería: 129 tests en total.
- **Nunca se toca el sistema real**: `systemctl`, `df`, `ss`, `last` y `tar` se sustituyen por stubs en el `PATH`; los directorios de trabajo son temporales de bats; las auditorías leen datos sintéticos de `tests/fixtures/`.
- Se prueban los caminos de error (argumentos inválidos, rutas peligrosas, dependencias que faltan), no solo el camino feliz.
- Los tests que dependen de no ser root (`check-services -r`, permisos de `shadow`) se saltan solos si se ejecutan como root.

## 11. Qué se ha verificado y qué no

**Verificado ejecutándolo** (Arch/CachyOS, Bash 5, shellcheck y bats instalados):

- `shellcheck` sin avisos en los 8 scripts y en `lib/common.sh`.
- `bats tests/`: 129 tests correctos.
- Los 8 scripts, ejecutados contra el sistema real o contra datos de prueba, con la salida que muestra el README.
- `make install` / `make uninstall` en un prefijo temporal: enlaza los 8 scripts, el enlace funciona y no se borran ficheros ajenos.
- `systemd-analyze verify` sobre los units: solo se queja de que los binarios de `/usr/local/bin` no están instalados (esperado).
- `check-ports` en un espacio de red aislado (`unshare -rn`) con servidores HTTP reales.

**No verificado:**

- El workflow de CI **no se ha ejecutado** (el repositorio aún no está en GitHub): solo se comprobó que el YAML es válido y que `make lint` y `make test` funcionan en local.
- Los timers y services de systemd **no se han instalado ni activado**; el crontab **no se ha validado** (no hay `crontab` en la máquina de desarrollo).
- `check-services -r` (reiniciar servicios) requiere root: solo se prueba que sin root se rechaza; el reinicio en sí **no se ha probado**.
- `user-audit` y `ssh-hardening-check` no se han probado como root sobre un servidor real; `/etc/sudoers` y `/etc/shadow` no son legibles sin privilegios.
- Solo una distribución y una versión de OpenSSH. Los valores por defecto de `ssh-hardening-check` pueden diferir en otras versiones.
- Bash 4.4 es el mínimo declarado por las características que se usan, pero solo se ha probado con Bash 5.

## 12. Fuera de alcance, a propósito

- No hay envío de alertas (correo, Slack): se delega en cron (`MAILTO`), `logger` o el monitor que consuma los códigos de salida.
- No se modifica ninguna configuración de SSH ni de usuarios: los scripts de auditoría solo informan.
- No hay instalación de paquetes ni gestión de dependencias: `require_cmd` avisa de lo que falte.
