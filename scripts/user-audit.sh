#!/usr/bin/env bash
# user-audit.sh — auditoría rápida de cuentas: UID 0, shells de login, sudo/wheel y últimos accesos.
#
# Uso: user-audit.sh [-r RAIZ] [-n N] [-h]
# Códigos de salida: 0 = sin hallazgos, 1 = aviso, 2 = crítico, 3 = auditoría incompleta, 64 = uso incorrecto.
# Solo lee: no modifica ninguna cuenta ni fichero.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

readonly DEFAULT_LAST=10
readonly FIRST_HUMAN_UID=1000
# Grupos cuyos miembros pueden usar sudo.
readonly PRIVILEGED_GROUPS=(sudo wheel admin)
# Shells que no permiten iniciar sesión.
readonly NOLOGIN_SHELLS='(/nologin|/false|/sync|/shutdown|/halt)$'

usage() {
  cat <<EOF
Uso: user-audit.sh [-r RAIZ] [-n N] [-h]

Audita las cuentas locales y muestra:
  1. Cuentas con UID 0 (solo root debería tenerlo)
  2. Usuarios con shell de login (y cuentas de sistema que no deberían tenerlo)
  3. Miembros de los grupos sudo/wheel/admin y reglas de sudoers
  4. Cuentas con contraseña vacía (si /etc/shadow es legible)
  5. Últimos accesos (last)

Opciones:
  -r RAIZ  Raíz del sistema a auditar (por defecto /). Sirve para una copia
           montada o para pruebas: se leen RAIZ/etc/passwd, RAIZ/etc/group...
  -n N     Número de últimos accesos a mostrar (por defecto ${DEFAULT_LAST})
  -h       Muestra esta ayuda

Algunos ficheros (sudoers, shadow) solo los puede leer root. Si no se pueden
leer, se avisa y la auditoría se marca como incompleta (código 3).

Códigos de salida: 0 = sin hallazgos, 1 = aviso, 2 = crítico, 3 = auditoría incompleta, 64 = uso incorrecto.
EOF
}

CRITICAL=false
WARNING=false
UNKNOWN=false

# report <nivel> <mensaje> — imprime una línea de resultado y anota el nivel.
report() {
  local level="$1"
  shift
  printf '%-9s %s\n' "$level" "$*"
  case "$level" in
    CRITICAL) CRITICAL=true ;;
    WARNING) WARNING=true ;;
    UNKNOWN) UNKNOWN=true ;;
  esac
}

section() {
  printf '\n== %s ==\n' "$1"
}

# audit_uid0 <passwd> — cuentas con UID 0 distintas de root.
audit_uid0() {
  local user _pw uid found=false
  while IFS=: read -r user _pw uid _; do
    if [[ "$uid" == "0" && "$user" != "root" ]]; then
      report CRITICAL "Cuenta '${user}' con UID 0 (equivale a root)"
      found=true
    fi
  done <"$1"
  [[ "$found" == true ]] || report OK "Solo root tiene UID 0"
}

# audit_shells <passwd> — usuarios con shell de login.
audit_shells() {
  local user _pw uid _gid _gecos _home shell found=false
  while IFS=: read -r user _pw uid _gid _gecos _home shell; do
    [[ -n "$user" && "$user" != \#* ]] || continue
    [[ -n "$shell" && ! "$shell" =~ $NOLOGIN_SHELLS ]] || continue
    found=true
    if [[ "$user" != "root" ]] && is_uint "$uid" && ((uid < FIRST_HUMAN_UID)); then
      report WARNING "${user} (uid ${uid}) es cuenta de sistema con shell ${shell}"
    else
      report INFO "${user} (uid ${uid}) shell ${shell}"
    fi
  done <"$1"
  [[ "$found" == true ]] || report OK "Ningún usuario con shell de login"
}

# group_members <group-file> <grupo> — gid y miembros: "gid miembros".
group_members() {
  local name _pw gid members
  while IFS=: read -r name _pw gid members; do
    if [[ "$name" == "$2" ]]; then
      printf '%s %s\n' "$gid" "$members"
      return 0
    fi
  done <"$1"
  return 1
}

# audit_privileged_groups <group> <passwd> — miembros de sudo/wheel/admin.
audit_privileged_groups() {
  local grp info gid members user _pw _uid pgid found=false
  for grp in "${PRIVILEGED_GROUPS[@]}"; do
    info="$(group_members "$1" "$grp")" || continue
    gid="${info%% *}"
    members="${info#* }"
    [[ "$info" == *" "* ]] || members=""
    # También cuenta quien tiene el grupo como primario.
    while IFS=: read -r user _pw _uid pgid _; do
      if [[ "$pgid" == "$gid" ]]; then
        members="${members:+${members},}${user}"
      fi
    done <"$2"
    found=true
    report INFO "grupo ${grp}: ${members:-(sin miembros)}"
  done
  [[ "$found" == true ]] || report INFO "No existen los grupos ${PRIVILEGED_GROUPS[*]}"
}

# sudoers_files <raíz> — ficheros de sudoers que sudo realmente lee.
sudoers_files() {
  local root="$1" file
  [[ -e "${root}/etc/sudoers" ]] && printf '%s\n' "${root}/etc/sudoers"
  if [[ -d "${root}/etc/sudoers.d" ]]; then
    for file in "${root}"/etc/sudoers.d/*; do
      # sudo ignora los ficheros con punto o terminados en ~.
      [[ -f "$file" && "${file##*/}" != *.* && "${file##*/}" != *~ ]] && printf '%s\n' "$file"
    done
  fi
  return 0
}

# audit_sudoers <raíz> — reglas de sudoers; avisa de NOPASSWD.
audit_sudoers() {
  local root="$1" file line found=false
  local -a files=()
  mapfile -t files < <(sudoers_files "$root")
  if ((${#files[@]} == 0)); then
    report INFO "No hay fichero sudoers en ${root}/etc"
    return 0
  fi
  for file in "${files[@]}"; do
    if [[ ! -r "$file" ]]; then
      report UNKNOWN "No se puede leer ${file} (ejecuta como root para auditarlo)"
      continue
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%%#*}"
      line="${line#"${line%%[![:space:]]*}"}"
      [[ -n "$line" ]] || continue
      [[ "$line" =~ ^(Defaults|User_Alias|Runas_Alias|Host_Alias|Cmnd_Alias|@include|@includedir) ]] && continue
      found=true
      if [[ "$line" == *NOPASSWD* ]]; then
        report WARNING "sudoers NOPASSWD (${file##*/}): ${line}"
      else
        report INFO "sudoers (${file##*/}): ${line}"
      fi
    done <"$file"
  done
  [[ "$found" == true || "$UNKNOWN" == true ]] || report OK "sudoers sin reglas de usuario"
  return 0
}

# audit_empty_passwords <raíz> — cuentas sin contraseña (requiere leer shadow).
audit_empty_passwords() {
  local shadow="${1}/etc/shadow" user hash found=false
  if [[ ! -e "$shadow" ]]; then
    report INFO "No hay ${shadow}"
    return 0
  fi
  if [[ ! -r "$shadow" ]]; then
    report UNKNOWN "No se puede leer ${shadow} (ejecuta como root para comprobar contraseñas vacías)"
    return 0
  fi
  while IFS=: read -r user hash _; do
    if [[ -n "$user" && -z "$hash" ]]; then
      report CRITICAL "La cuenta '${user}' no tiene contraseña"
      found=true
    fi
  done <"$shadow"
  [[ "$found" == true ]] || report OK "Ninguna cuenta con contraseña vacía"
}

# audit_last <raíz> <n> — últimos accesos con `last`.
audit_last() {
  local root="$1" count="$2" out
  local -a args=(-n "$count" -w)
  if [[ "$root" != "/" ]]; then
    if [[ ! -r "${root}/var/log/wtmp" ]]; then
      report INFO "No hay ${root}/var/log/wtmp"
      return 0
    fi
    args+=(-f "${root}/var/log/wtmp")
  fi
  if ! command -v last >/dev/null 2>&1; then
    report INFO "El comando last no está instalado"
    return 0
  fi
  if ! out="$(last "${args[@]}" 2>/dev/null)" || [[ -z "$out" ]]; then
    report INFO "Sin registros de accesos (wtmp vacío o ilegible)"
    return 0
  fi
  printf '%s\n' "$out"
}

main() {
  local root="/" count="$DEFAULT_LAST" opt
  while getopts ':r:n:h' opt; do
    case "$opt" in
      r) root="$OPTARG" ;;
      n) count="$OPTARG" ;;
      h) usage; exit "$EXIT_OK" ;;
      *) usage >&2; exit "$EXIT_USAGE" ;;
    esac
  done
  shift $((OPTIND - 1))
  if (($# > 0)); then
    usage >&2
    exit "$EXIT_USAGE"
  fi
  if ! is_uint "$count" || ((count < 1)); then
    log_error "-n debe ser un entero mayor que 0 (recibido: '${count}')"
    exit "$EXIT_USAGE"
  fi
  if [[ ! -d "$root" ]]; then
    log_error "La raíz no es un directorio: ${root}"
    exit "$EXIT_USAGE"
  fi
  root="${root%/}"
  [[ -n "$root" ]] || root="/"
  local base="$root"
  [[ "$root" == "/" ]] && base=""

  local passwd="${base}/etc/passwd" group="${base}/etc/group"
  if [[ ! -r "$passwd" || ! -r "$group" ]]; then
    die "No se pueden leer ${passwd} o ${group}" "$EXIT_UNKNOWN"
  fi

  section "Cuentas con UID 0"
  audit_uid0 "$passwd"
  section "Usuarios con shell de login"
  audit_shells "$passwd"
  section "Privilegios (sudo/wheel/admin y sudoers)"
  audit_privileged_groups "$group" "$passwd"
  audit_sudoers "$base"
  section "Contraseñas vacías"
  audit_empty_passwords "$base"
  section "Últimos accesos"
  audit_last "$root" "$count"

  if [[ "$CRITICAL" == true ]]; then
    exit "$EXIT_CRITICAL"
  elif [[ "$WARNING" == true ]]; then
    exit "$EXIT_WARNING"
  elif [[ "$UNKNOWN" == true ]]; then
    exit "$EXIT_UNKNOWN"
  fi
  exit "$EXIT_OK"
}

main "$@"
