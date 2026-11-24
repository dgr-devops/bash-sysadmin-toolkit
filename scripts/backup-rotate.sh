#!/usr/bin/env bash
# backup-rotate.sh — crea una copia tar.gz con marca de hora, verifica su checksum y conserva solo las últimas N.
#
# Uso: backup-rotate.sh [-d DESTINO] [-k N] [-n NOMBRE] [--dry-run] [-h] ORIGEN...
# Códigos de salida: 0 = correcto, 1 = otra ejecución en curso, 2 = falló la copia o la verificación, 64 = uso incorrecto.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

readonly DEFAULT_KEEP=7
readonly DEFAULT_NAME="backup"
readonly NAME_PATTERN='^[A-Za-z0-9][A-Za-z0-9._-]*$'

usage() {
  cat <<EOF
Uso: backup-rotate.sh [-d DESTINO] [-k N] [-n NOMBRE] [--dry-run] [-h] ORIGEN...

Crea DESTINO/NOMBRE-AAAAMMDD-HHMMSS.tar.gz con los ORIGEN indicados, guarda su
suma SHA-256 en un .sha256 al lado, la verifica y borra las copias más antiguas
para quedarse solo con las últimas N. Usa flock para impedir ejecuciones
simultáneas sobre el mismo destino y nombre.

Opciones:
  -d DIR       Directorio de destino (o TOOLKIT_BACKUP_DEST)
  -k N         Copias a conservar, mínimo 1  (por defecto ${DEFAULT_KEEP})
  -n NOMBRE    Prefijo de las copias         (por defecto ${DEFAULT_NAME})
  --dry-run    Muestra qué haría sin crear ni borrar nada
  -h, --help   Muestra esta ayuda

Códigos de salida: 0 = correcto, 1 = otra ejecución en curso, 2 = falló la copia o la verificación, 64 = uso incorrecto.
EOF
}

# list_backups <destino> <nombre> — copias existentes, de la más antigua a la más reciente.
# El patrón estricto evita tocar ficheros ajenos que viven en el mismo directorio.
list_backups() {
  local dest="$1" name="$2" file base
  local -a found=()
  for file in "$dest"/"${name}"-*.tar.gz; do
    [[ -e "$file" ]] || continue
    base="${file##*/}"
    if [[ "$base" =~ ^${name//./\\.}-[0-9]{8}-[0-9]{6}\.tar\.gz$ ]]; then
      found+=("$file")
    fi
  done
  ((${#found[@]} == 0)) || printf '%s\n' "${found[@]}" | sort
}

# kib <fichero> — tamaño en KiB.
kib() {
  local bytes
  bytes="$(stat -c %s -- "$1")"
  printf '%d' $((bytes / 1024))
}

# rotate <destino> <nombre> <conservar> <dry_run> — borra las copias sobrantes.
rotate() {
  local dest="$1" name="$2" keep="$3" dry="$4" file
  local -a all=() old=()
  mapfile -t all < <(list_backups "$dest" "$name")
  local extra=$((${#all[@]} - keep))
  ((extra > 0)) || return 0
  old=("${all[@]:0:extra}")
  for file in "${old[@]}"; do
    if [[ "$dry" == true ]]; then
      printf '%-9s %s\n' "[dry-run] DELETE" "$file"
    else
      rm -f -- "$file" "${file}.sha256"
      printf '%-9s %s\n' "DELETE" "$file"
    fi
  done
}

main() {
  load_config
  local dest="${TOOLKIT_BACKUP_DEST:-}" keep="${TOOLKIT_BACKUP_KEEP:-$DEFAULT_KEEP}"
  local name="$DEFAULT_NAME" dry=false

  while (($# > 0)); do
    case "$1" in
      -d | -k | -n)
        (($# >= 2)) || { log_error "La opción $1 necesita un valor"; exit "$EXIT_USAGE"; }
        case "$1" in -d) dest="$2" ;; -k) keep="$2" ;; -n) name="$2" ;; esac
        shift
        ;;
      --dry-run) dry=true ;;
      -h | --help) usage; exit "$EXIT_OK" ;;
      --) shift; break ;;
      -*) log_error "Opción desconocida: $1"; usage >&2; exit "$EXIT_USAGE" ;;
      *) break ;;
    esac
    shift
  done

  if (($# == 0)); then
    usage >&2
    exit "$EXIT_USAGE"
  fi
  if [[ -z "$dest" ]]; then
    log_error "Falta el directorio de destino (-d o TOOLKIT_BACKUP_DEST)"
    exit "$EXIT_USAGE"
  fi
  if ! is_uint "$keep" || ((keep < 1)); then
    log_error "-k debe ser un entero mayor que 0 (recibido: '${keep}')"
    exit "$EXIT_USAGE"
  fi
  if [[ ! "$name" =~ $NAME_PATTERN ]]; then
    log_error "Nombre no válido: '${name}' (solo letras, números, punto, guion y guion bajo)"
    exit "$EXIT_USAGE"
  fi

  require_cmd tar gzip sha256sum flock realpath stat sort

  # Orígenes: deben existir, ser legibles y no contener al destino (la copia se incluiría a sí misma).
  local dest_real src real
  dest_real="$(realpath -m -- "$dest")"
  local -a rel_sources=()
  for src in "$@"; do
    if [[ -z "${src//[[:space:]]/}" || ! -e "$src" ]]; then
      log_error "El origen no existe: '${src}'"
      exit "$EXIT_USAGE"
    fi
    real="$(realpath -e -- "$src")"
    if [[ "$real" == "/" ]]; then
      log_error "No se admite / como origen"
      exit "$EXIT_USAGE"
    fi
    if [[ "$dest_real" == "$real" || "$dest_real" == "$real"/* ]]; then
      log_error "El destino (${dest_real}) está dentro del origen (${real})"
      exit "$EXIT_USAGE"
    fi
    rel_sources+=("${real#/}")
  done

  local stamp archive
  stamp="$(date '+%Y%m%d-%H%M%S')"
  archive="${dest_real}/${name}-${stamp}.tar.gz"

  if [[ "$dry" == true ]]; then
    printf '%-9s %s\n' "[dry-run] CREATE" "$archive"
    printf '%-9s %s\n' "[dry-run] CREATE" "${archive}.sha256"
    rotate "$dest_real" "$name" "$((keep - 1))" true
    log_info "Simulación: no se ha creado ni borrado nada."
    exit "$EXIT_OK"
  fi

  mkdir -p -- "$dest_real"
  # Cerrojo: un segundo proceso con el mismo destino y nombre no puede avanzar.
  exec 9>"${dest_real}/.${name}.lock"
  if ! flock -n 9; then
    log_warn "Ya hay otra copia '${name}' en curso sobre ${dest_real}; se cancela"
    exit "$EXIT_WARNING"
  fi

  if [[ -e "$archive" ]]; then
    die "Ya existe ${archive} (dos copias en el mismo segundo)" "$EXIT_CRITICAL"
  fi

  local partial="${archive}.partial"
  # Si algo falla no se deja una copia a medias.
  trap 'rm -f -- "$partial"' EXIT
  if ! tar -C / -czf "$partial" -- "${rel_sources[@]}"; then
    log_error "tar falló al crear la copia"
    exit "$EXIT_CRITICAL"
  fi
  mv -- "$partial" "$archive"

  # El .sha256 usa el nombre sin ruta para poder verificarlo desde el propio directorio.
  (cd "$dest_real" && sha256sum -- "${archive##*/}" >"${archive##*/}.sha256")
  if ! (cd "$dest_real" && sha256sum --check --quiet -- "${archive##*/}.sha256"); then
    log_error "La verificación del checksum de ${archive} falló"
    exit "$EXIT_CRITICAL"
  fi
  printf '%-9s %s (%d KiB)\n' "OK" "$archive" "$(kib "$archive")"
  printf '%-9s %s\n' "OK" "checksum SHA-256 verificado: ${archive}.sha256"

  rotate "$dest_real" "$name" "$keep" false
  exit "$EXIT_OK"
}

main "$@"
