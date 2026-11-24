#!/usr/bin/env bats
# Tests de scripts/backup-rotate.sh. Origen y destino son directorios temporales de bats.

load helpers

setup() {
  setup_env
  SRC="${BATS_TEST_TMPDIR}/datos"
  DEST="${BATS_TEST_TMPDIR}/copias"
  mkdir -p "$SRC/sub"
  echo "uno" >"${SRC}/a.txt"
  echo "dos" >"${SRC}/sub/b.txt"
}

# fake_backups <nombre> <n> — crea n copias antiguas con marcas de hora distintas.
fake_backups() {
  local name="$1" n="$2" i
  mkdir -p "$DEST"
  for ((i = 1; i <= n; i++)); do
    printf 'x' >"${DEST}/${name}-2020010${i}-000000.tar.gz"
    printf 'x' >"${DEST}/${name}-2020010${i}-000000.tar.gz.sha256"
  done
}

@test "muestra la ayuda con -h" {
  run "${SCRIPTS}/backup-rotate.sh" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"flock"* ]]
}

@test "sin orígenes devuelve 64" {
  run "${SCRIPTS}/backup-rotate.sh" -d "$DEST"
  [ "$status" -eq 64 ]
}

@test "sin destino devuelve 64" {
  run "${SCRIPTS}/backup-rotate.sh" "$SRC"
  [ "$status" -eq 64 ]
  [[ "$output" == *"destino"* ]]
}

@test "origen inexistente devuelve 64" {
  run "${SCRIPTS}/backup-rotate.sh" -d "$DEST" "${BATS_TEST_TMPDIR}/nada"
  [ "$status" -eq 64 ]
  [ ! -e "$DEST" ]
}

@test "origen vacío devuelve 64" {
  run "${SCRIPTS}/backup-rotate.sh" -d "$DEST" ""
  [ "$status" -eq 64 ]
}

@test "rechaza / como origen" {
  run "${SCRIPTS}/backup-rotate.sh" -d "$DEST" /
  [ "$status" -eq 64 ]
}

@test "rechaza un destino dentro del origen" {
  run "${SCRIPTS}/backup-rotate.sh" -d "${SRC}/copias" "$SRC"
  [ "$status" -eq 64 ]
  [[ "$output" == *"dentro del origen"* ]]
}

@test "-k inválido devuelve 64" {
  run "${SCRIPTS}/backup-rotate.sh" -d "$DEST" -k 0 "$SRC"
  [ "$status" -eq 64 ]
  run "${SCRIPTS}/backup-rotate.sh" -d "$DEST" -k abc "$SRC"
  [ "$status" -eq 64 ]
}

@test "nombre con caracteres peligrosos devuelve 64" {
  run "${SCRIPTS}/backup-rotate.sh" -d "$DEST" -n '../evil' "$SRC"
  [ "$status" -eq 64 ]
}

@test "crea el tar.gz con el contenido esperado" {
  run "${SCRIPTS}/backup-rotate.sh" -d "$DEST" -n web "$SRC"
  [ "$status" -eq 0 ]
  local archive
  archive="$(ls "$DEST"/web-*.tar.gz)"
  [[ "$archive" =~ web-[0-9]{8}-[0-9]{6}\.tar\.gz$ ]]
  run tar -tzf "$archive"
  [[ "$output" == *"datos/a.txt"* ]]
  [[ "$output" == *"datos/sub/b.txt"* ]]
}

@test "genera un .sha256 que verifica" {
  run "${SCRIPTS}/backup-rotate.sh" -d "$DEST" "$SRC"
  [ "$status" -eq 0 ]
  [[ "$output" == *"checksum SHA-256 verificado"* ]]
  cd "$DEST"
  run sha256sum --check --quiet backup-*.tar.gz.sha256
  [ "$status" -eq 0 ]
}

@test "un archivo corrupto falla la verificación del checksum" {
  "${SCRIPTS}/backup-rotate.sh" -d "$DEST" "$SRC"
  cd "$DEST"
  printf 'corrupto' >>backup-*.tar.gz
  run sha256sum --check --quiet backup-*.tar.gz.sha256
  [ "$status" -ne 0 ]
}

@test "crea el directorio de destino si no existe" {
  run "${SCRIPTS}/backup-rotate.sh" -d "${DEST}/a/b" "$SRC"
  [ "$status" -eq 0 ]
  [ -d "${DEST}/a/b" ]
}

@test "conserva solo las últimas N copias y borra también su .sha256" {
  fake_backups backup 5
  run "${SCRIPTS}/backup-rotate.sh" -d "$DEST" -k 3 "$SRC"
  [ "$status" -eq 0 ]
  [ "$(ls "$DEST"/backup-*.tar.gz | wc -l)" -eq 3 ]
  [ ! -e "${DEST}/backup-20200101-000000.tar.gz" ]
  [ ! -e "${DEST}/backup-20200101-000000.tar.gz.sha256" ]
  [ -e "${DEST}/backup-20200105-000000.tar.gz" ]
}

@test "no toca copias de otro nombre ni ficheros ajenos" {
  fake_backups otro 4
  : >"${DEST}/notas.tar.gz"
  run "${SCRIPTS}/backup-rotate.sh" -d "$DEST" -n backup -k 1 "$SRC"
  [ "$status" -eq 0 ]
  [ "$(ls "$DEST"/otro-*.tar.gz | wc -l)" -eq 4 ]
  [ -e "${DEST}/notas.tar.gz" ]
}

@test "--dry-run no crea ni borra nada" {
  fake_backups backup 3
  run "${SCRIPTS}/backup-rotate.sh" -d "$DEST" -k 2 --dry-run "$SRC"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run] CREATE"* ]]
  [[ "$output" == *"[dry-run] DELETE"*"20200101"* ]]
  [ "$(ls "$DEST"/backup-*.tar.gz | wc -l)" -eq 3 ]
}

@test "--dry-run no crea el destino" {
  run "${SCRIPTS}/backup-rotate.sh" -d "$DEST" --dry-run "$SRC"
  [ "$status" -eq 0 ]
  [ ! -e "$DEST" ]
}

@test "flock: una segunda ejecución simultánea sale con 1 sin crear copia" {
  mkdir -p "$DEST"
  flock "${DEST}/.backup.lock" sleep 5 &
  local holder=$!
  sleep 0.5
  run "${SCRIPTS}/backup-rotate.sh" -d "$DEST" "$SRC"
  kill "$holder" 2>/dev/null || true
  [ "$status" -eq 1 ]
  [[ "$output" == *"otra copia"* ]]
  [ -z "$(ls "$DEST"/backup-*.tar.gz 2>/dev/null)" ]
}

@test "si tar falla devuelve 2 y no deja copia a medias" {
  make_stub tar 'exit 2'
  run "${SCRIPTS}/backup-rotate.sh" -d "$DEST" "$SRC"
  [ "$status" -eq 2 ]
  [ -z "$(ls "$DEST"/backup-* 2>/dev/null)" ]
}

@test "usa destino y N de la configuración" {
  printf 'TOOLKIT_BACKUP_DEST=%s\nTOOLKIT_BACKUP_KEEP=2\n' "$DEST" >"$TOOLKIT_CONF"
  fake_backups backup 4
  run "${SCRIPTS}/backup-rotate.sh" "$SRC"
  [ "$status" -eq 0 ]
  [ "$(ls "$DEST"/backup-*.tar.gz | wc -l)" -eq 2 ]
}
