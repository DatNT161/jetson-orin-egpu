#!/usr/bin/env python3
"""Dựng một mạng conv thuần bằng API TensorRT (không cần onnx/torch), build engine, ghi ra file.

Dùng để kiểm TensorRT của JetPack chạy được trên GPU nào: chạy dưới `dgpu` thì build cho 2080 Ti
(sm_75), chạy thường thì build cho iGPU Orin (sm_87). Đo tốc độ bằng trtexec --loadEngine.

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
    keep = []  # trọng số numpy phải sống tới khi build xong
    c_in = 3
    for i in range(layers):
        w = rng.standard_normal((ch, c_in, 3, 3), dtype=np.float32) * 0.05
        b = np.zeros(ch, dtype=np.float32)
        keep += [w, b]
        conv = net.add_convolution_nd(x, ch, (3, 3), trt.Weights(w), trt.Weights(b))
        conv.padding_nd = (1, 1)
        if i % 4 == 3:  # giảm kích thước như backbone
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
        raise SystemExit("build engine thất bại")
    with open(path, "wb") as f:
        f.write(plan)
    gflop = sum(
        2 * ch * (3 if i == 0 else ch) * 9 * (size >> ((i) // 4)) ** 2 / (4 if i % 4 == 3 else 1)
        for i in range(layers)
    ) * batch / 1e9
    print(f"engine {path}: {plan.nbytes / 1e6:.1f} MB, ~{gflop:.0f} GFLOP/lần chạy")


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
