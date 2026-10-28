# /// script
# requires-python = ">=3.11,<3.13"
# dependencies = ["torch==2.5.1", "coremltools==8.3.0", "numpy<2.2"]
# ///
"""Converts Real-ESRGAN's realesr-general-x4v3 (SRVGGNetCompact, BSD-3, xinntao) to the Core ML package Pilot's
upscaler ships: Packaging/Upscale/realesr-general-x4v3.mlpackage, fp16, one 256 x 256 RGB tile in [0, 1] as `input`,
its 1024 x 1024 as `output`. Run once, by hand, when the model changes; the package is committed so a build needs no
Python (Scripts/build-app.sh compiles it into the bundle).

    uv run Scripts/convert-upscaler.py
"""
import hashlib
import pathlib
import urllib.request

import coremltools as ct
import numpy as np
import torch
from torch import nn
from torch.nn import functional as F

URL = "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-general-x4v3.pth"
SHA256 = "8dc7edb9ac80ccdc30c3a5dca6616509367f05fbc184ad95b731f05bece96292"
TILE = 256
ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "Packaging/Upscale/realesr-general-x4v3.mlpackage"


class SRVGGNetCompact(nn.Module):
    """Real-ESRGAN's realesrgan/archs/srvgg_arch.py (BSD-3, Copyright (c) 2021 Xintao Wang), PReLU only."""

    def __init__(self, num_in_ch=3, num_out_ch=3, num_feat=64, num_conv=32, upscale=4):
        super().__init__()
        self.upscale = upscale
        self.body = nn.ModuleList([nn.Conv2d(num_in_ch, num_feat, 3, 1, 1), nn.PReLU(num_parameters=num_feat)])
        for _ in range(num_conv):
            self.body.extend([nn.Conv2d(num_feat, num_feat, 3, 1, 1), nn.PReLU(num_parameters=num_feat)])
        self.body.append(nn.Conv2d(num_feat, num_out_ch * upscale * upscale, 3, 1, 1))
        self.upsampler = nn.PixelShuffle(upscale)

    def forward(self, x):
        out = x
        for layer in self.body:
            out = layer(out)
        return self.upsampler(out) + F.interpolate(x, scale_factor=self.upscale, mode="nearest")


def checkpoint() -> pathlib.Path:
    cache = pathlib.Path.home() / "Library/Caches/pilot-convert" / URL.rsplit("/", 1)[1]
    if not cache.exists():
        cache.parent.mkdir(parents=True, exist_ok=True)
        urllib.request.urlretrieve(URL, cache)
    digest = hashlib.sha256(cache.read_bytes()).hexdigest()
    if digest != SHA256:
        cache.unlink()
        raise SystemExit(f"checksum mismatch: {digest}")
    return cache


def main():
    net = SRVGGNetCompact()
    state = torch.load(checkpoint(), map_location="cpu", weights_only=True)
    net.load_state_dict(state.get("params", state), strict=True)
    net.eval()
    example = torch.rand(1, 3, TILE, TILE)
    traced = torch.jit.trace(net, example)
    model = ct.convert(
        traced,
        inputs=[ct.TensorType(name="input", shape=example.shape, dtype=np.float32)],
        outputs=[ct.TensorType(name="output", dtype=np.float32)],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS14,
    )
    model.short_description = "Real-ESRGAN realesr-general-x4v3, 4x, one 256 px tile (BSD-3, Xintao Wang)"
    model.license = "BSD-3-Clause"
    # The traced net against the converted one on the example: fp16 keeps them within a few hundredths.
    with torch.no_grad():
        want = traced(example).numpy()
    got = model.predict({"input": example.numpy()})["output"]
    print("max difference against torch:", float(np.abs(want - got).max()))
    OUT.parent.mkdir(parents=True, exist_ok=True)
    model.save(str(OUT))
    print("wrote", OUT)


if __name__ == "__main__":
    main()
