FROM --platform=linux/amd64 debian:bookworm-slim
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    build-essential ca-certificates cmake file flex bison gawk gettext git libjson-c-dev \
    libncurses-dev libssl-dev pkg-config python3 python3-distutils python3-pyelftools \
    rsync unzip wget xz-utils zstd \
    && rm -rf /var/lib/apt/lists/*

# Match the host ucode revision and mirror hash from OpenWrt v25.12.5.
ARG UCODE_VERSION=2026.01.16~85922056
ARG UCODE_SHA256=8c6f586f90e704827dc8736bf3726d15989a978c6a726a52d51e33f8019403b6
RUN wget -q "https://sources.openwrt.org/ucode-${UCODE_VERSION}.tar.zst" -O /tmp/ucode.tar.zst \
    && echo "${UCODE_SHA256}  /tmp/ucode.tar.zst" | sha256sum -c - \
    && mkdir /tmp/ucode \
    && tar --zstd -xf /tmp/ucode.tar.zst -C /tmp/ucode --strip-components=1 \
    && cmake -S /tmp/ucode -B /tmp/ucode/build \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DSOVERSION=20230711 \
        -DDEBUG_SUPPORT=OFF \
        -DDIGEST_SUPPORT=OFF \
        -DFS_SUPPORT=OFF \
        -DIO_SUPPORT=OFF \
        -DLOG_SUPPORT=OFF \
        -DMATH_SUPPORT=OFF \
        -DNL80211_SUPPORT=OFF \
        -DRESOLV_SUPPORT=OFF \
        -DRTNL_SUPPORT=OFF \
        -DSOCKET_SUPPORT=OFF \
        -DSTRUCT_SUPPORT=OFF \
        -DUBUS_SUPPORT=OFF \
        -DUCI_SUPPORT=OFF \
        -DULOOP_SUPPORT=OFF \
        -DZLIB_SUPPORT=OFF \
    && cmake --build /tmp/ucode/build --parallel 2 \
    && cmake --install /tmp/ucode/build \
    && ldconfig \
    && rm -rf /tmp/ucode /tmp/ucode.tar.zst
WORKDIR /src
