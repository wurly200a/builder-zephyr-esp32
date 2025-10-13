FROM ubuntu:24.04 AS base

ARG DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Tokyo

ARG USER_NAME="ubuntu"
ARG GROUP_NAME="ubuntu"

USER root

RUN apt-get update && \
    apt-get install -y --no-install-recommends tzdata ca-certificates && \
    echo "$TZ" > /etc/timezone && \
    ln -sf "/usr/share/zoneinfo/$TZ" /etc/localtime && \
    dpkg-reconfigure -f noninteractive tzdata && \
    apt-get install -y --no-install-recommends \
      git cmake ninja-build gperf \
      ccache dfu-util device-tree-compiler wget \
      python3 python3-dev python3-venv python3-pip python3-setuptools python3-wheel \
      xz-utils file make gcc \
      libsdl2-dev libmagic1 curl && \
    rm -rf /var/lib/apt/lists/*

FROM base AS zephyr-esp32

ENV ZEPHYR_HOME=/workspaces/zephyrproject \
    VENV_PATH=/workspaces/zephyrproject/.venv \
    PATH=/workspaces/zephyrproject/.venv/bin:$PATH

USER ${USER_NAME}
WORKDIR /workspaces

ENV ZEPHYR_SDK_INSTALL_DIR=/workspaces/zephyr-sdk

RUN python3 -m venv ${VENV_PATH} && \
    python -m pip install --upgrade pip setuptools wheel && \
    pip install west && \
    mkdir -p ${ZEPHYR_HOME} && \
    west init ${ZEPHYR_HOME} && \
    cd ${ZEPHYR_HOME} && \
    getent hosts github.com && \
    n=0; \
    until [ $n -ge 6 ]; do \
      west update --narrow --fetch-opt=--depth=1 && break; \
      n=$((n+1)); echo "west update retry $n..."; sleep $((5 * n)); \
    done && \
    west zephyr-export && \
    west packages pip --install && \
    cd ${ZEPHYR_HOME}/zephyr && \
    n=0; \
    until [ $n -ge 6 ]; do \
      west sdk install --install-dir "$ZEPHYR_SDK_INSTALL_DIR" -t xtensa-espressif_esp32_zephyr-elf && break; \
      n=$((n+1)); echo "west update retry $n..."; sleep $((5 * n)); \
    done && \
    n=0; \
    until [ $n -ge 6 ]; do \
      west sdk install --install-dir "$ZEPHYR_SDK_INSTALL_DIR" -t xtensa-espressif_esp32s2_zephyr-elf && break; \
      n=$((n+1)); echo "west update retry $n..."; sleep $((5 * n)); \
    done && \
    n=0; \
    until [ $n -ge 6 ]; do \
      west sdk install --install-dir "$ZEPHYR_SDK_INSTALL_DIR" -t xtensa-espressif_esp32s3_zephyr-elf && break; \
      n=$((n+1)); echo "west update retry $n..."; sleep $((5 * n)); \
    done && \
    n=0; \
    until [ $n -ge 6 ]; do \
      west blobs fetch hal_espressif && break; \
      n=$((n+1)); echo "west update retry $n..."; sleep $((5 * n)); \
    done && \
    echo "===== ZEPHYR SDK installed under: ${ZEPHYR_SDK_INSTALL_DIR} =====" && \
    (ls -al "${ZEPHYR_SDK_INSTALL_DIR}" || true)

# ===== install esp-clang and use it for clangd (start) =====
USER root
# Install basic deps for fetching esp-idf tools (esp-clang)
RUN apt-get update && apt-get install -y --no-install-recommends python3-venv python3-pip git && rm -rf /var/lib/apt/lists/*

# Get ESP-IDF just to use idf_tools.py and export.sh (no IDF build intended)
ARG ESP_IDF_VERSION=v5.3.1
RUN cd /opt && git clone -b ${ESP_IDF_VERSION} --recursive https://github.com/espressif/esp-idf.git

# Install esp-clang toolchain only (kept under /home/${USER_NAME}/.espressif/tools)
USER ${USER_NAME}
RUN cd /opt/esp-idf && python3 ./tools/idf_tools.py install esp-clang && \
    echo "export IDF_PATH=/opt/esp-idf" >> /home/${USER_NAME}/.bashrc && \
    echo "source /opt/esp-idf/export.sh >/dev/null 2>&1" >> /home/${USER_NAME}/.bashrc

USER root
# Provide the Zephyr wrapper that sources ESP-IDF (to put esp-clang's clangd first in PATH)
RUN set -e; \
  cat >/usr/local/bin/clangd-with-zephyr <<'EOF' && chmod +x /usr/local/bin/clangd-with-zephyr
#!/usr/bin/env bash
set -euo pipefail

# Put esp-clang's clang/clangd into PATH (best effort)
if [ -f /opt/esp-idf/export.sh ]; then
  # shellcheck disable=SC1091
  source /opt/esp-idf/export.sh >/dev/null 2>&1 || true
fi

# Fallback: if clangd is still not visible, prepend esp-clang bin under $HOME
if ! command -v clangd >/dev/null 2>&1; then
  for d in "$HOME"/.espressif/tools/esp-clang/*/esp-clang/bin; do
    if [ -x "$d/clangd" ]; then
      export PATH="$d:$PATH"
      break
    fi
  done
fi

# Log file (override with CLANGD_LOG=...)
LOG="${CLANGD_LOG:-/tmp/clangd.log}"
: > "$LOG" || { echo "cannot write $LOG" >&2; exit 1; }
{
  echo "[INFO] which clangd: $(command -v clangd || echo 'NONE')"
  echo "[INFO] PATH=$PATH"
} >>"$LOG"

# 1) Auto-detect compile_commands.json unless given via --compile-commands-dir
find_cc_dir() {
  local d="$PWD"
  while [ "$d" != "/" ]; do
    [ -f "$d/compile_commands.json" ] && { echo "$d"; return 0; }
    [ -f "$d/build/compile_commands.json" ] && { echo "$d/build"; return 0; }
    d="$(dirname "$d")"
  done
  return 1
}
CC_DIR="${ZEPHYR_CC_DIR:-}"
# Allow explicit --compile-commands-dir passed by user
for i in "$@"; do
  case "$i" in
    --compile-commands-dir=*) CC_DIR="${i#*=}";;
  esac
done
if [ -z "${CC_DIR}" ]; then
  if ! CC_DIR="$(find_cc_dir)"; then
    echo "[ERROR] compile_commands.json not found." | tee -a "$LOG"
    echo "       e.g., west build -b esp32s3_devkitm/esp32s3 -- -DCMAKE_EXPORT_COMPILE_COMMANDS=ON" | tee -a "$LOG"
    exit 2
  fi
fi

# 2) Collect Zephyr SDK cross GCCs for --query-driver (we still use GCC for system headers/defines)
SDK_BASE="${ZEPHYR_SDK_INSTALL_DIR:-/workspaces/zephyr-sdk}"
SDK_GLOBS=(
  "${SDK_BASE}/xtensa-*/bin/*-gcc"
  "${SDK_BASE}/arm-zephyr-eabi/bin/arm-zephyr-eabi-gcc"
  "${SDK_BASE}/riscv64-zephyr-elf/bin/riscv64-zephyr-elf-gcc"
)
QD_LIST=()
for g in "${SDK_GLOBS[@]}"; do
  for p in $g; do [ -x "$p" ] && QD_LIST+=("$p"); done
done
QD_ARG=()
if [ ${#QD_LIST[@]} -gt 0 ]; then
  QD_ARG=(--query-driver="$(IFS=,; echo "${QD_LIST[*]}")")
else
  echo "[WARN] Zephyr SDK cross compilers not found; continuing without --query-driver." | tee -a "$LOG"
fi

# Prefer esp-clang's clangd; error if still missing
CLANGD_BIN="$(command -v clangd || true)"
if [ -z "$CLANGD_BIN" ]; then
  echo "[ERROR] clangd not found in PATH (esp-clang not installed?)." | tee -a "$LOG"
  exit 3
fi

exec "$CLANGD_BIN" \
  --background-index \
  --all-scopes-completion \
  --clang-tidy \
  --header-insertion=never \
  --compile-commands-dir="${CC_DIR}" \
  "${QD_ARG[@]}" \
  "$@" --log=verbose 2>>"$LOG"
EOF
USER ${USER_NAME}
# ===== install esp-clang and use it for clangd (end) =====

RUN bash -lc "echo \"PS1='(docker)zephyr-esp32:\\w\\$ '\" >> ~/.bashrc"
