# Rust on ESP8266

This script attempts to install the full toolchain needed to write firmware for
the ESP8266 using the [Arduino library](https://github.com/esp8266/Arduino/).
It also generates and compiles a simple skeleton firmware that blinks the
builtin LED.

**This project is currently in alpha. Effort will be made to maintain backwards
compatibility but there are not yet any guarantees.**

The toolchain is:

- The standard Rust toolchain, installed using [rustup](https://www.rustup.rs)
- [bindgen](https://github.com/rust-lang-nursery/rust-bindgen) +
  [rustfmt](https://github.com/rust-lang-nursery/rustfmt)
- [mrustc](https://github.com/thepowersgang/mrustc) Rust -> C compiler
- [PlatformIO](http://platformio.org/) and the ESP8266 toolchain that it
  installs

## Blink

```rust
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
```

## Installation

This will take a while since it needs to compile `mrustc`.

```
git clone https://github.com/emosenkis/esp-rs.git
esp-rs/build.sh --install
```

## Updating

This may take a while also if `mrustc` needs to be recompiled. If, for some
reason, updating to the latest version fails, you can delete the `~/.esp-rs`
directory and try again for a clean install.

```
cd ~/esp-rs
git pull
./build.sh --install
```

## Usage

Create a project directory, and run the script. When run for the first time in
a directory, it will generate a skeleton project.

```
mkdir my-project
cd my-project
/where/you/cloned/esp-rs/build.sh
```

## News

Subscribe to the [forum
thread](https://users.rust-lang.org/t/rust-on-esp8266/12933) for updates.

- **14 June 2018**\
  Added default dependency on new
  [`embedded-hal`](https://github.com/japaric/embedded-hal) implementation crate
  [`esp8266-hal`](https://github.com/emosenkis/esp8266-hal) (feel free to
  both from your `Cargo.toml` if you don't want to use them).

  Changed signature of `setup_rs` and `loop_rs` functions to facilitate
  maintaining state. Now `setup_rs` returns a `State` struct and `loop_rs`
  receives a `&mut State`.

  Moved generated bindings from a separate crate to a module. Included `cargo
  vendor` as part of the script. Switched to using libc from crates.io instead
  of from mrustc.

  Fixed handling of Rust dependencies. This has been tested to work on
  PlatformIO 3.6.0a1 - try updating PlatformIO or fixing the
  `.esp-rs-compiled-lib` symlink in your project dir if you get linker errors.

  **This version makes backwards-incompatible changes to the project's layout
  and code structure. It's probably worth starting in a new directory and
  letting the script initialize it, then copy over your code.**

- **30 May 2018**\
  Added support for Rust dependencies in the `vendor` subdirectory (see
  [`cargo-vendor`](https://github.com/alexcrichton/cargo-vendor)

- **27 May 2018**\
  Updated to Arduino SDK v2.4.1 and mrustc @b5b7089. You may need to delete
  your `~/.esp-rs/mrustc` dir and try again if `./build.sh --install` fails.

- **23 November 2017**\
  The biggest improvement in this version is placing the generated C files
  inside the project dir instead of in the mrustc installation dir. mrustc is
  also updated to the latest version and the ESP8266 Arduino SDK is pinned to a
  specific commit. The `--install` flag is added to avoid running the
  installation steps every time.

- **10 October 2017**\
  Over the last past few days, the script has been greatly improved. Generating
  bindings should work for all Arduino/ESP SDK libraries as well as
  dependencies listed in `platformio.ini`. Whitelisting is used for bindgen to
  avoid bloat and unnecessary failures. Documentation has been greatly
  expanded.

## Using C/C++ libraries

The bindgen tool is used to automatically generate Rust bindings into the
generated `bindings` crate for any Arduino/ESP SDK libraries you use, as well
as dependencies listed in your `platformio.ini`. You can look at the generated
Rust code directly in `bindings/src/lib.rs` or at the generated docs in
`target/i686-unknown-linux-gnu/doc/bindings/index.html`. Note that bindgen is
still a work in progress and it currently does not support some C/C++ features
and, for reasons that are not yet clear (see #1), it does not generate some
bindings that seem like they should be present.

To avoid unnecessary bindgen failures and reduce the generated code, bindings
are only generated for C types/functions/values that are referenced in your
Rust code.  The whitelist is derived from error messages output by `cargo
build` when the bindings crate is empty. Note that sometimes (such as enums) a
generated binding may be in a different namespace than its C counterpart (such
as enum values). The Rust compiler is typically able to suggest the proper
`use` statement to add in such cases.


## Using Rust libraries

mrustc's minicargo does not currently support fetching dependencies from
crates.io or GitHub so libraries included in your `Cargo.toml` will
automatically be downloaded to the `vendor` subdirectory of your project
directory by [`cargo-vendor`](https://github.com/alexcrichton/cargo-vendor).
Cargo and minicargo will both be configured to look for dependencies there.

## Requirements

- Host machine: Linux platform with rustup support installing Rust nightly and
  for \[cross-\]compiling to `i686-unknown-linux-gnu` (thas only been tested on
  `x86_64` with Ubuntu 16.04).
- Software: The script will try to install all parts of the toolchain listed
  above but you probably need to have a C toolchain already installed (see #6).
  You may need to update PlatformIO to >=3.6.0a1.
- Dev board: The generated platformio project sets the board to to `nodemcuv2`.
  It has only been tested on
  [these](https://www.banggood.com/Geekcreit-Doit-NodeMcu-Lua-ESP8266-ESP-12E-WIFI-Development-Board-p-985891.html)
  but adapting it to other ESP8266 boards would probably be trivial.

## Contributing

Pull requests are welcome! See the open issues for ideas or just try building
an interesting firmware and fix whatever doesn't work or could be better along
the way. Please try to maintain the existing coding style and code defensively.

## Caveats

You will probably have to read error messages to figure out which dependencies
need to be installed manually, or worse, why `mrustc` won't compile. Detection
of which parts of the toolchain have been installed is imperfect and you may
have to delete a seemingly unrelated file in order to get the script to
continue from a failed installation. This has not been tested with anything
more complex than blinking the built-in LED.

## Debugging

You're mostly on your own, but if things get really broken, delete
`$HOME/.esp-rs` to get a clean start.
