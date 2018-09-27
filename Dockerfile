FROM ubuntu:16.04

RUN apt-get update && apt-get install -y git curl gcc libssl-dev pkg-config python-pip cmake
RUN curl https://sh.rustup.rs -sSf > rustup.sh && chmod +x rustup.sh
RUN ./rustup.sh -y
ENV PATH="/root/.cargo/bin:${PATH}"

WORKDIR /build

RUN git clone https://github.com/emosenkis/esp-rs

WORKDIR /build/esp-rs

RUN ./build.sh --install
