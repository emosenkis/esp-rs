#!/bin/bash

set -e -u -o pipefail

readonly INSTALL_DIR="${HOME}/.esp-rs"
readonly MRUSTC_DIR="${INSTALL_DIR}/mrustc"
readonly SDK_ROOT="${INSTALL_DIR}/esp8266-arduino"
readonly TOOLCHAIN_ROOT="${HOME}/.platformio/packages/toolchain-xtensa"
readonly PROJECT_DIR="${PWD}"

function main() {
    install_toolchain
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
    if ! rustfmt --version &>/dev/null; then
        echo 'Installing rustfmt...'
        cargo install rustfmt
    fi
    if ! platformio --version &>/dev/null; then
        echo 'Installing platformio...'
        pip install platformio
    fi
    if ! [[ -d "${INSTALL_DIR}" ]]; then
        mkdir "${INSTALL_DIR}"
    fi

    if ! [[ -d "${MRUSTC_DIR}" ]]; then
        git clone 'https://github.com/thepowersgang/mrustc' "${MRUSTC_DIR}"
    fi
    echo 'Building mrustc/minicargo'
    touch "${MRUSTC_DIR}"/script-overrides/nightly-2017-07-08/build_rustc_{a,l,m,t}san.txt
    ( cd "${MRUSTC_DIR}" && make RUSTCSRC && make -f minicargo.mk )
    echo 'Building Rust std library with mrustc'
    ( cd "${MRUSTC_DIR}/tools" && ./build_rustc_with_minicargo.sh )
    if ! [[ -d "${SDK_ROOT}" ]]; then
		git clone https://github.com/esp8266/Arduino/ "${SDK_ROOT}"
	fi
    if ! [[ -d "${TOOLCHAIN_ROOT}" ]]; then
        echo 'Installing ESP8266 Arduino SDK...'
        platformio platform install espressif8266
    fi
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
    local crate_name="$( egrep '^name\b' Cargo.toml  | cut -f2 -d'"' )"
    readonly GENERATED_C_SRC="${MRUSTC_DIR}/output/lib$( echo "${crate_name}" | sed 's/-/_/g' ).hir.o.c"
	if ! [[ -d bindings ]]; then
		mkdir bindings
	fi
	if ! [[ -e bindings/Cargo.toml ]]; then
		echo 'Initializing bindings crate'
		cargo init bindings
		echo 'libc = { path = "../libc", default-features = false }' >> bindings/Cargo.toml
    fi
	if ! [[ -d libc ]]; then
		echo 'Creating symlink to libc'
		ln -s "${MRUSTC_DIR}/rustc-nightly/src/vendor/libc" libc
	fi
    if ! [[ -e src/main.ino ]]; then
        echo 'Generating src/main.ino'
        cat > src/main.ino <<EOF
#include "${GENERATED_C_SRC}"
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
	( cd "${SDK_ROOT}" && \
		bindgen \
		   --use-core \
		   --ctypes-prefix libc \
		   --rustfmt-bindings \
		   --raw-line '#![no_std]' \
		   --raw-line '#![allow(non_snake_case,non_camel_case_types,non_upper_case_globals)]' \
		   --raw-line 'extern crate libc;' \
		   cores/esp8266/Esp.h \
		   -- \
		   -I"${TOOLCHAIN_ROOT}/lib/gcc/xtensa-lx106-elf/4.8.2/include" \
		   -Itools/sdk/libc/xtensa-lx106-elf/include \
		   -Itools/sdk/include \
		   -Ivariants/nodemcu \
		   -Icores/esp8266 \
		   -x c++ \
		   -std=c++14 \
		   -nostdinc \
           -m32 \
		   > "${PROJECT_DIR}/bindings/src/lib.rs" )
}


function compile_with_rustc() {
    echo 'Building project with rustc to run checks'
    cargo build --target i686-unknown-linux-gnu
    echo 'Building docs with rustc'
    cargo doc --target i686-unknown-linux-gnu
}

function compile_woth_mrustc() {
    echo 'Transpiling project with mrustc'
    ( cd "${MRUSTC_DIR}" && \
		tools/bin/minicargo "${PROJECT_DIR}" \
	        --script-overrides script-overrides/nightly-2017-07-08/ \
    	    --vendor-dir tools/output/ )
    sed -i '/stdatomic/d' "${GENERATED_C_SRC}"
    sed -i '/__int128/d' "${GENERATED_C_SRC}"
	sed -ir '/uint128_t/,/^}$/d' "${GENERATED_C_SRC}"
}

function compile_with_platformio() {
    echo 'Compiling firmware'
    platformio run
}

main
