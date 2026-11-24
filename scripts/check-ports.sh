#!/usr/bin/env bash
# check-ports.sh — lista los puertos en escucha y avisa de los que no están permitidos.
#
# Uso: check-ports.sh [-a PUERTOS] [-f FICHERO] [-i] [-h]
# Códigos de salida: 0 = todo permitido, 1 = hay puertos no permitidos, 3 = desconocido, 64 = uso incorrecto.

set -euo pipefail

# readlink -f: permite ejecutar el script a través de un enlace simbólico (make install).
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

usage() {
  cat <<'EOF'
Uso: check-ports.sh [-a PUERTOS] [-f FICHERO] [-i] [-h]

Lista con `ss` los puertos TCP/UDP en escucha y marca los que no estén en la
lista de permitidos. Por defecto ignora los que solo escuchan en loopback
(127.0.0.1, ::1), porque no son accesibles desde fuera.

Opciones:
  -a LISTA   Puertos permitidos separados por comas (ej. 22,80,443)
  -f FICHERO Fichero con un puerto por línea (admite comentarios con #)
  -i         Incluye también los puertos que solo escuchan en loopback
  -h         Muestra esta ayuda

Sin -a ni -f se usa TOOLKIT_ALLOWED_PORTS (config/toolkit.conf). Si tampoco
existe, el script solo informa y devuelve 0.

Códigos de salida: 0 = todo permitido, 1 = hay puertos no permitidos, 3 = desconocido, 64 = uso incorrecto.
EOF
}

# Puertos permitidos: puerto -> 1.
declare -A ALLOWED=()

# add_allowed <puerto> — valida (1-65535) y registra el puerto.
add_allowed() {
  local port="$1"
  if ! is_uint "$port" || ((port < 1 || port > 65535)); then
    log_error "Puerto no válido: '${port}' (debe estar entre 1 y 65535)"
    exit "$EXIT_USAGE"
  fi
  ALLOWED["$((10#$port))"]=1
}

# add_allowed_list <p1,p2,...> — registra una lista separada por comas.
add_allowed_list() {
  local item
  local -a items
  IFS=',' read -r -a items <<<"$1"
  for item in "${items[@]}"; do
    item="${item//[[:space:]]/}"
    [[ -n "$item" ]] && add_allowed "$item"
  done
  return 0
}

# add_allowed_file <fichero> — un puerto por línea, # comenta.
add_allowed_file() {
  local file="$1" line
  [[ -r "$file" ]] || die "No se puede leer el fichero de puertos: ${file}" "$EXIT_USAGE"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line//[[:space:]]/}"
    [[ -n "$line" ]] && add_allowed "$line"
  done <"$file"
  return 0
}

# is_loopback <dirección> — verdadero para 127.x.x.x y ::1.
is_loopback() {
  [[ "$1" == 127.* || "$1" == "::1" ]]
}

main() {
  local allow_list="" allow_file="" include_loopback=false opt
  load_config
  allow_list="${TOOLKIT_ALLOWED_PORTS:-}"

  while getopts ':a:f:ih' opt; do
    case "$opt" in
      a) allow_list="$OPTARG" ;;
      f) allow_file="$OPTARG" ;;
      i) include_loopback=true ;;
      h) usage; exit "$EXIT_OK" ;;
      *) usage >&2; exit "$EXIT_USAGE" ;;
    esac
  done
  shift $((OPTIND - 1))
  if (($# > 0)); then
    usage >&2
    exit "$EXIT_USAGE"
  fi

  [[ -n "$allow_list" ]] && add_allowed_list "$allow_list"
  [[ -n "$allow_file" ]] && add_allowed_file "$allow_file"
  local have_allowlist=false
  ((${#ALLOWED[@]} > 0)) && have_allowlist=true
  if [[ "$have_allowlist" == false ]]; then
    log_warn "Sin lista de puertos permitidos: solo se informa, no se evalúa"
  fi

  require_cmd ss
  local raw
  raw="$(ss -H -tulnp 2>/dev/null)" || die "No se pudo ejecutar ss" "$EXIT_UNKNOWN"

  # Un mismo puerto suele escucharse en IPv4 e IPv6: se agrupa por protocolo y puerto.
  declare -A addr_of=() proc_of=() exposed_of=()
  local netid local_addr proc port addr name key
  while read -r netid _ _ _ local_addr _ proc; do
    [[ -n "${local_addr:-}" ]] || continue
    port="${local_addr##*:}"
    addr="${local_addr%:*}"
    addr="${addr%%\%*}" # quita la interfaz: 127.0.0.53%lo, [fe80::1]%wlan0
    addr="${addr#\[}"
    addr="${addr%\]}"
    is_uint "$port" || continue
    name=""
    if [[ "${proc:-}" =~ \(\(\"([^\"]+)\" ]]; then
      name="${BASH_REMATCH[1]}"
    fi
    key="${netid}/${port}"
    if ! is_loopback "$addr"; then
      exposed_of["$key"]=1
    fi
    if [[ -z "${addr_of[$key]:-}" ]] || ! is_loopback "$addr"; then
      addr_of["$key"]="$addr"
    fi
    if [[ -n "$name" && -z "${proc_of[$key]:-}" ]]; then
      proc_of["$key"]="$name"
    fi
  done <<<"$raw"

  local unexpected=0 status shown=0 proto
  while read -r key; do
    [[ -n "$key" ]] || continue
    proto="${key%%/*}"
    port="${key##*/}"
    if [[ -z "${exposed_of[$key]:-}" && "$include_loopback" == false ]]; then
      continue
    fi
    if [[ "$have_allowlist" == false ]]; then
      status="INFO"
    elif [[ -n "${ALLOWED[$port]:-}" ]]; then
      status="OK"
    else
      status="WARNING"
      unexpected=$((unexpected + 1))
    fi
    shown=$((shown + 1))
    printf '%-9s %-4s %-6s %-20s %s\n' "$status" "$proto" "$port" "${addr_of[$key]}" "${proc_of[$key]:--}"
  done < <(printf '%s\n' "${!addr_of[@]}" | sort -t/ -k2,2n -k1,1)

  if ((shown == 0)); then
    printf '%-9s %s\n' "OK" "No hay puertos en escucha que revisar"
  fi
  if ((unexpected > 0)); then
    log_warn "${unexpected} puerto(s) en escucha que no están en la lista de permitidos"
    exit "$EXIT_WARNING"
  fi
  exit "$EXIT_OK"
}

main "$@"
