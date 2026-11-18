#!/usr/bin/env bash
# sysinfo.sh — resumen rápido del sistema: SO, kernel, CPU, memoria, carga y uptime.
#
# Uso: sysinfo.sh [-h]
# Códigos de salida: 0 = correcto, 64 = uso incorrecto.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

usage() {
  cat <<'EOF'
Uso: sysinfo.sh [-h]

Muestra un resumen del sistema: host, SO, kernel, CPU, memoria, carga y uptime.

Opciones:
  -h, --help   Muestra esta ayuda
EOF
}

# os_name — nombre legible de la distribución (PRETTY_NAME de /etc/os-release).
os_name() {
  local pretty="desconocido"
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    pretty="$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-desconocido}")"
  fi
  printf '%s' "$pretty"
}

# cpu_model — modelo de la primera CPU lógica.
cpu_model() {
  awk -F': ' '/^model name/ {print $2; exit}' /proc/cpuinfo 2>/dev/null || true
}

# mem_summary — "usada / total MiB (porcentaje %)" a partir de /proc/meminfo.
mem_summary() {
  awk '
    /^MemTotal:/     {total=$2}
    /^MemAvailable:/ {avail=$2}
    END {
      if (total == 0) { print "desconocida"; exit }
      used = total - avail
      printf "%d / %d MiB (%d%%)", used/1024, total/1024, used*100/total
    }' /proc/meminfo
}

main() {
  case "${1:-}" in
    -h | --help) usage; exit "$EXIT_OK" ;;
    "") ;;
    *) usage >&2; exit "$EXIT_USAGE" ;;
  esac

  require_cmd awk uptime nproc

  local load
  read -r load _ < /proc/loadavg

  printf '%-10s %s\n' "Host:" "$(hostname)"
  printf '%-10s %s\n' "SO:" "$(os_name)"
  printf '%-10s %s\n' "Kernel:" "$(uname -r)"
  printf '%-10s %s (%s núcleos)\n' "CPU:" "$(cpu_model)" "$(nproc)"
  printf '%-10s %s\n' "Memoria:" "$(mem_summary)"
  printf '%-10s %s (1 min)\n' "Carga:" "$load"
  printf '%-10s %s\n' "Uptime:" "$(uptime -p)"
}

main "$@"
