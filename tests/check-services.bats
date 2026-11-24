#!/usr/bin/env bats
# Tests de scripts/check-services.sh con un `systemctl` falso (stub en el PATH).

load helpers

setup() {
  setup_env
  # nginx: activo · sshd: parado · ghost: no existe.
  make_stub systemctl 'cmd="$1"
unit="${@: -1}"
case "$cmd" in
  show)
    [[ "$unit" == ghost ]] && echo not-found || echo loaded
    ;;
  is-active)
    case "$unit" in
      nginx) echo active ;;
      *) echo inactive; exit 3 ;;
    esac
    ;;
esac
exit 0'
}

@test "muestra la ayuda con -h" {
  run "${SCRIPTS}/check-services.sh" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Uso: check-services.sh"* ]]
}

@test "sin servicios devuelve 64" {
  run "${SCRIPTS}/check-services.sh"
  [ "$status" -eq 64 ]
}

@test "opción desconocida devuelve 64" {
  run "${SCRIPTS}/check-services.sh" -z nginx
  [ "$status" -eq 64 ]
}

@test "nombre de servicio con formato de opción devuelve 64" {
  run "${SCRIPTS}/check-services.sh" -- --now
  [ "$status" -eq 64 ]
  [[ "$output" == *"no válido"* ]]
}

@test "nombre con caracteres peligrosos devuelve 64" {
  run "${SCRIPTS}/check-services.sh" 'nginx;rm -rf /'
  [ "$status" -eq 64 ]
}

@test "servicio activo devuelve 0" {
  run "${SCRIPTS}/check-services.sh" nginx
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"*"nginx"* ]]
}

@test "servicio caído devuelve 2" {
  run "${SCRIPTS}/check-services.sh" sshd
  [ "$status" -eq 2 ]
  [[ "$output" == *"CRITICAL"*"sshd (inactive)"* ]]
}

@test "servicio inexistente devuelve 3" {
  run "${SCRIPTS}/check-services.sh" ghost
  [ "$status" -eq 3 ]
  [[ "$output" == *"UNKNOWN"*"ghost"* ]]
}

@test "caído e inexistente a la vez: gana el 2" {
  run "${SCRIPTS}/check-services.sh" ghost sshd
  [ "$status" -eq 2 ]
}

@test "varios servicios: se informa de cada uno" {
  run "${SCRIPTS}/check-services.sh" nginx sshd ghost
  [[ "$output" == *"OK"*"nginx"* ]]
  [[ "$output" == *"CRITICAL"*"sshd"* ]]
  [[ "$output" == *"UNKNOWN"*"ghost"* ]]
}

@test "-r sin ser root devuelve 64" {
  if [ "$EUID" -eq 0 ]; then
    skip "se ejecuta como root"
  fi
  run "${SCRIPTS}/check-services.sh" -r sshd
  [ "$status" -eq 64 ]
  [[ "$output" == *"root"* ]]
}

@test "sin systemctl devuelve error de dependencia" {
  # PATH mínimo sin systemctl: solo lo imprescindible para ejecutar bash.
  mkdir "${BATS_TEST_TMPDIR}/minimo"
  for cmd in bash dirname readlink date cat env; do
    ln -s "$(command -v "$cmd")" "${BATS_TEST_TMPDIR}/minimo/${cmd}"
  done
  PATH="${BATS_TEST_TMPDIR}/minimo" run "$(command -v bash)" "${SCRIPTS}/check-services.sh" nginx
  [ "$status" -ne 0 ]
  [[ "$output" == *"systemctl"* ]]
}
