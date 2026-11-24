#!/usr/bin/env bats
# Tests de scripts/check-disk.sh con un `df` falso (stub en el PATH).

load helpers

setup() {
  setup_env
}

# fake_df <uso_raiz> <uso_datos> — df falso con dos sistemas de ficheros.
fake_df() {
  make_stub df "printf 'Filesystem Use%% Mounted on\n/dev/sda1 $1%% /\n/dev/sdb1 $2%% /datos\n'"
}

@test "muestra la ayuda con -h" {
  run "${SCRIPTS}/check-disk.sh" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Uso: check-disk.sh"* ]]
}

@test "opción desconocida devuelve 64" {
  run "${SCRIPTS}/check-disk.sh" -z
  [ "$status" -eq 64 ]
}

@test "umbral no numérico devuelve 64" {
  run "${SCRIPTS}/check-disk.sh" -w abc
  [ "$status" -eq 64 ]
}

@test "umbral fuera de 1-100 devuelve 64" {
  run "${SCRIPTS}/check-disk.sh" -c 101
  [ "$status" -eq 64 ]
  run "${SCRIPTS}/check-disk.sh" -w 0
  [ "$status" -eq 64 ]
}

@test "aviso mayor o igual que crítico devuelve 64" {
  run "${SCRIPTS}/check-disk.sh" -w 90 -c 80
  [ "$status" -eq 64 ]
}

@test "todo por debajo del aviso devuelve 0" {
  fake_df 10 20
  run "${SCRIPTS}/check-disk.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"*"/datos"* ]]
}

@test "uso entre aviso y crítico devuelve 1" {
  fake_df 10 85
  run "${SCRIPTS}/check-disk.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"WARNING"*"/datos"* ]]
}

@test "uso por encima del crítico devuelve 2" {
  fake_df 95 85
  run "${SCRIPTS}/check-disk.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"CRITICAL"*"/"* ]]
}

@test "el estado más grave gana" {
  fake_df 91 50
  run "${SCRIPTS}/check-disk.sh"
  [ "$status" -eq 2 ]
}

@test "respeta umbrales personalizados" {
  fake_df 55 10
  run "${SCRIPTS}/check-disk.sh" -w 50 -c 60
  [ "$status" -eq 1 ]
}

@test "el umbral es inclusivo" {
  fake_df 80 10
  run "${SCRIPTS}/check-disk.sh"
  [ "$status" -eq 1 ]
}

@test "acepta rutas explícitas" {
  fake_df 10 20
  run "${SCRIPTS}/check-disk.sh" /datos
  [ "$status" -eq 0 ]
}

@test "si df falla devuelve 3" {
  make_stub df 'exit 1'
  run "${SCRIPTS}/check-disk.sh"
  [ "$status" -eq 3 ]
}
