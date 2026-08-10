ARG BASE_IMAGE="ghcr.io/ublue-os/bluefin-dx"
ARG BASE_TAG="latest"

FROM ${BASE_IMAGE}:${BASE_TAG}

# Which image family this is. build.sh keys desktop-only packages off it, since
# ucore is a headless server image and has no use for a GUI terminal.
ARG VARIANT="bluefin"

COPY build_files/ /ctx/

RUN --mount=type=cache,dst=/var/cache/libdnf5,sharing=locked \
    /ctx/build.sh "${VARIANT}" && \
    rm -rf /ctx && \
    ostree container commit
