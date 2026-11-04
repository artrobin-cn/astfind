import argparse
from pathlib import Path

import coremltools as ct
import numpy as np
import onnx


def fuse_final_gemm_batchnorm(model: onnx.ModelProto) -> bool:
    graph = model.graph
    if len(graph.node) < 2:
        return False
    gemm, batchnorm = graph.node[-2:]
    if gemm.op_type != "Gemm" or batchnorm.op_type != "BatchNormalization":
        return False
    attributes = {item.name: item.f for item in gemm.attribute}
    if attributes.get("alpha", 1) != 1 or attributes.get("beta", 1) != 1:
        raise SystemExit("only unit-alpha/beta Gemm fusion is supported")

    initializers = {item.name: item for item in graph.initializer}
    required = [gemm.input[1], gemm.input[2], *batchnorm.input[1:]]
    if any(name not in initializers for name in required):
        raise SystemExit("Gemm/BatchNormalization parameters must be initializers")
    arrays = {name: onnx.numpy_helper.to_array(initializers[name]) for name in required}
    weight = arrays[gemm.input[1]]
    bias = arrays[gemm.input[2]]
    gamma = arrays[batchnorm.input[1]]
    beta = arrays[batchnorm.input[2]]
    mean = arrays[batchnorm.input[3]]
    variance = arrays[batchnorm.input[4]]
    epsilon = next((item.f for item in batchnorm.attribute if item.name == "epsilon"), 1e-5)
    scale = gamma / np.sqrt(variance + epsilon)
    if weight.shape[0] != scale.shape[0] or bias.shape != scale.shape:
        raise SystemExit("unexpected Gemm/BatchNormalization parameter shapes")

    fused_weight = (weight * scale[:, None]).astype(np.float32)
    fused_bias = ((bias - mean) * scale + beta).astype(np.float32)
    initializers[gemm.input[1]].CopyFrom(onnx.numpy_helper.from_array(fused_weight, gemm.input[1]))
    initializers[gemm.input[2]].CopyFrom(onnx.numpy_helper.from_array(fused_bias, gemm.input[2]))
    gemm.output[0] = batchnorm.output[0]
    graph.node.remove(batchnorm)
    onnx.checker.check_model(model)
    return True


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("onnx_model")
    parser.add_argument("output_package")
    args = parser.parse_args()

    source = Path(args.onnx_model)
    output = Path(args.output_package)
    if not source.is_file():
        raise SystemExit("ONNX model does not exist")
    if output.suffix != ".mlmodel":
        raise SystemExit("output must end in .mlmodel")

    onnx_model = onnx.load(str(source))
    graph = onnx_model.graph
    initializer_names = {item.name for item in graph.initializer}
    inputs = [item for item in graph.input if item.name not in initializer_names]
    if len(inputs) != 1 or len(graph.output) != 1:
        raise SystemExit("expected one model input and one output")

    input_shape = [dimension.dim_value for dimension in inputs[0].type.tensor_type.shape.dim]
    output_shape = [dimension.dim_value for dimension in graph.output[0].type.tensor_type.shape.dim]
    if input_shape[0] not in (0, 1) or input_shape[1:] != [3, 112, 112]:
        raise SystemExit(f"unexpected input shape: {input_shape}")
    if output_shape[-1] != 512:
        raise SystemExit(f"unexpected output shape: {output_shape}")

    inputs[0].type.tensor_type.shape.dim[0].dim_value = 1
    input_name = inputs[0].name
    output.parent.mkdir(parents=True, exist_ok=True)
    if fuse_final_gemm_batchnorm(onnx_model):
        onnx.save(onnx_model, str(output.parent / f"{source.stem}-fused.onnx"))
    model = ct.converters.onnx.convert(
        onnx_model,
        minimum_ios_deployment_target="13",
    )
    model.save(str(output))
    print(f"input={input_name} shape={input_shape}")
    print(f"output={graph.output[0].name} shape={output_shape}")


if __name__ == "__main__":
    main()
