FROM --platform=linux/amd64 debian:bookworm-slim
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    build-essential ca-certificates file flex bison gawk gettext git libncurses-dev \
    libssl-dev python3 python3-distutils python3-pyelftools rsync unzip wget xz-utils zstd \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
