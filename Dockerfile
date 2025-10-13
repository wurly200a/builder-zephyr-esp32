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

USER root
RUN apt-get update && \
    apt-get install -y --no-install-recommends clangd-18 && \
    rm -rf /var/lib/apt/lists/*

RUN set -e; \
  cat >/usr/local/bin/clangd-with-zephyr <<'EOF' && chmod +x /usr/local/bin/clangd-with-zephyr
#!/usr/bin/env bash
set -euo pipefail

LOG=/tmp/clangd.log
: > "$LOG" || { echo "cannot write $LOG" >&2; exit 1; }

# 1) Auto-detect compile_commands.json
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
if [ -z "${CC_DIR}" ]; then
  if ! CC_DIR="$(find_cc_dir)"; then
    echo "[ERROR] compile_commands.json not found." | tee -a "$LOG"
    echo "       e.g., run: west build -b esp32s3_devkitm/esp32s3 -- -DCMAKE_EXPORT_COMPILE_COMMANDS=ON" | tee -a "$LOG"
    exit 2
  fi
fi

# 2) Enumerate Zephyr SDK cross compilers and pass them to --query-driver
#    The SDK location is taken from env; default to /workspaces/zephyr-sdk
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
  echo "[WARN] No cross compilers found in Zephyr SDK. Continuing without --query-driver." | tee -a "$LOG"
fi

exec clangd-18 \
  --background-index \
  --all-scopes-completion \
  --clang-tidy \
  --header-insertion=never \
  --compile-commands-dir="${CC_DIR}" \
  "${QD_ARG[@]}" \
  "$@" --log=verbose 2>>"$LOG"
EOF
USER ${USER_NAME}

RUN bash -lc "echo \"PS1='(docker)zephyr-esp32:\\w\\$ '\" >> ~/.bashrc"
