# 给 agent 的操作规则

接手前先读 `HANDOVER.md`（现状、代码地图、下一步），再读 `README.md`（面向使用者）。

## 沟通

- 用中文回复用户，简洁、讲原因、不夸大。用户会自己试用并反馈。
- 录制不能异常中断是最高优先级；改动录制路径必须先跑写入测试再部署。
- 不要擅自做超出请求的改动；发现的问题先说明再动手。

## 环境

- SwiftPM 编译与任何 GPU/Metal/Vision 工作需要 `required_permissions: ["all"]`（默认沙箱禁用 GPU）。
- shell 是 zsh：`$var` 不按空格拆词；系统日志用 `/usr/bin/log`；通配符未匹配会中止整条命令。
- 删除文件用绝对路径或 `find <目录> -maxdepth 1 -name ... -delete`，不要"cd + 通配符 rm"。
- 用户的真实录制文件和测试图里的第三方人像都属于隐私，不要放进文档、截图或对外内容。

## 构建与部署

```bash
swift build -c release
./scripts/build-app.sh          # 生成 dist/课程录制工具.app（ad-hoc 签名，identifier 固定为 com.gene.course-recorder）
```

- 部署前检查应用是否在录制：`lsof -p <pid> | grep "\.mp4"` 有结果就**不要**重启。重启用 `kill <pid>`（SIGTERM，应用会保存后退出）再 `open dist/课程录制工具.app`。
- 用户在录制或试用时，不要运行占用 GPU 的测试（会让摄像头掉帧）。
- 不要改 Bundle ID 和签名脚本里的 `--requirements`，否则用户的摄像头/麦克风/录屏权限会失效。

## 代码约定

- 只用系统框架，不引入第三方依赖；Swift 5 语言模式；界面文案中文，代码注释英文（现有风格）。
- 不要用 `movieFragmentInterval`（MP4 分段写入在 macOS 上收尾失败，-16341）。
- `Recorder` 的音频时间轴是整数采样连续累计，改动后跑 `--writer-test <dir> 23 0.08 noise-jitter-skip-seg5` 并用 `python3 scripts/check-segments.py <首段MP4路径>` 核对音视频总时长（默认允许 1 毫秒元数据误差；需要 ffprobe）。
- 离线写入必须按 `Recorder.inputReadiness` 交替喂音视频，音频读完调 `finishAudioInput()`。
- 任何离屏工具创建 `AppState` 后设 `persistsSettings = false`。
- 界面状态用 `ViewState<T>`（`@State` 宏在当前 SDK 不可用）；SwiftUI 的画布要写 `SwiftUI.Canvas`（项目里有同名 `Canvas`）。
- 引擎接口保持时间参数化（`at:`），离线导出依赖它。

## 验证

- 文件：`ffprobe -v error -show_entries stream=codec_type,duration,nb_frames -of compact <文件>`。
- 全链路：`--production-test`、`--auto-record`（真机）、`--ui-snapshot`（界面截图）。命令与范围见 `HANDOVER.md` 第 5 节及其 README 验证章节链接。
- 性能日志：`/usr/bin/log show --last 5m --predicate 'subsystem == "com.gene.course-recorder"'`，正常值：摄像头约 30 fps、输出 60 fps、late 为个位数。
