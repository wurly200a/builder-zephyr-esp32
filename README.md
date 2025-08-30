# builder-zephyr-esp32

Zephyr Builder for esp32 series

## Build

```
docker build --target zephyr-esp32 -t ghcr.io/wurly200a/builder-zephyr-esp32/zephyr-esp32:latest .
```

## Run

### Without the device

```
docker run --rm -it -v ${PWD}:/home/builder/work -w /home/builder/zephyrproject ghcr.io/wurly200a/builder-zephyr-esp32/zephyr-esp32:latest
```

### With the device

```
DEV=/dev/ttyUSB0;docker run --rm -it --device=${DEV} --group-add $(stat -c '%g' ${DEV}) -v ${PWD}:/home/builder/work -w /home/builder/zephyrproject ghcr.io/wurly200a/builder-zephyr-esp32/zephyr-esp32:latest
```
