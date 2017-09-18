# Rust on ESP8266

This script attempts to install the full toolchain needed to write firmware for
the ESP8266 using the [Arduino library](https://github.com/esp8266/Arduino/).
It also generates and compiles a simple skeleton firmware that blinks the
builtin LED.

**This is pre-alpha software. Contributions are welcome!**

The toolchain is:

- The standard Rust toolchain, installed using [rustup](https://www.rustup.rs)
- [bindgen](https://github.com/rust-lang-nursery/rust-bindgen) + [rustfmt](https://github.com/rust-lang-nursery/rustfmt)
- [mrustc](https://github.com/thepowersgang/mrustc) Rust -> C compiler
- [PlatformIO](http://platformio.org/) and its ESP8266 toolchain

## Usage

Clone the repository, create a project directory, and run the script. The first
time will take a while since it needs to compile `mrustc`.

```
git clone https://github.com/emosenkis/esp-rs.git
mkdir my-project
cd my-project
../esp-rs/build.sh
```


## Requirements

- Host machine: Linux platform with rustup support installing Rust nightly and
  for \[cross-\]compiling to `i686-unknown-linux-gnu` (thas only been tested on
  `x86_64` with Ubuntu 16.04).
- Software: The script will try to install all parts of the toolchain listed
  above but you probably need to have a C toolchain already installed.
- Dev board: NodeMCU v2 such as
  [these](https://www.banggood.com/Geekcreit-Doit-NodeMcu-Lua-ESP8266-ESP-12E-WIFI-Development-Board-p-985891.html)
  (adapting to other ESP8266 boards would probably be trivial)

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
