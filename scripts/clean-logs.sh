#!/usr/bin/env bash
# clean-logs.sh — comprime los logs antiguos y borra los más viejos de un directorio.
#
# Uso: clean-logs.sh [--apply] [-c DIAS] [-d DIAS] [-r] [-h] DIRECTORIO
# Por defecto solo SIMULA (dry-run): no toca nada hasta que se pasa --apply.
# Códigos de salida: 0 = correcto, 2 = falló alguna operación, 64 = uso incorrecto.

set -euo pipefail

# readlink -f: permite ejecutar el script a través de un enlace simbólico (make install).
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

readonly DEFAULT_COMPRESS_DAYS=7
readonly DEFAULT_DELETE_DAYS=30

usage() {
  cat <<EOF
Uso: clean-logs.sh [--apply] [-c DIAS] [-d DIAS] [-r] [-h] DIRECTORIO

Comprime con gzip los logs de más de -c días y borra los de más de -d días
(según la fecha de modificación). Solo actúa sobre ficheros regulares llamados
*.log o *.log.*; nunca sigue enlaces simbólicos ni sale del sistema de ficheros.

Opciones:
  --apply     Ejecuta los cambios de verdad (sin esto solo se simula)
  --dry-run   Simula (es el comportamiento por defecto; no se puede combinar con --apply)
  -c DIAS     Comprime los logs con más de DIAS días   (por defecto ${DEFAULT_COMPRESS_DAYS})
  -d DIAS     Borra los logs con más de DIAS días      (por defecto ${DEFAULT_DELETE_DAYS})
  -r          Recorre también los subdirectorios
  -h, --help  Muestra esta ayuda

Se rechazan rutas vacías, inexistentes y directorios del sistema (/, /etc, /usr,
/var, /home, el HOME del usuario...). Ejemplo: clean-logs.sh --apply /var/log/miapp

Códigos de salida: 0 = correcto, 2 = falló alguna operación, 64 = uso incorrecto.
EOF
}

# resolve_target <ruta> — valida la ruta y escribe la ruta real en stdout.
resolve_target() {
  local raw="$1" resolved
  if [[ -z "${raw//[[:space:]]/}" ]]; then
    log_error "La ruta del directorio está vacía"
    exit "$EXIT_USAGE"
  fi
  if [[ ! -d "$raw" ]]; then
    log_error "No es un directorio: ${raw}"
    exit "$EXIT_USAGE"
  fi
  resolved="$(realpath -e -- "$raw")"
  case "$resolved" in
    / | /bin | /boot | /dev | /etc | /home | /lib | /lib32 | /lib64 | /opt | /proc | /root | /run | /sbin | /srv | /sys | /tmp | /usr | /var \
      | /boot/* | /dev/* | /etc/* | /proc/* | /sys/* | /usr/* | /bin/* | /sbin/* | /lib/* | /lib64/*)
      log_error "Directorio protegido, no se limpia: ${resolved}"
      exit "$EXIT_USAGE"
      ;;
  esac
  if [[ -n "${HOME:-}" && "$resolved" == "$(realpath -m -- "$HOME")" ]]; then
    log_error "No se limpia el directorio personal: ${resolved}"
    exit "$EXIT_USAGE"
  fi
  printf '%s\n' "$resolved"
}

# validate_days <nombre> <valor> — entero mayor que 0.
validate_days() {
  if ! is_uint "$2" || (($2 < 1)); then
    log_error "${1} debe ser un entero mayor que 0 (recibido: '${2}')"
    exit "$EXIT_USAGE"
  fi
}

main() {
  load_config
  local compress_days="${TOOLKIT_LOG_COMPRESS_DAYS:-$DEFAULT_COMPRESS_DAYS}"
  local delete_days="${TOOLKIT_LOG_DELETE_DAYS:-$DEFAULT_DELETE_DAYS}"
  local apply=false dry=false recursive=false

  while (($# > 0)); do
    case "$1" in
      --apply) apply=true ;;
      --dry-run) dry=true ;;
      -r) recursive=true ;;
      -c | -d)
        (($# >= 2)) || { log_error "La opción $1 necesita un valor"; exit "$EXIT_USAGE"; }
        if [[ "$1" == "-c" ]]; then compress_days="$2"; else delete_days="$2"; fi
        shift
        ;;
      -h | --help) usage; exit "$EXIT_OK" ;;
      --) shift; break ;;
      -*) log_error "Opción desconocida: $1"; usage >&2; exit "$EXIT_USAGE" ;;
      *) break ;;
    esac
    shift
  done

  if (($# != 1)); then
    usage >&2
    exit "$EXIT_USAGE"
  fi
  if [[ "$apply" == true && "$dry" == true ]]; then
    log_error "--apply y --dry-run son incompatibles"
    exit "$EXIT_USAGE"
  fi
  validate_days "Los días de compresión (-c)" "$compress_days"
  validate_days "Los días de borrado (-d)" "$delete_days"
  if ((compress_days >= delete_days)); then
    log_error "Los días de compresión (${compress_days}) deben ser menos que los de borrado (${delete_days})"
    exit "$EXIT_USAGE"
  fi

  require_cmd find gzip stat realpath
  local dir
  dir="$(resolve_target "$1")"

  local depth=(-maxdepth 1)
  [[ "$recursive" == true ]] && depth=()

  local mode_label="dry-run"
  [[ "$apply" == true ]] && mode_label="apply"
  log_info "Directorio: ${dir} (modo ${mode_label}; comprimir > ${compress_days} d, borrar > ${delete_days} d)"

  local failures=0 deleted=0 compressed=0 freed=0 file size
  local compressed_names=(! -name '*.gz' ! -name '*.xz' ! -name '*.bz2' ! -name '*.zst')

  # 1) Borrar lo más viejo.
  while IFS= read -r -d '' file; do
    size="$(stat -c %s -- "$file")"
    if [[ "$apply" == true ]]; then
      if rm -- "$file"; then
        printf '%-9s %s\n' "DELETE" "$file"
      else
        log_error "No se pudo borrar ${file}"
        failures=$((failures + 1))
        continue
      fi
    else
      printf '%-9s %s\n' "[dry-run] DELETE" "$file"
    fi
    deleted=$((deleted + 1))
    freed=$((freed + size))
  done < <(find "$dir" -xdev "${depth[@]}" -type f \( -name '*.log' -o -name '*.log.*' \) -mtime +"$delete_days" -print0)

  # 2) Comprimir lo que ya es viejo pero aún no se borra.
  while IFS= read -r -d '' file; do
    if [[ -e "${file}.gz" ]]; then
      log_warn "Se omite ${file}: ya existe ${file}.gz"
      continue
    fi
    if [[ "$apply" == true ]]; then
      if gzip -- "$file"; then
        printf '%-9s %s\n' "COMPRESS" "$file"
      else
        log_error "No se pudo comprimir ${file}"
        failures=$((failures + 1))
        continue
      fi
    else
      printf '%-9s %s\n' "[dry-run] COMPRESS" "$file"
    fi
    compressed=$((compressed + 1))
  done < <(find "$dir" -xdev "${depth[@]}" -type f \( -name '*.log' -o -name '*.log.[0-9]*' \) "${compressed_names[@]}" -mtime +"$compress_days" ! -mtime +"$delete_days" -print0)

  local prefix=""
  [[ "$apply" == true ]] || prefix="[dry-run] "
  printf '%sResumen: %d comprimidos, %d borrados, %d KiB liberados por el borrado\n' \
    "$prefix" "$compressed" "$deleted" "$((freed / 1024))"
  if [[ "$apply" != true ]]; then
    log_info "Simulación: no se ha modificado nada. Usa --apply para ejecutar."
  fi

  ((failures == 0)) || exit "$EXIT_CRITICAL"
  exit "$EXIT_OK"
}

main "$@"
