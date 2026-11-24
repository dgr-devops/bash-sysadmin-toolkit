#!/usr/bin/env bats
# Tests de scripts/clean-logs.sh. Todo ocurre en directorios temporales de bats.

load helpers

setup() {
  setup_env
  LOGDIR="${BATS_TEST_TMPDIR}/logs"
  mkdir -p "$LOGDIR"
  # Cuatro edades: reciente (2 d), media (10 d), vieja (40 d) y un fichero que no es log.
  make_log recent.log 2
  make_log middle.log 10
  make_log old.log 40
  make_log notes.txt 60
}

# make_log <nombre> <días> — crea un fichero de 2 KiB con esa antigüedad.
make_log() {
  truncate -s 2048 "${LOGDIR}/$1"
  touch -d "$2 days ago" "${LOGDIR}/$1"
}

@test "muestra la ayuda con -h" {
  run "${SCRIPTS}/clean-logs.sh" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"--apply"* ]]
}

@test "sin directorio devuelve 64" {
  run "${SCRIPTS}/clean-logs.sh"
  [ "$status" -eq 64 ]
}

@test "ruta vacía devuelve 64 y no hace nada" {
  run "${SCRIPTS}/clean-logs.sh" --apply ""
  [ "$status" -eq 64 ]
  [[ "$output" == *"vacía"* ]]
}

@test "ruta inexistente devuelve 64" {
  run "${SCRIPTS}/clean-logs.sh" "${BATS_TEST_TMPDIR}/no-existe"
  [ "$status" -eq 64 ]
}

@test "rechaza directorios del sistema" {
  for dir in / /etc /usr /var /home /boot /usr/lib; do
    run "${SCRIPTS}/clean-logs.sh" --apply "$dir"
    [ "$status" -eq 64 ]
    [[ "$output" == *"protegido"* ]]
  done
}

@test "rechaza el directorio personal" {
  HOME="$LOGDIR" run "${SCRIPTS}/clean-logs.sh" --apply "$LOGDIR"
  [ "$status" -eq 64 ]
  [ -e "${LOGDIR}/old.log" ]
}

@test "rechaza un enlace simbólico que apunta a un directorio protegido" {
  ln -s /etc "${BATS_TEST_TMPDIR}/enlace"
  run "${SCRIPTS}/clean-logs.sh" --apply "${BATS_TEST_TMPDIR}/enlace"
  [ "$status" -eq 64 ]
}

@test "--apply y --dry-run a la vez devuelve 64" {
  run "${SCRIPTS}/clean-logs.sh" --apply --dry-run "$LOGDIR"
  [ "$status" -eq 64 ]
}

@test "días no numéricos o cero devuelven 64" {
  run "${SCRIPTS}/clean-logs.sh" -c abc "$LOGDIR"
  [ "$status" -eq 64 ]
  run "${SCRIPTS}/clean-logs.sh" -d 0 "$LOGDIR"
  [ "$status" -eq 64 ]
}

@test "comprimir debe ser menor que borrar" {
  run "${SCRIPTS}/clean-logs.sh" -c 30 -d 7 "$LOGDIR"
  [ "$status" -eq 64 ]
}

@test "por defecto simula: informa pero no cambia nada" {
  run "${SCRIPTS}/clean-logs.sh" "$LOGDIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run] DELETE"*"old.log"* ]]
  [[ "$output" == *"[dry-run] COMPRESS"*"middle.log"* ]]
  [ -e "${LOGDIR}/old.log" ]
  [ -e "${LOGDIR}/middle.log" ]
  [ ! -e "${LOGDIR}/middle.log.gz" ]
}

@test "--dry-run explícito tampoco cambia nada" {
  run "${SCRIPTS}/clean-logs.sh" --dry-run "$LOGDIR"
  [ "$status" -eq 0 ]
  [ -e "${LOGDIR}/old.log" ]
}

@test "--apply borra lo viejo, comprime lo medio y respeta lo reciente" {
  run "${SCRIPTS}/clean-logs.sh" --apply "$LOGDIR"
  [ "$status" -eq 0 ]
  [ ! -e "${LOGDIR}/old.log" ]
  [ ! -e "${LOGDIR}/middle.log" ]
  [ -e "${LOGDIR}/middle.log.gz" ]
  [ -e "${LOGDIR}/recent.log" ]
}

@test "no toca ficheros que no son logs" {
  run "${SCRIPTS}/clean-logs.sh" --apply "$LOGDIR"
  [ -e "${LOGDIR}/notes.txt" ]
}

@test "respeta -c y -d personalizados" {
  run "${SCRIPTS}/clean-logs.sh" --apply -c 1 -d 5 "$LOGDIR"
  [ "$status" -eq 0 ]
  [ ! -e "${LOGDIR}/middle.log" ]
  [ -e "${LOGDIR}/recent.log.gz" ]
}

@test "un .gz ya existente no se pisa" {
  echo previo | gzip >"${LOGDIR}/middle.log.gz"
  run "${SCRIPTS}/clean-logs.sh" --apply "$LOGDIR"
  [ "$status" -eq 0 ]
  [ -e "${LOGDIR}/middle.log" ]
  [[ "$output" == *"ya existe"* ]]
}

@test "no sigue enlaces simbólicos a ficheros" {
  echo dato >"${BATS_TEST_TMPDIR}/fuera.log"
  touch -d "90 days ago" "${BATS_TEST_TMPDIR}/fuera.log"
  ln -s "${BATS_TEST_TMPDIR}/fuera.log" "${LOGDIR}/enlace.log"
  run "${SCRIPTS}/clean-logs.sh" --apply "$LOGDIR"
  [ -e "${BATS_TEST_TMPDIR}/fuera.log" ]
}

@test "sin -r no entra en subdirectorios; con -r sí" {
  mkdir "${LOGDIR}/sub"
  truncate -s 10 "${LOGDIR}/sub/viejo.log"
  touch -d "90 days ago" "${LOGDIR}/sub/viejo.log"
  run "${SCRIPTS}/clean-logs.sh" --apply "$LOGDIR"
  [ -e "${LOGDIR}/sub/viejo.log" ]
  run "${SCRIPTS}/clean-logs.sh" --apply -r "$LOGDIR"
  [ ! -e "${LOGDIR}/sub/viejo.log" ]
}

@test "usa los días de la configuración" {
  printf 'TOOLKIT_LOG_COMPRESS_DAYS=1\nTOOLKIT_LOG_DELETE_DAYS=5\n' >"$TOOLKIT_CONF"
  run "${SCRIPTS}/clean-logs.sh" --apply "$LOGDIR"
  [ ! -e "${LOGDIR}/middle.log" ]
}
