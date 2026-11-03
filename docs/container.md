# Running Splat Workshop in a container

The image holds Splat Workshop, Spirula Studio (Vulkan), splat-transform, ffmpeg and uv. Two things come from outside:

- the **Arcturus reconstruction scripts**: download them from [arcturus.vision/apps](https://arcturus.vision/apps) and mount them at `/opt/pipeline`;
- the **GPU driver**: it comes from the host, as described below.

Everything that should stay goes to `/data`: config, recordings, scenes and the package cache.

## Build

```bash
docker build --build-arg SPIRULA_REV=<commit> -t splat-workshop .
```

Use the Spirula revision the pipeline's README names (`git -C spirula-studio checkout <commit>`). On start, the container warns if the two differ.

Building takes about 20 minutes and a lot of memory: each shader compiler takes 3–4 GB, and `BUILD_JOBS` sets how many run at once (default 3). With 8 GB or less, use `--build-arg BUILD_JOBS=1`.

## Run

On start, the container chooses a Vulkan driver, lists the devices it sees and stops with a hint if there is no GPU. `SPLAT_VULKAN_DRIVER` (`wsl`, `nvidia`, `mesa` or `cpu`) overrides the choice.

**NVIDIA on Linux** needs the [NVIDIA Container Toolkit](https://github.com/NVIDIA/nvidia-container-toolkit). Its Vulkan driver is only there when the capabilities include `graphics`, which `all` does. [`docker/compose.yml`](../docker/compose.yml) is a complete example.

```bash
docker run --gpus all -e NVIDIA_DRIVER_CAPABILITIES=all -p 8771:8771 \
    -v ./data:/data -v ./av1-3dgs-pipeline:/opt/pipeline:ro splat-workshop
```

**AMD and Intel on Linux** use the Mesa drivers in the image:

```bash
docker run --device /dev/dri -p 8771:8771 \
    -v ./data:/data -v ./av1-3dgs-pipeline:/opt/pipeline:ro splat-workshop
```

**WSL** has no Linux Vulkan driver for the GPU. The image goes through Mesa's Dozen, which runs Vulkan on Direct3D 12, and needs the host's libraries:

```bash
docker run --device /dev/dxg -v /usr/lib/wsl:/wsl:ro -p 8771:8771 \
    -v ./data:/data -v ./av1-3dgs-pipeline:/opt/pipeline:ro splat-workshop
```

Dozen is not a conformant Vulkan driver, and bundle adjustment runs on the CPU with it. Tested so far on an RTX 5070 Ti with Spirula's structure-from-motion; training through Dozen has not been tested yet.

**No GPU:** `-e ALLOW_CPU=1` runs on the CPU (lavapipe). This is for trying things out: matching took about 28 times as long as on a GPU in one test.

## Settings

| Variable | |
|---|---|
| `FRAME_HOST` | your Frame's SSH target, e.g. `steamos@192.168.1.50` |
| `SPLAT_ALLOWED_HOSTS` | host names behind a reverse proxy, separated by commas |
| `SPLAT_UID`, `SPLAT_GID` | the user the server runs as (default 1000), and who owns `/data` |
| `SPLAT_PORT` | default 8771 |

Everything else is in `/data/config.toml`, which is written on the first start. The options are explained in [`config.example.toml`](../config.example.toml).

**The Frame:** mount a private key that `ssh-copy-id` has authorized at `/run/secrets/frame_key`. The Frame's own key is remembered on first contact.

## Access

There is **no login**. The image runs in LAN mode, so anyone in your network who can reach the port can use it.

Behind a reverse proxy, list the host name in `SPLAT_ALLOWED_HOSTS`. The server then sees only the proxy's address, so its check for private addresses no longer protects you: put a login in front of the proxy.

## What is different from the desktop

- **Not available:** tray icon, desktop notifications, standby when done, and everything that opens a window (video player, folder, Spirula viewer, Blender).
- **Importing splat files** only works from the machine itself. With a container, that means `docker exec` or `kubectl port-forward`, with the file somewhere under `/data`.
- **Recordings** come from the Frame over SSH, or you copy them to `/data/recordings`. The page cannot upload them.
- **Deleted scenes go to the trash** at `/data/home/.local/share/Trash` and still take up space there until you empty it.
- **Conversions end with the container.** A stopped conversion can be resumed under *Cancelled runs* as long as `/data` stays.

## Kubernetes

Run one replica with `/data` on a persistent volume and `--no-idle-exit` from the image's default command. The essentials for a WSL node, with the NVIDIA runtime class:

```yaml
spec:
  runtimeClassName: nvidia
  containers:
    - name: splat-workshop
      image: splat-workshop
      env:
        - name: NVIDIA_VISIBLE_DEVICES
          value: all
        - name: NVIDIA_DRIVER_CAPABILITIES
          value: all
        - name: SPLAT_ALLOWED_HOSTS
          value: splat.example.org
      resources:
        limits:
          nvidia.com/gpu: "1"   # or leave it out to share the GPU with other pods, unprotected
      volumeMounts:
        - { name: data, mountPath: /data }
        - { name: wsl, mountPath: /wsl, readOnly: true }
  volumes:
    - name: wsl
      hostPath: { path: /usr/lib/wsl, type: Directory }
```

The container starts as root to link the WSL libraries and to set the owner of `/data`, then continues as `SPLAT_UID`. On a normal Linux node, the runtime class, the `wsl` volume and `NVIDIA_VISIBLE_DEVICES` depend on how your cluster exposes GPUs.
