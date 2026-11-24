#!/usr/bin/env bats
# Tests de scripts/ssh-hardening-check.sh con ficheros sshd_config de prueba (nunca el real).

load helpers

setup() {
  setup_env
  FIX="${REPO_ROOT}/tests/fixtures"
  CONF="${BATS_TEST_TMPDIR}/sshd_config"
}

@test "muestra la ayuda con -h y --help" {
  run "${SCRIPTS}/ssh-hardening-check.sh" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"PermitRootLogin"* ]]
  run "${SCRIPTS}/ssh-hardening-check.sh" --help
  [ "$status" -eq 0 ]
}

@test "opción desconocida devuelve 64" {
  run "${SCRIPTS}/ssh-hardening-check.sh" -z
  [ "$status" -eq 64 ]
}

@test "más de un fichero devuelve 64" {
  run "${SCRIPTS}/ssh-hardening-check.sh" "${FIX}/sshd_config.hardened" "${FIX}/sshd_config.insecure"
  [ "$status" -eq 64 ]
}

@test "fichero indicado e inexistente devuelve 64" {
  run "${SCRIPTS}/ssh-hardening-check.sh" "${BATS_TEST_TMPDIR}/no-existe"
  [ "$status" -eq 64 ]
}

@test "ruta vacía devuelve 64" {
  run "${SCRIPTS}/ssh-hardening-check.sh" ""
  [ "$status" -eq 64 ]
}

@test "fichero por defecto ilegible devuelve 3" {
  TOOLKIT_SSHD_CONFIG="${BATS_TEST_TMPDIR}/no-existe" run "${SCRIPTS}/ssh-hardening-check.sh"
  [ "$status" -eq 3 ]
}

@test "usa TOOLKIT_SSHD_CONFIG de la configuración" {
  printf 'TOOLKIT_SSHD_CONFIG=%s\n' "${FIX}/sshd_config.hardened" >"$TOOLKIT_CONF"
  run "${SCRIPTS}/ssh-hardening-check.sh"
  [ "$status" -eq 0 ]
}

@test "configuración endurecida devuelve 0 sin avisos" {
  run "${SCRIPTS}/ssh-hardening-check.sh" "${FIX}/sshd_config.hardened"
  [ "$status" -eq 0 ]
  [[ "$output" != *"WARNING"* ]]
  [[ "$output" != *"CRITICAL"* ]]
  [[ "$output" == *"AllowUsers/AllowGroups"* ]]
}

@test "configuración insegura devuelve 2" {
  run "${SCRIPTS}/ssh-hardening-check.sh" "${FIX}/sshd_config.insecure"
  [ "$status" -eq 2 ]
  [[ "$output" == *"CRITICAL"*"PermitRootLogin = yes"* ]]
  [[ "$output" == *"WARNING"*"PasswordAuthentication = yes"* ]]
  [[ "$output" == *"WARNING"*"X11Forwarding = yes"* ]]
  [[ "$output" == *"WARNING"*"MaxAuthTries = 10"* ]]
  [[ "$output" == *"Port = 2222"* ]]
}

@test "gana la primera aparición de una directiva, como en sshd" {
  # En el fichero inseguro la segunda línea dice 'no', pero la primera dice 'yes'.
  run "${SCRIPTS}/ssh-hardening-check.sh" "${FIX}/sshd_config.insecure"
  [[ "$output" == *"PermitRootLogin = yes"* ]]
}

@test "ignora lo que hay dentro de un bloque Match" {
  run "${SCRIPTS}/ssh-hardening-check.sh" "${FIX}/sshd_config.insecure"
  # Dentro de Match se pone PasswordAuthentication no, que no debe contar.
  [[ "$output" == *"WARNING"*"PasswordAuthentication = yes"* ]]
}

@test "sin directivas evalúa los valores por defecto y lo indica" {
  printf '# vacío\n' >"$CONF"
  run "${SCRIPTS}/ssh-hardening-check.sh" "$CONF"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PermitRootLogin = prohibit-password (por defecto)"* ]]
  [[ "$output" == *"PasswordAuthentication = yes (por defecto)"* ]]
}

@test "PermitRootLogin prohibit-password es aviso, no crítico" {
  printf 'PermitRootLogin prohibit-password\n' >"$CONF"
  run "${SCRIPTS}/ssh-hardening-check.sh" "$CONF"
  [[ "$output" == *"WARNING"*"PermitRootLogin = prohibit-password"* ]]
  [[ "$output" != *"CRITICAL"* ]]
}

@test "PermitEmptyPasswords yes es crítico" {
  printf 'PermitEmptyPasswords yes\n' >"$CONF"
  run "${SCRIPTS}/ssh-hardening-check.sh" "$CONF"
  [ "$status" -eq 2 ]
  [[ "$output" == *"CRITICAL"*"PermitEmptyPasswords = yes"* ]]
}

@test "entiende el formato Directiva=valor y no distingue mayúsculas" {
  printf 'permitrootlogin=NO\nPASSWORDAUTHENTICATION No\n' >"$CONF"
  run "${SCRIPTS}/ssh-hardening-check.sh" "$CONF"
  [[ "$output" == *"OK"*"PermitRootLogin = NO"* ]]
  [[ "$output" == *"OK"*"PasswordAuthentication = No"* ]]
}

@test "Protocol 1 es crítico" {
  printf 'Protocol 1\n' >"$CONF"
  run "${SCRIPTS}/ssh-hardening-check.sh" "$CONF"
  [ "$status" -eq 2 ]
  [[ "$output" == *"CRITICAL"*"Protocol = 1"* ]]
}

@test "ChallengeResponseAuthentication se acepta como alias antiguo" {
  printf 'ChallengeResponseAuthentication no\n' >"$CONF"
  run "${SCRIPTS}/ssh-hardening-check.sh" "$CONF"
  [[ "$output" == *"OK"*"KbdInteractiveAuthentication = no"* ]]
}

@test "sigue las líneas Include (ruta relativa y absoluta)" {
  mkdir "${BATS_TEST_TMPDIR}/conf.d"
  printf 'PermitRootLogin no\n' >"${BATS_TEST_TMPDIR}/conf.d/10-root.conf"
  printf 'PasswordAuthentication no\n' >"${BATS_TEST_TMPDIR}/conf.d/20-pass.conf"
  printf 'Include conf.d/10-*.conf\nInclude %s/conf.d/20-*.conf\n' "$BATS_TEST_TMPDIR" >"$CONF"
  run "${SCRIPTS}/ssh-hardening-check.sh" "$CONF"
  [[ "$output" == *"OK"*"PermitRootLogin = no"* ]]
  [[ "$output" == *"OK"*"PasswordAuthentication = no"* ]]
}

@test "un Include circular no provoca un bucle infinito" {
  printf 'Include %s\nPermitRootLogin no\n' "$CONF" >"$CONF"
  run timeout 10 "${SCRIPTS}/ssh-hardening-check.sh" "$CONF"
  [ "$status" -ne 124 ]
  [[ "$output" == *"PermitRootLogin = no"* ]]
}

@test "no modifica el fichero auditado" {
  cp "${FIX}/sshd_config.insecure" "$CONF"
  before="$(sha256sum "$CONF")"
  run "${SCRIPTS}/ssh-hardening-check.sh" "$CONF"
  [ "$before" = "$(sha256sum "$CONF")" ]
}
