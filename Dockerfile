ARG TARGETARCH

FROM --platform=linux/amd64 debian:bookworm AS cross-builder-base
ARG CPCD_VERSION
ARG GECKO_SDK_VERSION

ENV \
    LANG="C.UTF-8" \
    DEBIAN_FRONTEND="noninteractive" \
    CURL_CA_BUNDLE="/etc/ssl/certs/ca-certificates.crt"

WORKDIR /usr/src

# Allow to reuse downloaded packages (these are only staged build images)
# hadolint ignore=DL3009
RUN \
    set -x \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
       bash \
       curl \
       ca-certificates \
       build-essential \
       git \
	   git-lfs \
	   unzip \
	   openjdk-17-jre
	   
RUN \
    set -x \
    && curl -O https://www.silabs.com/documents/login/software/slc_cli_linux.zip \
    && unzip slc_cli_linux.zip \
    && cd slc_cli/ && chmod +x slc
	
RUN  \
    set -x \
	&& git clone --depth 1 -b "${CPCD_VERSION}" \
       https://github.com/SiliconLabs/cpc-daemon.git
	   
RUN \
    set -x \
    && git clone --depth 1 -b ${GECKO_SDK_VERSION} \
       https://github.com/SiliconLabs/gecko_sdk.git
	   
FROM --platform=linux/amd64 cross-builder-base AS cross-builder-amd64

COPY debian-amd64.cmake /usr/src/debian.cmake

ENV DEBIAN_ARCH=amd64
ENV DEBIAN_CROSS_PREFIX=x86_64-linux-gnu
ENV SLC_ARCH=zigbee_x86_64

RUN \
    set -x \
    && dpkg --add-architecture amd64 \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
       crossbuild-essential-amd64
	   
FROM --platform=linux/amd64 cross-builder-base AS cross-builder-arm64

COPY debian-arm64.cmake /usr/src/debian.cmake

ENV DEBIAN_ARCH=arm64
ENV DEBIAN_CROSS_PREFIX=aarch64-linux-gnu
ENV SLC_ARCH=linux_arch_64

RUN \
    set -x \
    && dpkg --add-architecture arm64 \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
       crossbuild-essential-arm64
	   
FROM --platform=linux/amd64 cross-builder-${TARGETARCH} AS cpcd-builder

ARG CPCD_VERSION

RUN \
    set -x \
    && apt-get install -y --no-install-recommends \
       cmake \
       "libmbedtls-dev:${DEBIAN_ARCH}" \
       "libmbedtls14:${DEBIAN_ARCH}" \
    && mkdir cpc-daemon/build && cd cpc-daemon/build \
    && cmake ../ \
       -DCMAKE_TOOLCHAIN_FILE=../debian.cmake \
       -DENABLE_ENCRYPTION=FALSE \
    && make \
    && make install

FROM --platform=linux/amd64 cross-builder-${TARGETARCH} AS zigbeed-builder

ARG GECKO_SDK_VERSION

ENV PATH="/usr/src/slc_cli/:$PATH"



# zigbeed links against libcpc.so
COPY --from=cpcd-builder /usr/local/ /usr/${DEBIAN_CROSS_PREFIX}/

RUN \
    set -x \
    && cd gecko_sdk \
    && GECKO_SDK=$(pwd) \
    && slc signature trust --sdk=${GECKO_SDK} \
    && cd protocol/zigbee \
    && slc generate \
       --sdk=${GECKO_SDK} \
       --with="${SLC_ARCH}" \
       --project-file=$(pwd)/app/zigbeed/zigbeed.slcp \
       --export-destination=$(pwd)/app/zigbeed/output \
       --copy-proj-sources \
    && cd app/zigbeed/output \
    && make -j -f zigbeed.Makefile \
        AR="${DEBIAN_CROSS_PREFIX}-ar" \
        CC="${DEBIAN_CROSS_PREFIX}-gcc" \
        LD="${DEBIAN_CROSS_PREFIX}-gcc" \
        CXX="${DEBIAN_CROSS_PREFIX}-g++" \
        C_FLAGS="-std=gnu99 -DEMBER_MULTICAST_TABLE_SIZE=16" \
        debug


FROM --platform=$TARGETPLATFORM debian:bookworm

WORKDIR /

ENV \
    LANG="C.UTF-8" \
    DEBIAN_FRONTEND="noninteractive" \
    CURL_CA_BUNDLE="/etc/ssl/certs/ca-certificates.crt"

RUN \
    set -x \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
	   systemd \
	   systemd-sysv \
	   libmbedtls14 \
	   socat
	   
RUN \
	set -x \
	&& apt-get install -y --no-install-recommends \
       iproute2 \
       patch \
       lsb-release \
       netcat-traditional \
       sudo \
	   cmake

COPY --from=zigbeed-builder \
     /usr/src/gecko_sdk/util/third_party/ot-br-posix /usr/src/ot-br-posix
COPY --from=zigbeed-builder \
     /usr/src/gecko_sdk/util/third_party/openthread /usr/src/openthread
COPY --from=zigbeed-builder \
     /usr/src/gecko_sdk/protocol/openthread/platform-abstraction/posix/ /usr/src/silabs-vendor-interface
COPY --from=cpcd-builder /usr/local/ /usr/local/

COPY otbr-patches/0001-Avoid-writing-to-system-console.patch /usr/src
COPY otbr-patches/0001-rest-support-erasing-all-persistent-info-1908.patch /usr/src
COPY otbr-patches/0002-rest-support-deleting-the-dataset.patch /usr/src
COPY otbr-patches/0003-mdns-update-mDNSResponder-to-1790.80.10.patch /usr/src
COPY otbr-patches/0004-mdns-add-Linux-specific-patches.patch /usr/src

# Build OTBR natively from Gecko SDK sources
WORKDIR /usr/src/ot-br-posix

RUN \
	set +x \
    && patch -p1 < /usr/src/0001-Avoid-writing-to-system-console.patch \
    && patch -p1 < /usr/src/0001-rest-support-erasing-all-persistent-info-1908.patch \
    && patch -p1 < /usr/src/0002-rest-support-deleting-the-dataset.patch \
    && patch -p1 < /usr/src/0003-mdns-update-mDNSResponder-to-1790.80.10.patch \
    && patch -p1 < /usr/src/0004-mdns-add-Linux-specific-patches.patch \
    && ln -s ../../../openthread/ third_party/openthread/repo \
    && (cd third_party/openthread/repo \
        && ln -s ../../../../silabs-vendor-interface/openthread-core-silabs-posix-config.h src/posix/platform/openthread-core-silabs-posix-config.h) \
    && chmod +x ./script/* \
    && ./script/bootstrap \
    # Mimic rt_tables_install \
    && echo "88 openthread" >> /etc/iproute2/rt_tables
	

# Mimic otbr_install
RUN \
	set +x \
    && (./script/cmake-build \
        -DBUILD_TESTING=OFF \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DCMAKE_MODULE_PATH=/usr/src/silabs-vendor-interface/ \
        -DOTBR_FEATURE_FLAGS=ON \
        -DOTBR_DNSSD_DISCOVERY_PROXY=ON \
        -DOTBR_SRP_ADVERTISING_PROXY=ON \
        -DOTBR_INFRA_IF_NAME=eth0 \
		-DOTBR_RADIO_URL="spinel+cpc://cpcd_0?iid=2&iid-list=0" \
        -DOTBR_MDNS=mDNSResponder \
        -DOTBR_VERSION= \
        -DOT_PACKAGE_VERSION= \
        -DOTBR_DBUS=OFF \
        -DOT_MULTIPAN_RCP=ON \
        -DOT_POSIX_CONFIG_RCP_BUS=VENDOR \
        -DOT_POSIX_CONFIG_RCP_VENDOR_DEPS_PACKAGE=SilabsRcpDeps \
        -DOT_POSIX_CONFIG_RCP_VENDOR_INTERFACE=/usr/src/silabs-vendor-interface/cpc_interface.cpp \
        -DOT_CONFIG="openthread-core-silabs-posix-config.h" \
        -DOT_LINK_RAW=1 \
        -DOTBR_VENDOR_NAME="ISIOT" \
        -DOTBR_PRODUCT_NAME="Silicon Labs Multiprotocol" \
        -DOTBR_WEB=OFF \
        -DOTBR_BORDER_ROUTING=ON \
        -DOTBR_REST=ON \
        -DOTBR_BACKBONE_ROUTER=ON \
        && cd build/otbr/ \
        && ninja \
        && ninja install)
		
COPY --from=zigbeed-builder \
     /usr/src/gecko_sdk/protocol/zigbee/app/zigbeed/output/build/debug/zigbeed \
     /usr/local/bin
	 

RUN set +x \
	&& export SUDO_FORCE_REMOVE=yes \
	&& apt-get remove -y build-essential patch cmake sudo \
	&& apt -y autoremove \
    && rm -rf /var/lib/apt/lists/* \
    && rm -rf /usr/src/*
	
COPY rootfs /

RUN ldconfig && touch /accept_silabs_msla

WORKDIR /root

VOLUME [ "/sys/fs/cgroup" ]

CMD ["/lib/systemd/systemd"]







