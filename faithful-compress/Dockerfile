FROM haskell:9.6.7 AS base

ENV DEBIAN_FRONTEND=noninteractive \
    PATH=/opt/ghc/9.6.7/bin:/root/.cabal/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        libgmp-dev \
        pkg-config \
        python3 \
        python3-pip \
        python3-venv \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
COPY requirements-dev.txt /tmp/requirements-dev.txt
RUN python3 -m pip install --no-cache-dir -r /tmp/requirements-dev.txt

FROM base AS dev
CMD ["bash"]

FROM base AS build
COPY cabal.project ./cabal.project
COPY faithful-compress.cabal ./faithful-compress.cabal
COPY src ./src
COPY app ./app
COPY test ./test
RUN cabal update \
    && cabal install exe:faithful-compress-cli --install-method=copy --installdir=/opt/faithful/bin

FROM debian:bookworm-slim AS runtime

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        libgmp10 \
        python3 \
        python3-pip \
        zlib1g \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m pip install --no-cache-dir tiktoken
COPY --from=build /opt/faithful/bin/faithful-compress-cli /usr/local/bin/faithful-compress-cli
WORKDIR /workspace
ENTRYPOINT ["faithful-compress-cli"]
