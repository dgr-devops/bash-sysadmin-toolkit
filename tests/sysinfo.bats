#!/usr/bin/env bats
# Tests de scripts/sysinfo.sh: solo lectura del sistema, sin efectos.

load helpers

setup() {
  setup_env
}

@test "muestra la ayuda con -h y --help" {
  run "${SCRIPTS}/sysinfo.sh" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Uso: sysinfo.sh"* ]]
  run "${SCRIPTS}/sysinfo.sh" --help
  [ "$status" -eq 0 ]
}

@test "argumento desconocido devuelve 64" {
  run "${SCRIPTS}/sysinfo.sh" --nada
  [ "$status" -eq 64 ]
}

@test "imprime todas las secciones del resumen" {
  run "${SCRIPTS}/sysinfo.sh"
  [ "$status" -eq 0 ]
  for label in "Host:" "SO:" "Kernel:" "CPU:" "Memoria:" "Carga:" "Uptime:"; do
    [[ "$output" == *"$label"* ]]
  done
}

@test "la memoria se muestra con porcentaje" {
  run "${SCRIPTS}/sysinfo.sh"
  [[ "$output" =~ Memoria:[[:space:]]+[0-9]+\ /\ [0-9]+\ MiB\ \([0-9]+%\) ]]
}

@test "el kernel coincide con uname -r" {
  run "${SCRIPTS}/sysinfo.sh"
  [[ "$output" == *"$(uname -r)"* ]]
}

@test "funciona al ejecutarse a través de un enlace simbólico" {
  ln -s "${SCRIPTS}/sysinfo.sh" "${BATS_TEST_TMPDIR}/sysinfo"
  run "${BATS_TEST_TMPDIR}/sysinfo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Host:"* ]]
}
