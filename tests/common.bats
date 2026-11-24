#!/usr/bin/env bats
# Tests de lib/common.sh: is_uint y load_config.

load helpers

setup() {
  setup_env
}

# Ejecuta código bash con la librería ya cargada.
run_lib() {
  run bash -c "set -euo pipefail; source '${REPO_ROOT}/lib/common.sh'; $1"
}

@test "is_uint acepta enteros no negativos" {
  run_lib 'is_uint 0 && is_uint 42'
  [ "$status" -eq 0 ]
}

@test "is_uint rechaza vacío, negativos y texto" {
  run_lib '! is_uint "" && ! is_uint -1 && ! is_uint abc && ! is_uint 1.5'
  [ "$status" -eq 0 ]
}

@test "load_config lee valores con y sin comillas" {
  printf '# comentario\nTOOLKIT_A=uno\nTOOLKIT_B="dos palabras"\n  TOOLKIT_C = '"'tres'"'\n' >"$TOOLKIT_CONF"
  run_lib 'load_config; printf "%s|%s|%s" "$TOOLKIT_A" "$TOOLKIT_B" "$TOOLKIT_C"'
  [ "$status" -eq 0 ]
  [ "$output" = "uno|dos palabras|tres" ]
}

@test "load_config no sobrescribe variables ya definidas en el entorno" {
  printf 'TOOLKIT_A=del-fichero\n' >"$TOOLKIT_CONF"
  TOOLKIT_A=del-entorno run_lib 'load_config; printf "%s" "$TOOLKIT_A"'
  [ "$output" = "del-entorno" ]
}

@test "load_config no ejecuta código del fichero" {
  printf 'TOOLKIT_A=$(touch %s/pwned)\n$(touch %s/pwned2)\n' "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR" >"$TOOLKIT_CONF"
  run_lib 'load_config'
  [ "$status" -eq 0 ]
  [ ! -e "${BATS_TEST_TMPDIR}/pwned" ]
  [ ! -e "${BATS_TEST_TMPDIR}/pwned2" ]
}

@test "load_config ignora claves que no empiezan por TOOLKIT_" {
  printf 'PATH=/tmp\nOTRA=1\n' >"$TOOLKIT_CONF"
  run_lib 'load_config; printf "%s" "${OTRA:-vacia}"'
  [ "$output" = "vacia" ]
}

@test "load_config falla con 64 si TOOLKIT_CONF apunta a un fichero inexistente" {
  TOOLKIT_CONF="${BATS_TEST_TMPDIR}/no-existe.conf" run_lib 'load_config'
  [ "$status" -eq 64 ]
}
