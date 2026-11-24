#!/usr/bin/env bats
# Tests de scripts/user-audit.sh sobre un árbol de ficheros sintético (tests/fixtures/rootfs).

load helpers

setup() {
  setup_env
  FIXTURE="${REPO_ROOT}/tests/fixtures/rootfs"
  # `last` falso: nunca se lee el wtmp real.
  make_stub last 'printf "alice    pts/0  10.0.0.5  Mon Nov 23 10:00 - 10:30  (00:30)\n"'
  # Copia limpia y modificable del árbol de pruebas.
  ROOT="${BATS_TEST_TMPDIR}/rootfs"
  cp -r "$FIXTURE" "$ROOT"
}

@test "muestra la ayuda con -h" {
  run "${SCRIPTS}/user-audit.sh" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Uso: user-audit.sh"* ]]
}

@test "opción desconocida devuelve 64" {
  run "${SCRIPTS}/user-audit.sh" -z
  [ "$status" -eq 64 ]
}

@test "-n inválido devuelve 64" {
  run "${SCRIPTS}/user-audit.sh" -r "$ROOT" -n 0
  [ "$status" -eq 64 ]
}

@test "raíz inexistente devuelve 64" {
  run "${SCRIPTS}/user-audit.sh" -r "${BATS_TEST_TMPDIR}/nada"
  [ "$status" -eq 64 ]
}

@test "raíz sin /etc/passwd devuelve 3" {
  mkdir "${BATS_TEST_TMPDIR}/vacia"
  run "${SCRIPTS}/user-audit.sh" -r "${BATS_TEST_TMPDIR}/vacia"
  [ "$status" -eq 3 ]
}

@test "detecta una segunda cuenta con UID 0 como crítica" {
  run "${SCRIPTS}/user-audit.sh" -r "$ROOT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"CRITICAL"*"toor"*"UID 0"* ]]
}

@test "lista usuarios con shell de login y omite los nologin" {
  run "${SCRIPTS}/user-audit.sh" -r "$ROOT"
  [[ "$output" == *"alice (uid 1000) shell /bin/bash"* ]]
  [[ "$output" == *"bob (uid 1001) shell /bin/zsh"* ]]
  [[ "$output" != *"daemon (uid"* ]]
  [[ "$output" != *"carol (uid"* ]]
  [[ "$output" != *"sync (uid"* ]]
}

@test "avisa de cuentas de sistema con shell de login" {
  run "${SCRIPTS}/user-audit.sh" -r "$ROOT"
  [[ "$output" == *"WARNING"*"backup (uid 34)"* ]]
}

@test "muestra los miembros de sudo y wheel, incluido el grupo primario" {
  run "${SCRIPTS}/user-audit.sh" -r "$ROOT"
  [[ "$output" == *"grupo sudo: alice,carol"* ]]
  [[ "$output" == *"grupo wheel: bob"* ]]
}

@test "lee sudoers y sudoers.d y avisa de NOPASSWD" {
  run "${SCRIPTS}/user-audit.sh" -r "$ROOT"
  [[ "$output" == *"%sudo ALL=(ALL:ALL) ALL"* ]]
  [[ "$output" == *"WARNING"*"NOPASSWD"*"bob"* ]]
}

@test "ignora comentarios, Defaults y ficheros de sudoers.d con punto" {
  run "${SCRIPTS}/user-audit.sh" -r "$ROOT"
  [[ "$output" != *"Defaults"* ]]
  [[ "$output" != *"ignorado"* ]]
}

@test "detecta contraseñas vacías en shadow" {
  run "${SCRIPTS}/user-audit.sh" -r "$ROOT"
  [[ "$output" == *"CRITICAL"*"'guest' no tiene contraseña"* ]]
}

@test "muestra los últimos accesos con last" {
  run "${SCRIPTS}/user-audit.sh" -r "$ROOT"
  [[ "$output" == *"alice    pts/0"* ]]
}

@test "árbol limpio devuelve 1 por el NOPASSWD y el shell de sistema, no 2" {
  sed -i '/^toor:/d' "${ROOT}/etc/passwd"
  sed -i '/^guest:/d' "${ROOT}/etc/shadow"
  run "${SCRIPTS}/user-audit.sh" -r "$ROOT"
  [ "$status" -eq 1 ]
}

@test "árbol sin hallazgos devuelve 0" {
  sed -i '/^toor:/d; /^backup:/d' "${ROOT}/etc/passwd"
  sed -i '/^guest:/d' "${ROOT}/etc/shadow"
  rm "${ROOT}/etc/sudoers.d/deploy"
  run "${SCRIPTS}/user-audit.sh" -r "$ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Solo root tiene UID 0"* ]]
}

@test "shadow ilegible marca la auditoría como incompleta (3)" {
  sed -i '/^toor:/d; /^backup:/d' "${ROOT}/etc/passwd"
  rm "${ROOT}/etc/sudoers.d/deploy"
  chmod 000 "${ROOT}/etc/shadow"
  if [ -r "${ROOT}/etc/shadow" ]; then
    skip "se ejecuta como root: chmod 000 no impide leer"
  fi
  run "${SCRIPTS}/user-audit.sh" -r "$ROOT"
  [ "$status" -eq 3 ]
  [[ "$output" == *"UNKNOWN"*"shadow"* ]]
}

@test "no modifica ningún fichero del árbol auditado" {
  before="$(cd "$ROOT" && find . -type f -exec sha256sum {} + | sort)"
  run "${SCRIPTS}/user-audit.sh" -r "$ROOT"
  after="$(cd "$ROOT" && find . -type f -exec sha256sum {} + | sort)"
  [ "$before" = "$after" ]
}
