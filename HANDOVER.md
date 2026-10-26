# 开发交接：Course Recorder

本文件是可随源码公开的技术交接。接手时先读本文件，再读 [README](README.md) 和 [AGENTS](AGENTS.md)。本机私有补充可能另存于被 Git 忽略的 HANDOVER.local.md，不属于公开发布内容。

## 1. 当前状态

当前应用版本为 1.4.2，处于本机可用、持续试用迭代阶段。功能包括四镜头、横竖屏、人像处理、实时录制与分段保存、口播制作、可审核的 AI 草稿、SRT 和会议输出窗口。已验证范围与待验收能力以 [README 的状态摘要](README.md#工作全景图同步摘要) 为准。

Package.swift 声明 macOS 14、Swift tools 5.10；使用 Swift 5 语言模式和系统框架，不引入第三方 Swift 包。已覆盖 Apple Silicon 开发环境，其他系统版本和架构仍需独立验收。

## 2. 代码地图

| 目录 | 职责 |
|---|---|
| App | 设置、全局状态、权限、快捷键、项目操作 |
| Capture | 摄像头、麦克风、屏幕、鼠标和最新帧存储 |
| Processing | Vision 分割、人脸处理、美颜和形变 |
| Render | 布局、Core Image 合成、课件与时间驱动引擎 |
| Audio | 采样读取、音频处理、混音、BGM |
| Recording | AVAssetWriter、整数采样音频时间轴和分段 |
| Production | 口播项目、素材、时间线、AI、字幕与导出 |
| UI | SwiftUI/AppKit 界面、提词器、控制条、共享窗口 |
| *SelfTest.swift | CPU、合成媒体、生命周期和文件检查入口 |

实时链路：摄像头经处理进入 FrameStore，屏幕和课件进入 RenderEngine，按布局合成后分发给独立 FrameSink。预览、共享窗口和 Recorder 是不同消费者。麦克风、系统声和 BGM 经 AudioMixer 写入录制器。

口播制作按口播时间记录镜头事件、演示素材和鼠标信息；ProjectExporter 用独立处理器、引擎和离线写入器导出。原始口播与演示素材保留完整源画幅，最终画幅通过 RecordingSettings.outputSize 与布局决定。

## 3. 必须保持的约定

1. 录制保存优先。正在录制、暂停或收尾时不要覆盖应用包、重启或运行 GPU 压力检查。
2. 不使用 movieFragmentInterval；本项目曾在 macOS 的 MP4 收尾中遇到该写法失败。
3. Recorder 的音频时间轴使用整数采样连续累计。改动后检查分段总时长、音视频一致性和连接处。
4. 离线写入按 inputReadiness 交替提供音视频，音频结束调用 finishAudioInput()，避免单路阻塞。
5. 不削弱写入器 stop() 收尾期间的生命周期持有；先等演示 take 写完，再导出、换项目或删项目。
6. 重录、导入和导出先写新文件，核对令牌与项目快照，成功后才更新引用；失败保留原媒体与旧成片。
7. 项目删除使用系统废纸篓，不用永久删除替代。
8. Bundle ID 固定为 com.gene.course-recorder；保留签名脚本的 identifier requirement，减少本机更新造成的重复授权。
9. 创建 AppState 的离屏工具必须立即设置 persistsSettings = false，不改使用者设置。
10. 引擎接口保持时间参数化，以便离线与实时共用。GUI 使用 ViewState；SwiftUI 画布写作 SwiftUI.Canvas，避免与渲染 Canvas 同名。
11. 分段保护降低损失范围，不保证零丢失；正在写入或收尾的文件仍可能损坏，续录也受存储条件限制。

## 4. 横竖屏、人像与会议输出

- RecordingSettings.outputSize 统一实时画布、录制、导入和成片；项目 outputAspect 可选，旧项目缺省横屏。
- 竖屏分屏使用独立 portraitCameraAtBottom / portraitPersonHeight，默认底部人像 25%、内容主区域 75%；横屏仍用 cameraOnRight / personWidth。
- ContentSlot.sourceCrop 使用全源归一坐标；缩放与点击映射需要合并选区，点击高亮限制在实际可见内容内。
- 出镜、小窗、分屏共用 faceTracking；出镜跟随平滑水平人脸位置，保留手动垂直构图与缩放。同为 16:9 的 1× 全景没有平移余量。
- 摄像头发现包含 continuityCamera，具体设备条件见 README；不能把代码支持写成某型号已实测。
- ProgramWindowController 的共享窗口只挂接独立画面 sink，关闭后不停止 engine 或其他消费者。活动令牌与录制独立。
- 会议输出没有虚拟麦克风；本工具静音不代替会议静音，BGM 不会自动注入会议。真实会议端表现仍需验证。

## 5. 构建与验证

在仓库根目录运行：

```bash
./scripts/build-app.sh
open "dist/课程录制工具.app"
```

诊断入口和范围见 [README 验证章节](README.md#7-验证与稳定性) 与 Sources/CourseRecorder/main.swift。媒体自测使用现场生成的合成素材，不应依赖私人课程、第三方人物或未入库视频。

```bash
.build/release/CourseRecorder --output-aspect-cpu-test
.build/release/CourseRecorder --presenter-tracking-test
.build/release/CourseRecorder --device-quick-toggle-test
.build/release/CourseRecorder --meeting-output-test .selftest/meeting --no-capture
.build/release/CourseRecorder --device-quick-toggle-media-test .selftest/toggle --no-capture
.build/release/CourseRecorder --narration-import-preview-test .selftest/import-preview --no-capture
.build/release/CourseRecorder --writer-test .selftest/writer 23 0.08 noise-jitter-skip-seg5
python3 scripts/check-segments.py .selftest/writer/writer-23s-offset80-noise-jitter-skip-seg5.mp4
```

分段核对脚本只读指定首段及同目录的后续分段，依赖 Python 3 与 PATH 中的 ffprobe。它检查流元数据、编号和音视频总时长（默认误差 1 毫秒），返回非零表示检查失败；不解码媒体，也不证明跨段内容没有缺口或重复。运行 `python3 scripts/check-segments.py --help` 查看参数。

媒体、界面、写入和真机检查只在使用者没有录制或试用时执行。带 live 的 AI 检查会联网并消耗当前账户额度，不能无理由运行。

## 6. 可选依赖和公开源码

演示文稿转换使用 LibreOffice 或 Keynote；普通 PDF/图片和手动录制不依赖它们。AI 使用本机设备端中文识别及 Codex 的 ChatGPT 登录；当前 CLI 默认路径固定于 ChatGPT.app 内部，尚未通用发现或独立隔离登录，详见 README。

项目使用 MIT 许可证。源码发布应包含所有 Swift、Package.swift、Resources、构建脚本、README、LICENSE 和项目开发说明；bg.png 是可选背景。录制视频、项目内容、个人设置、凭据、编译缓存、私有交接与测试输出均不入库。

不要把本地开发仓库的隐藏引用或完整 .git 目录当作公开源码包。公开发布使用仅含选定文件的干净仓库历史，源代码包用 git archive 导出。
