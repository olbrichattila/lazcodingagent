#!/usr/bin/env bash
# Shared Lazarus/FPC target and widgetset discovery for the Bash test runners.

TEST_HOST_OS="$(uname -s)"
UNIT_PLATFORM="$(fpc -iTP)-$(fpc -iTO)"

if [ -z "${LAZARUS_DIR:-}" ]; then
    case "${TEST_HOST_OS}" in
        Darwin)
            for candidate in \
                /Applications/Lazarus.app/Contents/Resources \
                /usr/local/share/lazarus \
                /opt/homebrew/share/lazarus; do
                if [ -d "${candidate}/components/lazutils" ]; then
                    LAZARUS_DIR="${candidate}"
                    break
                fi
            done
            ;;
        Linux)
            for candidate in /usr/lib/lazarus/default /usr/lib/lazarus/4.4; do
                if [ -d "${candidate}" ]; then
                    LAZARUS_DIR="${candidate}"
                    break
                fi
            done
            ;;
    esac
fi

if [ -z "${LAZARUS_DIR:-}" ] || [ ! -d "${LAZARUS_DIR}" ]; then
    echo "Error: Set LAZARUS_DIR to the Lazarus source/install directory." >&2
    exit 1
fi

if [ -z "${LCL_WS:-}" ]; then
    case "${TEST_HOST_OS}" in
        Darwin) LCL_WS=cocoa ;;
        Linux) LCL_WS=qt5 ;;
        *) echo "Error: Bash GUI test runners support macOS and Linux; use the .bat runners on Windows." >&2; exit 1 ;;
    esac
fi

export LAZARUS_DIR LCL_WS UNIT_PLATFORM TEST_HOST_OS
