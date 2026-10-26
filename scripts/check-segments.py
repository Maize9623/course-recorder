#!/usr/bin/env python3
"""Check MP4 segment metadata and summed audio/video durations with ffprobe.

This does not decode media or prove continuity of the recorded content.
"""

import argparse
import json
import math
from pathlib import Path
import re
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(
        description="核对首段 MP4 及同目录的（第N段）文件，汇总帧数与音视频时长。只读元数据，不验证画面内容或跨段内容连续性。")
    parser.add_argument("first_segment", type=Path, help="首段 MP4 路径；需安装 ffprobe，脚本不搜索其他录制目录")
    parser.add_argument("--tolerance", type=float, default=0.001,
                        help="音视频总时长允许差值，单位秒（默认 0.001）")
    args = parser.parse_args()
    if not math.isfinite(args.tolerance) or args.tolerance < 0:
        parser.error("--tolerance 必须是有限的非负数")
    first = args.first_segment.expanduser()
    if first.suffix.lower() != ".mp4" or not first.is_file():
        parser.error("请提供存在的首段 MP4 文件")
    ffprobe = shutil.which("ffprobe")
    if ffprobe is None:
        parser.error("未找到 ffprobe，请安装 FFmpeg 并将 ffprobe 加入 PATH")

    pattern = re.compile(re.escape(first.stem) + r"（第(\d+)段）\.mp4", re.IGNORECASE)
    numbered = sorted((int(match.group(1)), path) for path in first.parent.iterdir()
                      if path.is_file() and (match := pattern.fullmatch(path.name)))
    numbers = [number for number, _ in numbered]
    files = [first] + [path for _, path in numbered]
    failed = numbers != list(range(2, len(numbers) + 2))
    if failed:
        print("FAIL: 分段编号不连续或不从第 2 段开始")

    total_video = total_audio = 0.0
    total_frames = 0
    for path in files:
        try:
            out = subprocess.run([ffprobe, "-v", "error", "-show_entries",
                                  "stream=codec_type,duration,nb_frames,start_time", "-of", "json", str(path)],
                                 capture_output=True, text=True, timeout=30, check=True)
            streams = json.loads(out.stdout)["streams"]
            video = next(stream for stream in streams if stream["codec_type"] == "video")
            audio = next(stream for stream in streams if stream["codec_type"] == "audio")
            vd, ad = float(video["duration"]), float(audio["duration"])
            if not all(math.isfinite(value) and value > 0 for value in (vd, ad)):
                raise ValueError("invalid stream duration")
            frames = int(video["nb_frames"])
            vs, als = float(video.get("start_time", 0)), float(audio.get("start_time", 0))
        except (subprocess.SubprocessError, OSError, KeyError, StopIteration, ValueError) as error:
            print(f"FAIL: {path.name}: 无法读取完整的音视频元数据（{type(error).__name__}）")
            failed = True
            continue
        total_video += vd
        total_audio += ad
        total_frames += frames
        markers = path.with_suffix(".markers.srt").is_file()
        print(f"{path.name}: video {vd:.6f}s / {frames} frames (start {vs:.6f}), "
              f"audio {ad:.6f}s (start {als:.6f}), markers {'yes' if markers else 'no'}")

    delta = total_audio - total_video
    print(f"total: {len(files)} files, video {total_video:.6f}s / {total_frames} frames, "
          f"audio {total_audio:.6f}s, audio-video {delta:+.6f}s")
    if abs(delta) > args.tolerance:
        print(f"FAIL: 音视频总时长差值超过 {args.tolerance:.6f}s")
        failed = True
    if not failed:
        print("PASS: 分段元数据完整，音视频总时长在允许误差内")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
