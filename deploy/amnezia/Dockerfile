# Клиент AmneziaWG (userspace, без модуля ядра) + HTTP-прокси tinyproxy.
# Весь исходящий трафик контейнера идёт через туннель, бот ходит в Telegram через этот прокси.

FROM golang:1.25-bookworm AS build
# Фиксированные теги (AmneziaWG 3.1), чтобы сборка была воспроизводимой. Обновлять осознанно.
ARG AWG_GO_REF=v3.1.20260828
ARG AWG_TOOLS_REF=v3.1.20260812
ENV GOTOOLCHAIN=auto CGO_ENABLED=0
RUN git clone --depth 1 --branch "$AWG_GO_REF" https://github.com/amnezia-vpn/amneziawg-go /src/awg-go \
 && cd /src/awg-go && go build -trimpath -ldflags "-s -w" -o /out/usr/bin/amneziawg-go .
RUN git clone --depth 1 --branch "$AWG_TOOLS_REF" https://github.com/amnezia-vpn/amneziawg-tools /src/awg-tools \
 && make -C /src/awg-tools/src -j"$(nproc)" \
 && make -C /src/awg-tools/src install DESTDIR=/out WITH_WGQUICK=yes WITH_BASHCOMPLETION=no WITH_SYSTEMDUNITS=no \
 && rm -rf /out/usr/share
COPY patch-awg-quick.sh /tmp/
RUN sed -i 's/\r$//' /tmp/patch-awg-quick.sh && bash /tmp/patch-awg-quick.sh /out/usr/bin/awg-quick

FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends bash iproute2 iptables procps tinyproxy curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /out/ /
COPY tinyproxy.conf /etc/tinyproxy/tinyproxy.conf
COPY entrypoint.sh /entrypoint.sh
# на случай, если файлы прошли через Windows и получили CRLF
RUN sed -i 's/\r$//' /entrypoint.sh /etc/tinyproxy/tinyproxy.conf && chmod +x /entrypoint.sh

ENV WG_QUICK_USERSPACE_IMPLEMENTATION=amneziawg-go \
    AWG_CONFIG=/config/awg0.conf \
    AWG_KEEP_IPV6=0 \
    CHECK_URL=https://api.telegram.org

HEALTHCHECK --interval=60s --timeout=15s --start-period=30s --retries=3 \
    CMD curl -s -o /dev/null -m 10 "$CHECK_URL" || exit 1

EXPOSE 8888
ENTRYPOINT ["/entrypoint.sh"]
