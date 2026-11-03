"""The container's start script: which way to the GPU it chooses, and that it stops instead of starting without one.

No container and no GPU: the script runs on a folder that stands in for /, with a fake vulkaninfo.
"""
import os
import subprocess
from pathlib import Path

import pytest

ENTRYPOINT = Path(__file__).resolve().parent.parent / "docker" / "entrypoint.sh"
GPU = "deviceType = PHYSICAL_DEVICE_TYPE_DISCRETE_GPU\ndeviceName = Some GPU\n"
CPU = "deviceType = PHYSICAL_DEVICE_TYPE_CPU\ndeviceName = llvmpipe\n"
REV = "a" * 40


@pytest.fixture
def box(tmp_path):
    class Box:
        root = tmp_path / "root"
        data = tmp_path / "data"
        bin = tmp_path / "bin"

        def touch(self, path, text=""):
            p = self.root / path.lstrip("/")
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(text)
            return p

        def vulkan(self, summary=GPU, code=0):
            self.bin.mkdir(exist_ok=True)
            p = self.bin / "vulkaninfo"
            p.write_text(f"#!/bin/sh\ncat <<'E'\n{summary}E\nexit {code}\n")
            p.chmod(0o755)

        def wsl(self):
            self.touch("/dev/dxg")
            self.touch("/wsl/lib/libd3d12.so")
            self.touch("/wsl/lib/libnvidia-gpucomp.so")
            self.touch("/wsl/drivers/nvmdi.inf_amd64_1/libnvwgf2umx.so")
            self.touch("/wsl/drivers/iigd_dch.inf_amd64_1/libigd12umd64.so")

        def run(self, **env):
            full = {k: v for k, v in os.environ.items() if k not in ("VK_DRIVER_FILES", "LD_LIBRARY_PATH")}
            full |= {"SPLAT_SYSROOT": str(self.root), "SPLAT_DATA": str(self.data),
                     "PATH": f"{self.bin}:{os.environ['PATH']}", **env}
            return subprocess.run([str(ENTRYPOINT), "sh", "-c",
                                   'echo "DRIVER_FILES=$VK_DRIVER_FILES"; echo "LIBS=${LD_LIBRARY_PATH:-}"; echo "HOME=$HOME"'],
                                  env=full, capture_output=True, text=True)
    b = Box()
    b.root.mkdir()
    b.touch("/usr/share/vulkan/icd.d/dzn_icd.json")
    b.touch("/usr/share/vulkan/icd.d/lvp_icd.json")
    b.vulkan()
    return b


def test_without_a_gpu_it_stops_and_says_what_to_do(box):
    r = box.run()
    assert r.returncode == 1 and "--gpus all" in r.stderr and "ALLOW_CPU" in r.stderr
    assert not box.data.exists()


def test_allow_cpu_runs_on_lavapipe(box):
    box.vulkan(CPU)
    r = box.run(ALLOW_CPU="1")
    assert r.returncode == 0 and f"DRIVER_FILES={box.root}/usr/share/vulkan/icd.d/lvp_icd.json" in r.stdout


def test_wsl_uses_dozen_and_links_every_gpus_driver(box):
    box.wsl()
    r = box.run()
    assert r.returncode == 0, r.stderr
    assert "Vulkan driver: wsl" in r.stdout
    assert f"DRIVER_FILES={box.root}/usr/share/vulkan/icd.d/dzn_icd.json" in r.stdout
    assert f"LIBS={box.root}/usr/lib/wsl/lib" in r.stdout
    lib, drivers = box.root / "usr/lib/wsl/lib", box.root / "usr/lib/wsl/drivers"
    assert (lib / "libnvidia-gpucomp.so").exists()              # NVIDIA opens it by its full path
    assert (drivers / "iigd_dch.inf_amd64_1/libigd12umd64.so").exists()   # Dozen fails without the iGPU's


def test_wsl_keeps_what_the_nvidia_runtime_already_put_there(box):
    box.wsl()
    box.touch("/wsl/lib/libdxcore.so", "from the host")
    box.touch("/usr/lib/wsl/lib/libdxcore.so", "from the runtime")
    assert box.run().returncode == 0
    p = box.root / "usr/lib/wsl/lib/libdxcore.so"
    assert not p.is_symlink() and p.read_text() == "from the runtime"


def test_wsl_without_the_host_libraries_stops(box):
    box.touch("/dev/dxg")
    r = box.run()
    assert r.returncode == 1 and "/usr/lib/wsl" in r.stderr


def test_nvidia_uses_the_driver_the_runtime_injected(box):
    box.touch("/dev/nvidiactl")
    icd = box.touch("/etc/vulkan/icd.d/nvidia_icd.json")
    r = box.run()
    assert r.returncode == 0 and "Vulkan driver: nvidia" in r.stdout and f"DRIVER_FILES={icd}" in r.stdout


def test_nvidia_without_graphics_capability_says_so(box):
    box.touch("/dev/nvidiactl")
    r = box.run()
    assert r.returncode == 1 and "NVIDIA_DRIVER_CAPABILITIES" in r.stderr


def test_amd_and_intel_leave_the_choice_to_mesa(box):
    box.touch("/dev/dri/renderD128")
    r = box.run()
    assert r.returncode == 0 and "Vulkan driver: mesa" in r.stdout and "DRIVER_FILES=\n" in r.stdout


def test_wsl_goes_before_nvidia_and_mesa(box):
    box.wsl()
    box.touch("/dev/nvidiactl")
    box.touch("/dev/dri/renderD128")
    assert "Vulkan driver: wsl" in box.run().stdout


def test_the_driver_can_be_forced(box):
    box.touch("/dev/dri/renderD128")
    box.vulkan(CPU)
    assert "Vulkan driver: cpu" in box.run(SPLAT_VULKAN_DRIVER="cpu").stdout
    r = box.run(SPLAT_VULKAN_DRIVER="metal")
    assert r.returncode == 1 and "SPLAT_VULKAN_DRIVER" in r.stderr


def test_only_the_cpu_renderer_counts_as_no_gpu(box):
    box.touch("/dev/dri/renderD128")
    box.vulkan(CPU)
    r = box.run()
    assert r.returncode == 1 and "only offers the CPU" in r.stderr


def test_a_vulkan_that_does_not_start_stops_the_container(box):
    box.touch("/dev/dri/renderD128")
    box.vulkan(code=1)
    assert box.run().returncode == 1
    assert box.run(SPLAT_SKIP_GPU_CHECK="1").returncode == 0


def test_first_start_prepares_data_and_keeps_an_edited_config(box):
    box.touch("/dev/dri/renderD128")
    r = box.run()
    assert f"HOME={box.data}/home" in r.stdout
    assert (box.data / "recordings").is_dir() and (box.data / "runs").is_dir()
    config = box.data / "config.toml"
    assert '"/opt/spirula/spirula"' in config.read_text()
    config.write_text("# mine\n")
    box.run()
    assert config.read_text() == "# mine\n"


def test_the_frame_key_gets_a_private_copy_and_an_ssh_config(box):
    box.touch("/dev/dri/renderD128")
    box.touch("/run/secrets/frame_key", "secret").chmod(0o644)
    assert box.run().returncode == 0
    copy = box.data / "home/.ssh/frame_key"
    assert copy.read_text() == "secret" and copy.stat().st_mode & 0o077 == 0
    assert f"IdentityFile {copy}" in (box.data / "home/.ssh/config").read_text()


def test_spirula_from_another_revision_than_the_pipelines_is_a_warning(box):
    box.touch("/dev/dri/renderD128")
    box.touch("/opt/spirula/REVISION", "b" * 40 + "\n")
    box.touch("/opt/pipeline/README.md", f"git -C spirula-studio checkout {REV}\n")
    r = box.run()
    assert r.returncode == 0 and "WARNING" in r.stdout and REV in r.stdout
    box.touch("/opt/spirula/REVISION", REV + "\n")
    assert "WARNING" not in box.run().stdout


def test_a_missing_pipeline_does_not_stop_the_container(box):
    # The page itself says what is still missing
    box.touch("/dev/dri/renderD128")
    r = box.run()
    assert r.returncode == 0 and "/opt/pipeline" in r.stdout
