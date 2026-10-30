#!/usr/bin/env python3
"""Build a plain conv network with the TensorRT API (no onnx/torch needed), build the engine, write it to a file.

Used to check which GPU the JetPack TensorRT runs on: under `dgpu` it builds for the discrete card
(e.g. sm_75/sm_86), otherwise for the Orin iGPU (sm_87). Measure speed with trtexec --loadEngine.

    dgpu python3 trt_conv_bench.py conv-2080ti.engine --fp16
    dgpu /usr/src/tensorrt/bin/trtexec --loadEngine=conv-2080ti.engine
"""
import argparse

import numpy as np
import tensorrt as trt


def build(path, fp16, batch, size, layers, ch):
    log = trt.Logger(trt.Logger.WARNING)
    builder = trt.Builder(log)
    net = builder.create_network(0)
    x = net.add_input("x", trt.float32, (batch, 3, size, size))
    rng = np.random.default_rng(0)
    keep = []  # numpy weights must stay alive until the build finishes
    c_in = 3
    for i in range(layers):
        w = rng.standard_normal((ch, c_in, 3, 3), dtype=np.float32) * 0.05
        b = np.zeros(ch, dtype=np.float32)
        keep += [w, b]
        conv = net.add_convolution_nd(x, ch, (3, 3), trt.Weights(w), trt.Weights(b))
        conv.padding_nd = (1, 1)
        if i % 4 == 3:  # downsample like a backbone
            conv.stride_nd = (2, 2)
        x = net.add_activation(conv.get_output(0), trt.ActivationType.RELU).get_output(0)
        c_in = ch
    net.mark_output(x)

    cfg = builder.create_builder_config()
    cfg.set_memory_pool_limit(trt.MemoryPoolType.WORKSPACE, 1 << 30)
    if fp16:
        cfg.set_flag(trt.BuilderFlag.FP16)
    plan = builder.build_serialized_network(net, cfg)
    if plan is None:
        raise SystemExit("engine build failed")
    with open(path, "wb") as f:
        f.write(plan)
    gflop = sum(
        2 * ch * (3 if i == 0 else ch) * 9 * (size >> ((i) // 4)) ** 2 / (4 if i % 4 == 3 else 1)
        for i in range(layers)
    ) * batch / 1e9
    print(f"engine {path}: {plan.nbytes / 1e6:.1f} MB, ~{gflop:.0f} GFLOP/run")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("engine")
    ap.add_argument("--fp16", action="store_true")
    ap.add_argument("--batch", type=int, default=8)
    ap.add_argument("--size", type=int, default=640)
    ap.add_argument("--layers", type=int, default=16)
    ap.add_argument("--ch", type=int, default=64)
    a = ap.parse_args()
    build(a.engine, a.fp16, a.batch, a.size, a.layers, a.ch)
