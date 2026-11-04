import argparse
import json
from pathlib import Path

import cv2
import numpy as np
import onnxruntime


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("onnx_model")
    parser.add_argument("aligned_image")
    parser.add_argument("output_json")
    args = parser.parse_args()

    if not Path(args.onnx_model).is_file() or not Path(args.aligned_image).is_file():
        raise SystemExit("model or aligned image does not exist")
    image = cv2.imread(args.aligned_image, cv2.IMREAD_COLOR)
    if image is None or image.shape[:2] != (112, 112):
        raise SystemExit("aligned image must be a readable 112x112 PNG")

    rgb = cv2.cvtColor(image, cv2.COLOR_BGR2RGB).astype(np.float32)
    tensor = ((rgb - 127.5) / 127.5).transpose(2, 0, 1)[None, ...]
    tensor = np.ascontiguousarray(tensor, dtype=np.float32)
    session = onnxruntime.InferenceSession(args.onnx_model, providers=["CPUExecutionProvider"])
    input_name = session.get_inputs()[0].name
    output = session.run(None, {input_name: tensor})[0]
    vector = output.flatten().astype(np.float32)
    if vector.shape != (512,) or not np.isfinite(vector).all():
        raise SystemExit(f"unexpected output: {vector.shape}")
    norm = float(np.linalg.norm(vector))
    if norm <= 0:
        raise SystemExit("output vector has zero norm")
    vector = vector / norm

    output_path = Path(args.output_json)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(vector.tolist()), encoding="utf-8")
    norm = float(np.linalg.norm(vector))
    print(f"dimension={vector.size} norm={norm:.9f}")


if __name__ == "__main__":
    main()
