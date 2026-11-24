#!/usr/bin/env bash
# ssh-hardening-check.sh — compara un sshd_config con las buenas prácticas de seguridad.
#
# Uso: ssh-hardening-check.sh [-h] [FICHERO]
# Códigos de salida: 0 = todo correcto, 1 = hay avisos, 2 = hay hallazgos críticos, 3 = no se pudo leer, 64 = uso incorrecto.
# Solo lee el fichero: no modifica la configuración de SSH.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

readonly DEFAULT_SSHD_CONFIG="/etc/ssh/sshd_config"
readonly MAX_INCLUDE_DEPTH=5

usage() {
  cat <<EOF
Uso: ssh-hardening-check.sh [-h] [FICHERO]

Lee un fichero sshd_config (por defecto ${DEFAULT_SSHD_CONFIG}, o TOOLKIT_SSHD_CONFIG)
y comprueba las directivas más importantes frente a las buenas prácticas:
PermitRootLogin, PasswordAuthentication, PermitEmptyPasswords, X11Forwarding,
MaxAuthTries, PubkeyAuthentication, KbdInteractiveAuthentication,
PermitUserEnvironment y Protocol.

Sigue las líneas Include y, como sshd, usa la primera aparición de cada directiva
y deja de leer en el primer bloque Match. Cuando una directiva no está escrita se
evalúa su valor por defecto de OpenSSH (se indica con "por defecto"); esos valores
pueden variar según la versión y la distribución.

Opciones:
  -h, --help   Muestra esta ayuda

Códigos de salida: 0 = todo correcto, 1 = hay avisos, 2 = hay hallazgos críticos, 3 = no se pudo leer, 64 = uso incorrecto.
EOF
}

# Valor efectivo de cada directiva (clave en minúsculas): gana la primera aparición.
declare -A CFG=()
STOP_PARSE=false
CRITICAL=false
WARNING=false

# parse_config <fichero> <profundidad> — rellena CFG siguiendo los Include.
parse_config() {
  local file="$1" depth="$2" line key value pattern inc
  if ((depth > MAX_INCLUDE_DEPTH)); then
    log_warn "Demasiados Include anidados, se ignora ${file}"
    return 0
  fi
  [[ -r "$file" ]] || return 0
  # shellcheck disable=SC2094  # falso positivo: la recursión solo lee otros ficheros
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$STOP_PARSE" == true ]] && return 0
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -n "$line" && "$line" != \#* ]] || continue
    if [[ "$line" =~ ^([A-Za-z0-9]+)([[:space:]]*=[[:space:]]*|[[:space:]]+)(.*)$ ]]; then
      key="${BASH_REMATCH[1],,}"
      value="${BASH_REMATCH[3]}"
      value="${value%"${value##*[![:space:]]}"}"
      value="${value//\"/}"
    else
      continue
    fi
    case "$key" in
      match)
        STOP_PARSE=true
        return 0
        ;;
      include)
        for pattern in $value; do
          [[ "$pattern" == /* ]] || pattern="$(dirname "$file")/${pattern}"
          # shellcheck disable=SC2231  # el glob es intencionado
          for inc in $pattern; do
            [[ -f "$inc" ]] && parse_config "$inc" "$((depth + 1))"
          done
        done
        ;;
      *)
        [[ -n "${CFG[$key]+x}" ]] || CFG["$key"]="$value"
        ;;
    esac
  done <"$file"
}

# report <nivel> <mensaje>
report() {
  local level="$1"
  shift
  printf '%-9s %s\n' "$level" "$*"
  case "$level" in
    CRITICAL) CRITICAL=true ;;
    WARNING) WARNING=true ;;
  esac
}

# check <directiva> <defecto> <regex_bueno> <regex_aviso|-> <nivel_malo> <recomendación> [alias...]
# Evalúa el valor efectivo (o el defecto) y lo clasifica como OK, WARNING o <nivel_malo>.
check() {
  local name="$1" default="$2" good="$3" warn="$4" bad_level="$5" advice="$6"
  shift 6
  local key="${name,,}" value="" source_note="" alias
  value="${CFG[$key]:-}"
  for alias in "$@"; do
    [[ -n "$value" ]] || value="${CFG[${alias,,}]:-}"
  done
  if [[ -z "$value" ]]; then
    value="$default"
    source_note=" (por defecto)"
  fi
  local lower="${value,,}"
  if [[ "$lower" =~ $good ]]; then
    report OK "${name} = ${value}${source_note}"
  elif [[ "$warn" != "-" && "$lower" =~ $warn ]]; then
    report WARNING "${name} = ${value}${source_note} — recomendado: ${advice}"
  else
    report "$bad_level" "${name} = ${value}${source_note} — recomendado: ${advice}"
  fi
}

main() {
  local opt
  while getopts ':h-:' opt; do
    case "$opt" in
      h) usage; exit "$EXIT_OK" ;;
      -)
        if [[ "$OPTARG" == "help" ]]; then usage; exit "$EXIT_OK"; fi
        usage >&2
        exit "$EXIT_USAGE"
        ;;
      *) usage >&2; exit "$EXIT_USAGE" ;;
    esac
  done
  shift $((OPTIND - 1))
  if (($# > 1)); then
    usage >&2
    exit "$EXIT_USAGE"
  fi

  load_config
  local file explicit=false
  if (($# == 1)); then
    file="$1"
    explicit=true
  else
    file="${TOOLKIT_SSHD_CONFIG:-$DEFAULT_SSHD_CONFIG}"
  fi
  if [[ -z "${file//[[:space:]]/}" ]]; then
    log_error "La ruta del fichero está vacía"
    exit "$EXIT_USAGE"
  fi
  if [[ ! -f "$file" || ! -r "$file" ]]; then
    if [[ "$explicit" == true ]]; then
      log_error "No se puede leer el fichero: ${file}"
      exit "$EXIT_USAGE"
    fi
    die "No se puede leer ${file}" "$EXIT_UNKNOWN"
  fi

  parse_config "$file" 0
  printf 'Fichero: %s\n' "$file"

  check PermitRootLogin prohibit-password '^no$' '^(prohibit-password|without-password|forced-commands-only)$' CRITICAL "no"
  check PasswordAuthentication yes '^no$' - WARNING "no (usar claves públicas)"
  check PermitEmptyPasswords no '^no$' - CRITICAL "no"
  check PubkeyAuthentication yes '^yes$' - WARNING "yes"
  check X11Forwarding no '^no$' - WARNING "no"
  check MaxAuthTries 6 '^[1-4]$' - WARNING "4 o menos"
  check KbdInteractiveAuthentication yes '^no$' - WARNING "no (si no se usa 2FA)" ChallengeResponseAuthentication
  check PermitUserEnvironment no '^no$' - WARNING "no"

  # Protocol solo existe en OpenSSH antiguos: si aparece, debe ser 2.
  if [[ -n "${CFG[protocol]:-}" ]]; then
    check Protocol 2 '^2$' - CRITICAL "2"
  fi

  if [[ -n "${CFG[allowusers]:-}${CFG[allowgroups]:-}" ]]; then
    printf '%-9s %s\n' "INFO" "Acceso restringido con AllowUsers/AllowGroups"
  else
    printf '%-9s %s\n' "INFO" "Sin AllowUsers/AllowGroups: cualquier cuenta válida puede intentar entrar"
  fi
  printf '%-9s %s\n' "INFO" "Port = ${CFG[port]:-22}$([[ -n "${CFG[port]:-}" ]] || printf ' (por defecto)')"

  if [[ "$CRITICAL" == true ]]; then
    exit "$EXIT_CRITICAL"
  elif [[ "$WARNING" == true ]]; then
    exit "$EXIT_WARNING"
  fi
  exit "$EXIT_OK"
}

main "$@"
