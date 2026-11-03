# Splat Workshop with Spirula Studio and all its tools; see docs/container.md.
# Not included: the Arcturus reconstruction scripts (mount them at /opt/pipeline) and the GPU driver
# (it comes from the host).
#
# The Spirula revision must be the one the pipeline's README names:
#   docker build --build-arg SPIRULA_REV=<commit> -t splat-workshop .
# Each shader compiler takes 3-4 GB of memory, so choose BUILD_JOBS by memory rather than by CPU cores.

FROM ubuntu:24.04 AS spirula
ARG SPIRULA_REV=09383f75029fd9e0f34847e50d8514c3932db984
ARG BUILD_JOBS=3
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential ca-certificates cmake curl git \
        libvulkan-dev ninja-build python3
WORKDIR /src
RUN git init -q . \
 && git remote add origin https://github.com/arcturus-vision/spirula-studio.git \
 && git fetch -q --depth 1 origin "$SPIRULA_REV" \
 && git checkout -q FETCH_HEAD
# Not build_develop.bash: it takes its job count from the host's memory and ignores the container's limit.
# SS_BUILD_SAM: `spirula geometry`, which "Smooth surfaces" runs, is only built with it.
RUN cmake -B build_vulkan -G Ninja -DCMAKE_BUILD_TYPE=Release -DSS_BACKEND=vulkan \
        -DSS_BUILD_GUI=OFF -DSS_BUILD_SFM=ON -DSS_BUILD_SAM=ON \
 && ninja -C build_vulkan -j"$BUILD_JOBS" spirula \
 && strip build_vulkan/spirula \
 && mkdir -p /out \
 && cp build_vulkan/spirula /out/ \
 && echo "$SPIRULA_REV" > /out/REVISION

FROM node:22-bookworm-slim AS node
RUN npm install -g @playcanvas/splat-transform@3.10.3

FROM ubuntu:24.04
# kisak-mesa: Ubuntu's own Mesa leaves out Dozen, the Vulkan driver for GPUs under WSL.
# libegl1: NVIDIA's Vulkan driver cannot start without it, and the NVIDIA runtime does not bring it along.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates gnupg software-properties-common \
 && add-apt-repository -y ppa:kisak/kisak-mesa \
 && apt-get install -y --no-install-recommends curl ffmpeg libegl1 libglib2.0-bin libgomp1 libvulkan1 \
        mesa-vulkan-drivers openssh-client python3 util-linux vulkan-tools \
 && apt-get purge -y --auto-remove gnupg software-properties-common \
 && rm -rf /var/lib/apt/lists/*
COPY --from=spirula /out/ /opt/spirula/
COPY --from=ghcr.io/astral-sh/uv:0.12.15 /uv /uvx /usr/local/bin/
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s /usr/local/lib/node_modules/@playcanvas/splat-transform/bin/cli.mjs /usr/local/bin/splat-transform \
 && splat-transform --version
COPY . /opt/splat-workshop/
WORKDIR /opt/splat-workshop
ENV HOME=/data/home \
    UV_CACHE_DIR=/data/cache/uv \
    SPLAT_WORKSHOP_CONFIG=/data/config.toml \
    SPLAT_LAN=1
VOLUME /data
EXPOSE 8771
ENTRYPOINT ["/opt/splat-workshop/docker/entrypoint.sh"]
CMD ["python3", "-m", "splat_workshop.server", "--no-idle-exit"]
