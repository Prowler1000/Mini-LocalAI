ARG BUILD_DISTRO=ubuntu
ARG FINAL_DISTRO=alpine
ARG UBUNTU_TAG=20.04
ARG ALPINE_TAG=latest
ARG APP_DIR=app
ARG LOCALAI_VERSION=v2.12.4

ARG GRPC_BACKENDS=backend-assets/grpc/llama-cpp
ARG GRPC_VERSION=v1.58.0
ARG HEALTHCHECK_ENDPOINT=http://localhost:8080/readyz

############################################
############################################

FROM ubuntu:${UBUNTU_TAG} AS base-ubuntu
ARG UBUNTU_TAG
RUN echo "Using ubuntu:$UBUNTU_TAG as base image."
ENV DEBIAN_FRONTEND=noninteractive

FROM alpine:${ALPINE_TAG} AS base-alpine
ARG ALPINE_TAG
RUN echo "Using alpine:$ALPINE_TAG as base image."
RUN apk add gcompat bash

FROM base-ubuntu AS builder-ubuntu
RUN apt-get update && apt-get install -y \
    git \
    build-essential \
    cmake \
    curl \
    unzip
# Copied from later image
RUN apt-get install -y \
        ca-certificates \
        python3-pip \
        unzip \
        #libopenblas-dev \
        libopencv-dev \
    && \
    apt-get clean
RUN pip install --user grpcio-tools

FROM base-alpine AS builder-alpine
RUN apk update && apk add \
    git \
    build-base \
    cmake \
    curl \
    unzip \
    linux-headers
# Copied from later image
RUN apk add \
        ca-certificates \
        py3-pip \
        unzip \
        opencv-dev
# Install grpcio-tools (the version in 22.04 is too old)
RUN apk add py3-grpcio

FROM builder-${BUILD_DISTRO} AS builder
ARG BUILD_DISTRO
RUN echo "Building on $BUILD_DISTRO"

############################################
############################################

FROM builder AS localai-source
ARG LOCALAI_VERSION
WORKDIR /
RUN git clone --branch $LOCALAI_VERSION https://github.com/mudler/LocalAI /build

############################################
############################################

FROM builder AS grpc

ARG MAKEFLAGS
ARG GRPC_VERSION

WORKDIR /build
RUN git clone --recurse-submodules --jobs 4 -b ${GRPC_VERSION} --depth 1 --shallow-submodules https://github.com/grpc/grpc

WORKDIR /build/grpc
RUN mkdir -p cmake/build
WORKDIR /build/grpc/cmake/build
RUN cmake -DCMAKE_INSTALL_PREFIX=/build/grpc/output -DgRPC_INSTALL=ON -DgRPC_BUILD_TESTS=OFF ../..
RUN make
RUN make install

############################################
############################################

FROM builder AS requirements-core

USER root

ARG GO_VERSION=1.21.7
ARG BUILD_TYPE
ARG CUDA_MAJOR_VERSION=11
ARG CUDA_MINOR_VERSION=7
ARG TARGETARCH
ARG TARGETVARIANT

ENV BUILD_TYPE=${BUILD_TYPE}
ENV EXTERNAL_GRPC_BACKENDS=

ARG GO_TAGS=""

# Install Go
RUN curl -L -s https://go.dev/dl/go$GO_VERSION.linux-$TARGETARCH.tar.gz | tar -C /usr/local -xz
ENV PATH $PATH:/usr/local/go/bin

# Install grpc compilers
ENV PATH $PATH:/root/go/bin
RUN go install google.golang.org/protobuf/cmd/protoc-gen-go@latest && \
    go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest

# Install protobuf (the version in 22.04 is too old)
RUN curl -L -s https://github.com/protocolbuffers/protobuf/releases/download/v26.1/protoc-26.1-linux-x86_64.zip -o protoc.zip && \
    unzip -j -d /usr/local/bin protoc.zip bin/protoc && \
    rm protoc.zip

# Set up OpenCV
RUN ln -s /usr/include/opencv4/opencv2 /usr/include/opencv2

COPY --from=localai-source --chmod=644 /build/custom-ca-certs/* /usr/local/share/ca-certificates/
RUN update-ca-certificates

RUN echo "Target Architecture: $TARGETARCH"
RUN echo "Target Variant: $TARGETVARIANT"

############################################
############################################

FROM requirements-core AS localai-builder
ARG GO_TAGS=""
ARG GRPC_BACKENDS
ARG MAKEFLAGS

COPY --from=localai-source /build /build
COPY root/Makefile /build/Makefile

ENV GRPC_BACKENDS=${GRPC_BACKENDS}
ENV GO_TAGS=${GO_TAGS}
ENV MAKEFLAGS=${MAKEFLAGS}
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility
ENV NVIDIA_REQUIRE_CUDA="cuda>=${CUDA_MAJOR_VERSION}.0"
ENV NVIDIA_VISIBLE_DEVICES=all

WORKDIR /build
RUN echo "GRPC_BACKENDS ${GRPC_BACKENDS}"
RUN make prepare

COPY --from=grpc /build/grpc/output /usr/local
ENV PATH=/usr/local/bin:$PATH
RUN make build

FROM base-${FINAL_DISTRO} AS final
ARG HEALTHCHECK_ENDPOINT
ARG APP_DIR

ENV HEALTHCHECK_ENDPOINT=${HEALTHCHECK_ENDPOINT}

WORKDIR /

RUN mkdir -p \
    /$APP_DIR/models

COPY --from=localai-builder /build/local-ai /$APP_DIR/local-ai

COPY --from=grpc /build/grpc/output /usr/local
ENV PATH=/usr/local/bin:$PATH

COPY root/entrypoint.sh /$APP_DIR/entrypoint.sh
RUN chmod +x /$APP_DIR/entrypoint.sh

# Define the health check command
HEALTHCHECK --interval=1m --timeout=10m --retries=10 \
  CMD curl -f $HEALTHCHECK_ENDPOINT || exit 1
  
VOLUME /$APP_DIR/models
EXPOSE 8080
WORKDIR /$APP_DIR
#ENTRYPOINT [ "tail", "-f", "/dev/null" ]
ENTRYPOINT [ "./entrypoint.sh" ]