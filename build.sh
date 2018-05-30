#!/bin/bash

set -e -u -o pipefail

readonly MRUSTC_VER='b5b7089'
readonly SDK_VER='2.4.1'

readonly INSTALL_DIR="${HOME}/.esp-rs"
readonly MRUSTC_DIR="${INSTALL_DIR}/mrustc"
readonly SDK_ROOT="${INSTALL_DIR}/esp8266-arduino"
readonly TOOLCHAIN_ROOT="${HOME}/.platformio/packages/toolchain-xtensa"
readonly PROJECT_DIR="${PWD}"

function main() {
    if [[ "${1:-}" == '--install' ]]; then
        install_toolchain
        exit
    elif ! (
        rustup --version \
        && bindgen --version \
        && which rustfmt \
        && platformio --version \
        && [[ -x "${MRUSTC_DIR}/tools/bin/minicargo" ]] \
        && [[ -d "${TOOLCHAIN_ROOT}" ]] \
        ) &>/dev/null; then
            echo 'Installation does not seem to be complete. Try running with --install.'
            exit 1
    fi
    init_project
    generate_bindings
    compile_with_rustc
    compile_woth_mrustc
    compile_with_platformio
}

function install_toolchain() {
    if ! rustup --version &>/dev/null; then
        echo 'Installing rustup...'
        curl https://sh.rustup.rs -sSf | sh
    fi
    rustup target add i686-unknown-linux-gnu
    if ! bindgen --version &>/dev/null; then
        echo 'Installing bindgen...'
        rustup run nightly cargo install bindgen
    fi
    if ! which rustfmt &>/dev/null; then
        echo 'Installing rustfmt...'
        rustup run nightly cargo install rustfmt-nightly
    fi
    if ! platformio --version &>/dev/null; then
        echo 'Installing platformio...'
        pip install platformio
    fi
    if ! [[ -d "${INSTALL_DIR}" ]]; then
        mkdir "${INSTALL_DIR}"
    fi

    checkout_git_revision 'https://github.com/thepowersgang/mrustc.git' "${MRUSTC_VER}" "${MRUSTC_DIR}" 'mrustc'
    echo "Building mrustc/minicargo@${MRUSTC_VER}"
    ( cd "${MRUSTC_DIR}" && make RUSTCSRC && make -f minicargo.mk )
    checkout_git_revision 'https://github.com/esp8266/Arduino.git' "${SDK_VER}" "${SDK_ROOT}" 'ESP8266 Arduino SDK'
    if ! [[ -d "${TOOLCHAIN_ROOT}" ]]; then
        echo 'Installing PlatformIO ESP8266 Arduino SDK...'
        platformio platform install espressif8266
    fi
}

function checkout_git_revision() {
    local REPO_URL="$1"
    local COMMIT="$2"
    local TARGET_DIR="$3"
    local NAME="$4"
    if [[ -d "${TARGET_DIR}" ]]; then
        if ! ( cd "${TARGET_DIR}" && git rev-parse --verify --quiet "${COMMIT}" > /dev/null ); then
            echo "Fetching ${NAME} revision ${COMMIT}"
            ( cd "${TARGET_DIR}" && git fetch origin ) || echo "Failed to fetch ${NAME} revision ${COMMIT}."
        fi
    else
        git clone "${REPO_URL}" "${TARGET_DIR}"
    fi
    ( cd "${TARGET_DIR}" && git checkout "${COMMIT}" . )
}

function init_project() {
    if ! [[ -e platformio.ini ]]; then
        echo 'Initializing PlatformIO project...'
        platformio init -b nodemcuv2
    fi
    if ! [[ -e Cargo.toml ]]; then
        echo 'Initializing Cargo project...'
        cargo init
        echo 'bindings = { path = "bindings" }' >> Cargo.toml
    fi
    if ! [[ -e src/lib.rs ]]; then
        echo 'Generating src/lib.rs'
        cat > src/lib.rs <<EOF
#![no_std]

extern crate bindings;

use bindings::*;

#[no_mangle]
pub fn setup_rs() {
    unsafe {
        pinMode(LED_BUILTIN, OUTPUT as u8);
    }
}

#[no_mangle]
pub fn loop_rs() {
    unsafe {
        digitalWrite(LED_BUILTIN, LOW as u8);
        delay(1000);
        digitalWrite(LED_BUILTIN, HIGH as u8);
        delay(2000);
    }
}
EOF
    fi
    local crate_name="$( egrep '^name\b' Cargo.toml | head -n1 | cut -f2 -d'"' )"
    local crate_version="$( egrep '^version\b' Cargo.toml | head -n1 | cut -f2 -d'"' )"
    readonly GENERATED_C_SRC_PREFIX="lib$( echo "${crate_name}" | sed 's/-/_/g' )"
    readonly GENERATED_C_SRC="generated/${GENERATED_C_SRC_PREFIX}-$( echo "${crate_version}" | sed 's/\./_/g' ).hir.o.c"
    if ! [[ -d generated ]]; then
        mkdir generated
    fi
    if ! [[ -e "${GENERATED_C_SRC}" ]]; then
        touch "${GENERATED_C_SRC}"
    fi
    if ! [[ -d bindings ]]; then
        mkdir bindings
    fi
    if ! [[ -e bindings/Cargo.toml ]]; then
        echo 'Initializing bindings crate'
        cargo init bindings
        echo 'libc = { path = "../vendor/libc", default-features = false }' >> bindings/Cargo.toml
    fi
    if ! [[ -d vendor ]]; then
        mkdir vendor
    fi
    ln -sfn "${MRUSTC_DIR}/rustc-1.19.0-src/src/vendor/libc" vendor/libc
    if [[ -e Cargo.lock ]]; then
        cargo update -p libc
    fi
    if [[ -e src/main.ino ]]; then
        sed -i 's@^#include ".*'"${GENERATED_C_SRC_PREFIX}"'.*hir.o.c"$@#include "../'"${GENERATED_C_SRC}"'"@' src/main.ino
    else
        echo 'Generating src/main.ino'
        cat > src/main.ino <<EOF
#include "../${GENERATED_C_SRC}"
void setup() {
    setup_rs();
}

void loop() {
    loop_rs();
}
EOF
    fi
}

function generate_bindings() {
    # Find out which bindings are needed by deleting the contents of the
    # bindings crate, then running cargo to get errors for missing items.
    local whitelist_args=()
    echo > bindings/src/lib.rs
    readarray -t whitelist_args < <(
        python2 - <(cargo build --message-format=json 2>/dev/null) <<'EOF'
import json
import re
import sys

_RE = re.compile('cannot find [^ ]+ `([^`]+)` in this scope')

with open(sys.argv[1]) as input:
    for line in input:
        if not line.startswith('{'):
            continue
        data = json.loads(line)
        if 'message' not in data:
            continue
        match = _RE.match(data['message']['message'])
        if not match:
            continue
        name = match.group(1)
        print '--whitelist-type=' + name
        print '--whitelist-function=' + name
        print '--whitelist-var=' + name
EOF
    )

    # Use platformio to get compiler flags and include dirs.
    local extra_args=()
    readarray -t extra_args < <(
        python2 - <(platformio run -t idedata) <<'EOF'
import json
import sys

with open(sys.argv[1]) as input:
    for line in input:
        if line.startswith('{'):
            data = json.loads(line)
            for include in data['includes']:
                print '-I' + include
            for flag in data['cxx_flags'].split():
                if flag[:2] != '-m':
                    print flag
            break
EOF
    )

    ( cd "${SDK_ROOT}" && \
        set -x &&
        bindgen \
           --use-core \
           --ctypes-prefix libc \
           --rustfmt-bindings \
           --raw-line '#![no_std]' \
           --raw-line '#![allow(non_snake_case,non_camel_case_types,non_upper_case_globals)]' \
           --raw-line 'extern crate libc;' \
           --output "${PROJECT_DIR}/bindings/src/lib.rs" \
           "${whitelist_args[@]}" \
           <( echo '#include <Esp.h>' \
              && grep '^#include ' "${PROJECT_DIR}/src/main.ino" \
                  | grep -vF "${GENERATED_C_SRC}" ) \
           -- \
           -x c++ \
           -nostdinc \
           -m32 \
           -I"${TOOLCHAIN_ROOT}/xtensa-lx106-elf/include/c++/4.8.2" \
           -I"${TOOLCHAIN_ROOT}/xtensa-lx106-elf/include/c++/4.8.2/xtensa-lx106-elf" \
           -Itools/sdk/libc/xtensa-lx106-elf/include \
           "${extra_args[@]}" )
    # TODO: Figure out how to automatically derive the hardcoded -I flags above
}


function compile_with_rustc() {
    echo 'Building project with rustc to run checks'
    cargo build --target i686-unknown-linux-gnu
    echo 'Building docs with rustc'
    cargo doc --target i686-unknown-linux-gnu
}

function compile_woth_mrustc() {
    echo 'Transpiling project with mrustc'
    "${MRUSTC_DIR}"/tools/bin/minicargo "${PROJECT_DIR}" \
        --script-overrides "${MRUSTC_DIR}"/script-overrides/stable-1.19.0-linux/ \
        -L "${MRUSTC_DIR}"/output/ \
        --vendor-dir "${PROJECT_DIR}"/vendor/ \
        --output-dir "${PROJECT_DIR}"/generated/
    sed -i '/stdatomic/d' "${GENERATED_C_SRC}"
    sed -i '/__int128/d' "${GENERATED_C_SRC}"
    sed -ir '/uint128_t/,/^}$/d' "${GENERATED_C_SRC}"
}

function compile_with_platformio() {
    echo 'Compiling firmware'
    platformio run
}

main "$@"
