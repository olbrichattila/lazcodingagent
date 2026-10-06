#!/usr/bin/env bash
# ==============================================================================
# Lazarus Coding Agent - Build Script
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${SCRIPT_DIR}/app"
PKG_DIR="${SCRIPT_DIR}/package"
BIN_DIR="${APP_DIR}/bin"

# Detect Lazarus directory
LAZARUS_DIR="${LAZARUS_DIR:-}"
if [ -z "${LAZARUS_DIR}" ]; then
    if [ "$(uname -s)" = "Darwin" ]; then
        for candidate in /Applications/Lazarus.app/Contents/Resources /usr/local/share/lazarus /opt/homebrew/share/lazarus; do
            if [ -d "${candidate}" ]; then
                LAZARUS_DIR="${candidate}"
                break
            fi
        done
    elif [ -d "/usr/lib/lazarus/4.4" ]; then
        LAZARUS_DIR="/usr/lib/lazarus/4.4"
    elif [ -d "/usr/lib/lazarus/default" ]; then
        LAZARUS_DIR="/usr/lib/lazarus/default"
    fi
fi

# Detect LCL Widgetset
LCL_WS="${LCL_WS:-}"
if [ -z "${LCL_WS}" ]; then
    if [ "$(uname -s)" = "Darwin" ]; then
        LCL_WS="cocoa"
    elif command -v dpkg >/dev/null 2>&1 && dpkg -l 2>/dev/null | grep -q "lazarus-ide-qt5"; then
        LCL_WS="qt5"
    elif command -v dpkg >/dev/null 2>&1 && dpkg -l 2>/dev/null | grep -q "libgtk2.0-dev"; then
        LCL_WS="gtk2"
    elif command -v dpkg >/dev/null 2>&1 && dpkg -l 2>/dev/null | grep -q "libqt5pas-dev"; then
        LCL_WS="qt5"
    else
        LCL_WS="qt5"
    fi
fi

LAZBUILD_FLAGS=()
if [ -n "${LAZARUS_DIR}" ]; then
    LAZBUILD_FLAGS+=( "--lazarusdir=${LAZARUS_DIR}" )
fi
if [ -n "${LCL_WS}" ]; then
    LAZBUILD_FLAGS+=( "--ws=${LCL_WS}" )
fi

# Check for required tools
command -v lazbuild >/dev/null 2>&1 || {
    echo "Error: 'lazbuild' not found in PATH. Please install Lazarus IDE / lazbuild." >&2
    exit 1
}

command -v fpc >/dev/null 2>&1 || {
    echo "Error: 'fpc' not found in PATH. Please install Free Pascal Compiler." >&2
    exit 1
}

usage() {
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  app         Build the standalone chat application (default)"
    echo "  package     Compile the Lazarus IDE package (.lpk)"
    echo "  install     Register package and rebuild Lazarus IDE"
    echo "  all         Build both the standalone app and compile the package"
    echo "  clean       Remove compilation artifacts and binaries"
    echo "  help        Display this help message"
    echo ""
}

build_app() {
    echo "==> Building Standalone Chat Application..."
    mkdir -p "${BIN_DIR}"
    if [ -f "${APP_DIR}/standalone_chat.lpi" ]; then
        lazbuild "${LAZBUILD_FLAGS[@]}" --build-mode=Default "${APP_DIR}/standalone_chat.lpi"
        echo "==> Standalone app built successfully at: ${BIN_DIR}/standalone_chat"
    else
        echo "Error: ${APP_DIR}/standalone_chat.lpi not found."
        exit 1
    fi
}

build_package() {
    echo "==> Compiling Lazarus IDE Package..."
    if [ -f "${PKG_DIR}/lazaruscodingagent.lpk" ]; then
        lazbuild "${LAZBUILD_FLAGS[@]}" "${PKG_DIR}/lazaruscodingagent.lpk"
        echo "==> Package compiled successfully."
    else
        echo "Error: ${PKG_DIR}/lazaruscodingagent.lpk not found."
        exit 1
    fi
}

install_package() {
    echo "==> Registering package and rebuilding Lazarus IDE..."
    if [ -f "${PKG_DIR}/lazaruscodingagent.lpk" ]; then
        lazbuild "${LAZBUILD_FLAGS[@]}" --add-package "${PKG_DIR}/lazaruscodingagent.lpk"
        lazbuild "${LAZBUILD_FLAGS[@]}" --build-ide=
        echo "==> Package registered and Lazarus IDE rebuilt successfully."
    else
        echo "Error: ${PKG_DIR}/lazaruscodingagent.lpk not found."
        exit 1
    fi
}

clean() {
    echo "==> Cleaning build artifacts..."
    find "${SCRIPT_DIR}" -type f \( -name "*.o" -o -name "*.ppu" -o -name "*.a" -o -name "*.compiled" -o -name "*.or" -o -name "*.res" -o -name "*.rsj" \) -delete
    rm -rf "${BIN_DIR}" "${APP_DIR}/lib" "${PKG_DIR}/lib"
    echo "==> Clean complete."
}

ACTION="${1:-app}"

case "${ACTION}" in
    app)
        build_app
        ;;
    package)
        build_package
        ;;
    install)
        install_package
        ;;
    all)
        build_package
        build_app
        ;;
    clean)
        clean
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        echo "Error: Unknown command '${ACTION}'"
        usage
        exit 1
        ;;
esac
