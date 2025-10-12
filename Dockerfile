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

ENV ZEPHYR_HOME=/home/${USER_NAME}/zephyrproject \
    VENV_PATH=/home/${USER_NAME}/zephyrproject/.venv \
    PATH=/home/${USER_NAME}/zephyrproject/.venv/bin:$PATH

USER ${USER_NAME}
WORKDIR /home/${USER_NAME}

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
      west sdk install -t xtensa-espressif_esp32_zephyr-elf && break; \
      n=$((n+1)); echo "west update retry $n..."; sleep $((5 * n)); \
    done && \
    n=0; \
    until [ $n -ge 6 ]; do \
      west sdk install -t xtensa-espressif_esp32s2_zephyr-elf && break; \
      n=$((n+1)); echo "west update retry $n..."; sleep $((5 * n)); \
    done && \
    n=0; \
    until [ $n -ge 6 ]; do \
      west sdk install -t xtensa-espressif_esp32s3_zephyr-elf && break; \
      n=$((n+1)); echo "west update retry $n..."; sleep $((5 * n)); \
    done && \
    n=0; \
    until [ $n -ge 6 ]; do \
      west blobs fetch hal_espressif && break; \
      n=$((n+1)); echo "west update retry $n..."; sleep $((5 * n)); \
    done

RUN bash -lc "echo \"PS1='(docker)zephyr-esp32:\\w\\$ '\" >> ~/.bashrc"
