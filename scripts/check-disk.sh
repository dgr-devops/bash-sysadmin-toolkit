#!/usr/bin/env bash
# check-disk.sh — avisa cuando el uso de disco supera unos umbrales.
#
# Uso: check-disk.sh [-w AVISO] [-c CRITICO] [-h] [RUTA...]
# Códigos de salida: 0 = todo OK, 1 = aviso, 2 = crítico, 3 = desconocido, 64 = uso incorrecto.
# Es el mismo convenio que los plugins de Nagios, así que se integra con monitorización.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

readonly DEFAULT_WARN=80
readonly DEFAULT_CRIT=90
# Sistemas de ficheros virtuales que no interesa vigilar.
readonly EXCLUDED_FS=(tmpfs devtmpfs squashfs overlay efivarfs)

usage() {
  cat <<EOF
Uso: check-disk.sh [-w AVISO] [-c CRITICO] [-h] [RUTA...]

Comprueba el porcentaje de uso de disco y devuelve el estado más grave.
Sin RUTA, revisa todos los sistemas de ficheros reales montados.

Opciones:
  -w N   Umbral de aviso en %   (por defecto ${DEFAULT_WARN})
  -c N   Umbral crítico en %    (por defecto ${DEFAULT_CRIT})
  -h     Muestra esta ayuda

Códigos de salida: 0 = OK, 1 = aviso, 2 = crítico, 3 = desconocido, 64 = uso incorrecto.
EOF
}

# validate_threshold <nombre> <valor> — entero entre 1 y 100.
validate_threshold() {
  local name="$1" value="$2"
  if ! is_uint "$value" || ((value < 1 || value > 100)); then
    log_error "El umbral ${name} debe ser un entero entre 1 y 100 (recibido: '${value}')"
    exit "$EXIT_USAGE"
  fi
}

# disk_usage [ruta...] — imprime "porcentaje punto_de_montaje" por línea.
# Sin rutas, agrupa por dispositivo para no repetir subvolúmenes (btrfs, bind mounts).
disk_usage() {
  local exclude=() fs out
  for fs in "${EXCLUDED_FS[@]}"; do
    exclude+=(-x "$fs")
  done
  out="$(df --output=source,pcent,target "${exclude[@]}" "$@")" || return 1
  if (($# == 0)); then
    tail -n +2 <<<"$out" | awk '!seen[$1]++ {$1 = ""; sub(/^ /, ""); print}'
  else
    tail -n +2 <<<"$out" | awk '{$1 = ""; sub(/^ /, ""); print}'
  fi
}

main() {
  local warn="$DEFAULT_WARN" crit="$DEFAULT_CRIT" opt
  while getopts ':w:c:h' opt; do
    case "$opt" in
      w) warn="$OPTARG" ;;
      c) crit="$OPTARG" ;;
      h) usage; exit "$EXIT_OK" ;;
      *) usage >&2; exit "$EXIT_USAGE" ;;
    esac
  done
  shift $((OPTIND - 1))

  validate_threshold "aviso (-w)" "$warn"
  validate_threshold "crítico (-c)" "$crit"
  if ((warn >= crit)); then
    log_error "El umbral de aviso (${warn}) debe ser menor que el crítico (${crit})"
    exit "$EXIT_USAGE"
  fi

  require_cmd df tail awk

  local rows
  rows="$(disk_usage "$@")" || die "No se pudo leer el uso de disco" "$EXIT_UNKNOWN"

  local worst="$EXIT_OK" pcent target usage status
  while read -r pcent target; do
    usage="${pcent%\%}"
    if ((usage >= crit)); then
      status="CRITICAL"
      worst="$EXIT_CRITICAL"
    elif ((usage >= warn)); then
      status="WARNING"
      ((worst < EXIT_WARNING)) && worst="$EXIT_WARNING"
    else
      status="OK"
    fi
    printf '%-9s %3s%%  %s\n' "$status" "$usage" "$target"
  done <<<"$rows"

  exit "$worst"
}

main "$@"
