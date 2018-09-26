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
    if ! rustup toolchain list | grep -q nightly; then
        echo 'Installing nightly toolchain...'
        rustup toolchain install nightly
    fi
    if ! bindgen --version &>/dev/null; then
        echo 'Installing bindgen...'
        cargo +nightly install bindgen
    fi
    if ! which rustfmt &>/dev/null; then
        echo 'Installing rustfmt...'
        rustup component add rustfmt-preview
    fi
    if ! which cargo-vendor &>/dev/null; then
        echo 'Installing cargo-vendor...'
        cargo install cargo-vendor
    fi
    if ! platformio --version &>/dev/null; then
        echo 'Installing platformio...'
        pip install platformio --user
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
    if ! [[ -e .esp-rs-compiled-lib ]]; then
        ln -s .pioenvs/nodemcuv2/libc72 .esp-rs-compiled-lib
    fi
    if ! grep -q libgenerated platformio.ini; then
        echo "build_flags = '-L.esp-rs-compiled-lib -llibgenerated'" >> platformio.ini
    fi
    if ! [[ -e Cargo.toml ]]; then
        echo 'Initializing Cargo project...'
        cargo init
        echo 'embedded-hal = { version = "0.2.1", features = ["unproven"] }' >> Cargo.toml
        echo 'esp8266-hal = "0.0.1"' >> Cargo.toml
        echo 'libc = { version = "0.2.22", default-features = false }' >> Cargo.toml
    fi
    if ! grep -qs no_std src/lib.rs ; then
        echo 'Generating src/lib.rs'
        cat > src/lib.rs <<EOF
#![no_std]

extern crate embedded_hal;
extern crate esp8266_hal;
extern crate libc;

mod bindings;
use bindings::*;
use embedded_hal::prelude::*;

pub struct State {
    led: esp8266_hal::OutputPin,
}

#[no_mangle]
pub fn setup_rs() -> State {
    State {
        led: esp8266_hal::OutputPin::new(LED_BUILTIN as u8),
    }
}

#[no_mangle]
pub fn loop_rs(state: &mut State) {
    state.led.set_low();
    delay_rs(500);
    state.led.set_high();
    delay_rs(500);
}

fn delay_rs(millis: libc::c_ulong) {
    unsafe {
        delay(millis);
    }
}
EOF
    fi
    local crate_name="$( egrep '^name\b' Cargo.toml | head -n1 | cut -f2 -d'"' )"
    local crate_version="$( egrep '^version\b' Cargo.toml | head -n1 | cut -f2 -d'"' )"
    readonly GENERATED_C_SRC_PREFIX="lib$( echo "${crate_name}" | sed 's/-/_/g' )"
    readonly GENERATED_HIR="lib/generated/${GENERATED_C_SRC_PREFIX}-$( echo "${crate_version}" | sed 's/\./_/g' ).hir"
    readonly GENERATED_C_SRC="${GENERATED_HIR}.o.c"
    if ! [[ -d lib/generated ]]; then
        mkdir -p lib/generated
    fi
    if ! [[ -e lib/generated/generated.h ]]; then
        touch lib/generated/generated.h
    fi
    if ! [[ -e "${GENERATED_C_SRC}" ]]; then
        touch "${GENERATED_C_SRC}"
    fi
    cargo vendor
    if ! [[ -d .cargo ]]; then
        mkdir -p .cargo
    fi
    if ! [[ -e .cargo/config ]]; then
        cat > .cargo/config <<EOF
[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "vendor"
EOF
    fi
    if [[ -e src/main.ino ]]; then
        sed -i 's@^#include ".*'"${GENERATED_C_SRC_PREFIX}"'.*hir.o.c"$@#include "../'"${GENERATED_C_SRC}"'"@' src/main.ino
    else
        echo 'Generating src/main.ino'
        cat > src/main.ino <<EOF
// Include an empty header to make platformio compile the generated code
#include <generated.h>
extern "C" {
    #include "../${GENERATED_C_SRC}"
}

decltype(setup_rs()) main;

void setup() {
    main = setup_rs();
}

void loop() {
    loop_rs(&main);
}
EOF
    fi
}

function generate_bindings() {
    # Find out which bindings are needed by deleting the contents of the
    # bindings crate, then running cargo to get errors for missing items.
    local whitelist_args=()
    echo > src/bindings.rs
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
           --raw-line '#![allow(non_snake_case,non_camel_case_types,non_upper_case_globals)]' \
           --raw-line 'extern crate libc;' \
           --output "${PROJECT_DIR}/src/bindings.rs" \
           "${whitelist_args[@]}" \
           <( echo '#include <Esp.h>' \
              && grep '^#include ' "${PROJECT_DIR}/src/main.ino" \
                  | grep -ve '"generated/.*\.hir.o.c"' ) \
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
    echo 'Running cargo check'
    cargo check --target i686-unknown-linux-gnu
}

function compile_woth_mrustc() {
    echo 'Transpiling project with mrustc'
    # Delete the previous generated files to ensure mrustc builds them again.
    rm -f lib/generated/*.hir*
    "${MRUSTC_DIR}"/tools/bin/minicargo "${PROJECT_DIR}" \
        --script-overrides "${MRUSTC_DIR}"/script-overrides/stable-1.19.0-linux/ \
        -L "${MRUSTC_DIR}"/output/ \
        --vendor-dir "${PROJECT_DIR}"/vendor/ \
        --output-dir "${PROJECT_DIR}"/lib/generated/
    sed -i '/stdatomic/d' lib/generated/*.hir.o.c
    sed -i '/__int128/d' lib/generated/*.hir.o.c
    sed -ir '/uint128_t/,/^}$/d' lib/generated/*.hir.o.c
}

function compile_with_platformio() {
    echo 'Compiling firmware'
    platformio run
}

main "$@"
