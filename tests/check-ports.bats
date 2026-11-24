#!/usr/bin/env bats
# Tests de scripts/check-ports.sh con un `ss` falso (stub en el PATH).

load helpers

setup() {
  setup_env
  # Salida con el mismo formato que `ss -H -tulnp`.
  make_stub ss 'cat <<EOF
tcp LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=812,fd=3))
tcp LISTEN 0 128 [::]:22 [::]:* users:(("sshd",pid=812,fd=4))
tcp LISTEN 0 511 *:80 *:* users:(("nginx",pid=900,fd=6))
tcp LISTEN 0 4096 127.0.0.1:631 0.0.0.0:*
tcp LISTEN 0 4096 [fe80::1]%wlan0:8080 [::]:*
udp UNCONN 0 0 127.0.0.53%lo:53 0.0.0.0:*
EOF'
}

@test "muestra la ayuda con -h y sale con 0" {
  run "${SCRIPTS}/check-ports.sh" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Uso: check-ports.sh"* ]]
}

@test "opción desconocida devuelve 64" {
  run "${SCRIPTS}/check-ports.sh" -z
  [ "$status" -eq 64 ]
}

@test "argumentos posicionales devuelven 64" {
  run "${SCRIPTS}/check-ports.sh" 22
  [ "$status" -eq 64 ]
}

@test "puerto fuera de rango devuelve 64" {
  run "${SCRIPTS}/check-ports.sh" -a 22,99999
  [ "$status" -eq 64 ]
  [[ "$output" == *"Puerto no válido"* ]]
}

@test "puerto no numérico devuelve 64" {
  run "${SCRIPTS}/check-ports.sh" -a ssh
  [ "$status" -eq 64 ]
}

@test "todos los puertos expuestos permitidos devuelve 0" {
  run "${SCRIPTS}/check-ports.sh" -a 22,80,8080
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"*"22"*"sshd"* ]]
  [[ "$output" != *"WARNING"* ]]
}

@test "puerto no permitido devuelve 1 y lo marca" {
  run "${SCRIPTS}/check-ports.sh" -a 22,80
  [ "$status" -eq 1 ]
  [[ "$output" == *"WARNING"*"8080"* ]]
}

@test "agrupa IPv4 e IPv6 del mismo puerto en una sola línea" {
  run "${SCRIPTS}/check-ports.sh" -a 22,80,8080
  [ "$status" -eq 0 ]
  [ "$(grep -c ' 22 ' <<<"$output")" -eq 1 ]
}

@test "ignora loopback por defecto" {
  run "${SCRIPTS}/check-ports.sh" -a 22,80,8080
  [[ "$output" != *"631"* ]]
}

@test "con -i incluye loopback y lo evalúa" {
  run "${SCRIPTS}/check-ports.sh" -a 22,80,8080 -i
  [ "$status" -eq 1 ]
  [[ "$output" == *"WARNING"*"631"* ]]
}

@test "lee la lista de permitidos de un fichero con comentarios" {
  printf '# servicios\n22\n80 # web\n\n8080\n' >"${BATS_TEST_TMPDIR}/ports.txt"
  run "${SCRIPTS}/check-ports.sh" -f "${BATS_TEST_TMPDIR}/ports.txt"
  [ "$status" -eq 0 ]
}

@test "fichero de puertos inexistente devuelve 64" {
  run "${SCRIPTS}/check-ports.sh" -f "${BATS_TEST_TMPDIR}/no-existe.txt"
  [ "$status" -eq 64 ]
}

@test "usa TOOLKIT_ALLOWED_PORTS de la configuración" {
  printf 'TOOLKIT_ALLOWED_PORTS=22,80\n' >"$TOOLKIT_CONF"
  run "${SCRIPTS}/check-ports.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"WARNING"*"8080"* ]]
}

@test "sin lista de permitidos solo informa y devuelve 0" {
  run "${SCRIPTS}/check-ports.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"INFO"* ]]
}

@test "si ss falla devuelve 3" {
  make_stub ss 'exit 1'
  run "${SCRIPTS}/check-ports.sh" -a 22
  [ "$status" -eq 3 ]
}
