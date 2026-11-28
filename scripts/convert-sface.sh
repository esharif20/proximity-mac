#!/bin/sh
# Builds Sources/PresenceSensors/Resources/SFace.mlmodelc from the OpenCV Zoo SFace ONNX model.
# A developer runs this once; the app only loads the compiled model and never touches the network.
# Needs uv and Xcode (xcrun coremlcompiler).
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="$ROOT/Sources/PresenceSensors/Resources"
URL=https://media.githubusercontent.com/media/opencv/opencv_zoo/main/models/face_recognition_sface/face_recognition_sface_2021dec.onnx
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

curl -fL --retry 3 -o "$WORK/sface.onnx" "$URL"

cat > "$WORK/convert.py" <<'PY'
import sys
import coremltools as ct
import onnx2torch
import torch

src, dst = sys.argv[1], sys.argv[2]
model = onnx2torch.convert(src).eval()
example = torch.zeros(1, 3, 112, 112)
traced = torch.jit.trace(model, example)
# OpenCV feeds SFace RGB pixels in 0..255 with no mean or scale, so the image input does the same.
mlmodel = ct.convert(
    traced,
    inputs=[ct.ImageType(name="image", shape=example.shape, color_layout=ct.colorlayout.RGB, scale=1.0)],
    outputs=[ct.TensorType(name="embedding")],
    compute_precision=ct.precision.FLOAT16,
    minimum_deployment_target=ct.target.macOS14,
    convert_to="mlprogram",
)
mlmodel.short_description = "SFace face embedding (OpenCV Zoo, Apache-2.0)"
mlmodel.save(dst)
PY

uv run --no-project --python 3.12 --with coremltools --with onnx2torch --with torch==2.5.1 \
  python "$WORK/convert.py" "$WORK/sface.onnx" "$WORK/SFace.mlpackage"
rm -rf "$OUT/SFace.mlmodelc"
mkdir -p "$OUT"
xcrun coremlcompiler compile "$WORK/SFace.mlpackage" "$OUT"
echo "wrote $OUT/SFace.mlmodelc"
