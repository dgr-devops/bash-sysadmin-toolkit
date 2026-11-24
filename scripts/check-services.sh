#!/usr/bin/env bash
# check-services.sh — comprueba que unos servicios de systemd estén activos.
#
# Uso: check-services.sh [-r] [-h] SERVICIO...
# Códigos de salida: 0 = todos activos, 2 = alguno caído, 3 = alguno no existe, 64 = uso incorrecto.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

# Nombres de unidad permitidos: evita que un argumento se interprete como opción.
readonly UNIT_PATTERN='^[A-Za-z0-9][A-Za-z0-9@_.:-]*$'

usage() {
  cat <<'EOF'
Uso: check-services.sh [-r] [-h] SERVICIO...

Comprueba con systemctl que cada servicio esté activo.

Opciones:
  -r   Intenta reiniciar los servicios caídos (requiere root) y vuelve a comprobarlos
  -h   Muestra esta ayuda

Códigos de salida: 0 = todos activos, 2 = alguno caído, 3 = alguno no existe, 64 = uso incorrecto.
Si hay a la vez caídos e inexistentes, gana el 2 (un servicio caído es más grave).
EOF
}

# unit_exists <servicio> — verdadero si systemd conoce la unidad.
unit_exists() {
  local load_state
  load_state="$(systemctl show --property=LoadState --value -- "$1" 2>/dev/null || true)"
  [[ -n "$load_state" && "$load_state" != "not-found" ]]
}

# unit_state <servicio> — estado actual: active, inactive, failed...
unit_state() {
  systemctl is-active -- "$1" 2>/dev/null || true
}

# restart_unit <servicio> — reinicia y devuelve el nuevo estado.
restart_unit() {
  log_warn "Reiniciando $1"
  systemctl restart -- "$1" || log_error "No se pudo reiniciar $1"
  unit_state "$1"
}

main() {
  local restart=false opt
  while getopts ':rh' opt; do
    case "$opt" in
      r) restart=true ;;
      h) usage; exit "$EXIT_OK" ;;
      *) usage >&2; exit "$EXIT_USAGE" ;;
    esac
  done
  shift $((OPTIND - 1))

  if (($# == 0)); then
    usage >&2
    exit "$EXIT_USAGE"
  fi
  if [[ "$restart" == true && "$EUID" -ne 0 ]]; then
    die "La opción -r requiere ejecutar como root" "$EXIT_USAGE"
  fi

  require_cmd systemctl

  local any_down=false any_unknown=false svc state
  for svc in "$@"; do
    if [[ ! "$svc" =~ $UNIT_PATTERN ]]; then
      die "Nombre de servicio no válido: '${svc}'" "$EXIT_USAGE"
    fi

    if ! unit_exists "$svc"; then
      printf '%-9s %s (no existe)\n' "UNKNOWN" "$svc"
      any_unknown=true
      continue
    fi

    state="$(unit_state "$svc")"
    if [[ "$state" != "active" && "$restart" == true ]]; then
      state="$(restart_unit "$svc")"
    fi

    if [[ "$state" == "active" ]]; then
      printf '%-9s %s\n' "OK" "$svc"
    else
      printf '%-9s %s (%s)\n' "CRITICAL" "$svc" "$state"
      any_down=true
    fi
  done

  if [[ "$any_down" == true ]]; then
    exit "$EXIT_CRITICAL"
  elif [[ "$any_unknown" == true ]]; then
    exit "$EXIT_UNKNOWN"
  fi
  exit "$EXIT_OK"
}

main "$@"
