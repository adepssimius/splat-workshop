"""Training options: smooth surfaces (normals first) and simple colours (--sh-degree 0), via scripts/spirula-train.sh."""
import json
import os
import subprocess

from conftest import BIN, ROOT, RUNS, recording, server, tools_called, wait_job


def convert(**options):
    e = server.start_job({"path": str(recording()), "name": "Kitchen", "quality": "fast", "upload": False, **options})
    assert e is None, e
    return wait_job()


def spirula_calls(what):
    return [c[1:] for c in tools_called() if c[0] == "spirula" and c[1] == what]


def test_both_options_are_on_unless_switched_off():
    js = convert()
    assert js["result"] == "ok", js["tail"]
    data = str(RUNS / "Kitchen" / "dataset")
    assert spirula_calls("geometry") == [["geometry", data]]
    assert spirula_calls("train")[0][-2:] == ["--sh-degree", "0"]
    meta = server.read_meta("Kitchen")
    assert meta["normals"] is True and meta["sh0"] is True


def test_switched_off_the_training_is_as_before():
    js = convert(normals=False, sh0=False)
    assert js["result"] == "ok", js["tail"]
    assert spirula_calls("geometry") == []
    assert "--sh-degree" not in spirula_calls("train")[0]
    meta = server.read_meta("Kitchen")
    assert meta["normals"] is False and meta["sh0"] is False


def test_resume_keeps_the_scene_options():
    convert(normals=False, sh0=True)
    os.environ["FAKE_PIPELINE"] = "fail"
    server.resume_run("Kitchen", fresh=True)
    wait_job()
    assert spirula_calls("geometry") == []
    assert all(c[-2:] == ["--sh-degree", "0"] for c in spirula_calls("train"))


def test_the_wrapper_estimates_normals_first(tmp_path):
    data = tmp_path / "dataset"
    for cam in ("cam0", "cam1"):
        (data / "images" / cam).mkdir(parents=True)
        (data / "images" / cam / "0000.jpg").write_bytes(b"jpg")
    env = {**os.environ, "SPIRULA_REAL": str(BIN / "spirula"), "NORMALS": "1", "SH0": "0"}
    r = subprocess.run([str(ROOT / "scripts" / "spirula-train.sh"), "train", "--data", str(data)],
                       env=env, capture_output=True, text=True, check=True)
    assert r.stdout.splitlines()[0] == "@@ normals 2"
    assert sorted(p.name for p in (data / "normals").rglob("*")) == ["0000.png", "0000.png", "cam0", "cam1"]
    assert [c[:2] for c in tools_called()] == [["spirula", "geometry"], ["spirula", "train"]]
    # anything but training goes to Spirula unchanged
    subprocess.run([str(ROOT / "scripts" / "spirula-train.sh"), "sfm", "auto", "--help"], env=env, check=True)
    assert tools_called()[-1] == ["spirula", "sfm", "auto", "--help"]


def test_progress_while_estimating_normals():
    p = server.parse_output("Running native Spirula SfM\n@@ normals 40\nEstimating surface normals for 40 images ...\n")
    assert p["phase"] == 2 and p["info"]["normals"] == {"total": 40}
    p = server.parse_output("@@ normals 40\nstep   1000/3000 ( 33%)  splats 1000  [elapsed 00:00:01.000 | "
                            "ETA 00:00:02.000]  rgb_loss=0.1  ssim=0.8  psnr=28.5\n")
    assert "normals" not in p["info"] and p["pct"] == 33          # the training has begun


def test_cleaning_up_the_images_takes_the_normals_too(api):
    convert()
    d = RUNS / "Kitchen" / "dataset"
    for sub in ("images/cam0/0000.jpg", "normals/cam0/0000.png"):
        (d / sub).parent.mkdir(parents=True, exist_ok=True)
        (d / sub).write_bytes(b"x" * 5000)
    assert server.disk_usage(RUNS / "Kitchen")["images"] >= 8192
    assert api.post("/api/clean", {"slug": "Kitchen", "what": "images"})[0] == 200
    assert not (d / "images").exists() and not (d / "normals").exists()
    assert json.loads((RUNS / "Kitchen.ui.json").read_text())["cleaned"] == ["images"]
