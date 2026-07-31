ARG BASE_IMAGE="ghcr.io/ublue-os/bluefin-dx"
ARG BASE_TAG="latest"

FROM ${BASE_IMAGE}:${BASE_TAG}

COPY build_files/ /ctx/

RUN --mount=type=cache,dst=/var/cache/libdnf5,sharing=locked \
    /ctx/build.sh && \
    rm -rf /ctx && \
    ostree container commit
