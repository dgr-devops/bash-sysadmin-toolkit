# tests/helpers.bash — utilidades comunes de los tests (se cargan con `load helpers`).
# Todo ocurre dentro de $BATS_TEST_TMPDIR: los tests nunca tocan ficheros reales del sistema.

REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
SCRIPTS="${REPO_ROOT}/scripts"

# setup_env — entorno aislado: sin colores, sin configuración real y con un directorio de stubs al frente del PATH.
setup_env() {
  export NO_COLOR=1
  export STUB_DIR="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$STUB_DIR"
  export PATH="${STUB_DIR}:${PATH}"
  : >"${BATS_TEST_TMPDIR}/empty.conf"
  export TOOLKIT_CONF="${BATS_TEST_TMPDIR}/empty.conf"
  unset TOOLKIT_ALLOWED_PORTS TOOLKIT_LOG_COMPRESS_DAYS TOOLKIT_LOG_DELETE_DAYS \
    TOOLKIT_BACKUP_DEST TOOLKIT_BACKUP_KEEP TOOLKIT_SSHD_CONFIG
}

# make_stub <nombre> <cuerpo> — crea un ejecutable falso en el PATH del test.
make_stub() {
  local name="$1" body="$2"
  printf '#!/usr/bin/env bash\n%s\n' "$body" >"${STUB_DIR}/${name}"
  chmod +x "${STUB_DIR}/${name}"
}
