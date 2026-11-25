#!/usr/bin/env python3
"""Calibrate raw, unrotated views of a 9x6 inner-corner chessboard."""
import argparse
import json
from pathlib import Path
import cv2
import numpy as np

def calibrate(paths, device, output):
    object_points = np.zeros((9 * 6, 3), np.float32)
    object_points[:, :2] = np.mgrid[0:9, 0:6].T.reshape(-1, 2)
    objects, image_points, centers = [], [], []
    image_size = None
    for path in paths:
        image = cv2.imread(str(path), cv2.IMREAD_GRAYSCALE)
        if image is None:
            continue
        size = (image.shape[1], image.shape[0])
        if image_size is not None and image_size != size:
            raise ValueError("标定照片必须使用同一分辨率。")
        found, corners = cv2.findChessboardCornersSB(image, (9, 6), cv2.CALIB_CB_NORMALIZE_IMAGE)
        if not found:
            print(f"未检测到棋盘格：{path.name}")
            continue
        image_size = size
        objects.append(object_points.copy())
        image_points.append(corners)
        centers.append(corners.reshape(-1, 2).mean(axis=0) / np.array(size))
    if len(objects) < 8:
        raise ValueError(f"只有 {len(objects)} 张可用照片，至少需要 8 张不同位置和角度的原始棋盘格照片。")
    spread = np.ptp(np.array(centers), axis=0)
    if np.any(spread < 0.18):
        raise ValueError("棋盘格位置覆盖不足，请覆盖画面左、右、上、下并改变倾斜角度。")
    rms, matrix, coefficients, rotations, translations = cv2.calibrateCamera(
        objects, image_points, image_size, None, None
    )
    if not np.isfinite(rms) or rms > 2:
        raise ValueError(f"重投影误差 {rms:.3f} px 过大，请重新采集清楚的棋盘格照片。")
    report = {
        "version": 1, "deviceID": device, "width": image_size[0], "height": image_size[1],
        "fx": float(matrix[0, 0]), "fy": float(matrix[1, 1]),
        "cx": float(matrix[0, 2]), "cy": float(matrix[1, 2]),
        "distortion": coefficients.ravel()[:5].tolist(), "reprojectionRMS": float(rms),
        "imagesUsed": len(objects),
    }
    with output.open("x", encoding="utf-8") as handle:
        json.dump(report, handle, indent=2, ensure_ascii=False)
    print(f"已保存 {output}，使用 {len(objects)} 张，RMS {rms:.3f} px。")

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("folder", type=Path, help="同一摄像头、同一分辨率的 original.jpg 照片目录")
    parser.add_argument("--device-id", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    paths = sorted(path for path in args.folder.rglob("*") if path.suffix.lower() in {".jpg", ".jpeg", ".png"})
    calibrate(paths, args.device_id, args.output)

if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, cv2.error) as error:
        raise SystemExit(str(error)) from error
