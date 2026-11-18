# Linux 按住说话能力对齐

用户要求 Linux 对齐新版本能力。本轮先发布的 0.14.12 仅同步共享修复；继续补齐此前仅 Apple 平台具备的语音能力，另行验证和发布，不改已发布包。

## 实现范围

- 复用 Flutter 的 DesktopVoice、VoiceHold、VoiceKeyGate、输入历史和发送/编辑/取消规则；前台应用画面及文字终端均支持。独立拆窗沿用 macOS 的非目标，不截取语音快捷键。
- Linux 使用独立 `rapp-speech` worker，whisper-rs/whisper.cpp CPU 本地识别，PulseAudio/PipeWire 的 `parec` 采集 16kHz 单声道 PCM；音频仅驻留内存，不上传、不保存。
- 首次按语音按钮下载官方多语言 base 模型（147951465 字节），校验固定 SHA256 后原子写入用户 cache。录音开始前模型必须就绪；失败可重试，退出停止下载与录音。
- 保留共享 `VoiceInput` 状态机，通过 Linux MethodChannel 适配器承接 worker；只接受当前运行的事件，取消/失焦/切会话后不得发送迟到文本。Linux 最终识别等待允许超过 Apple 流式接口的一秒。
- 热键使用已有物理键到规范键码的映射；Linux 标签为 Alt/Ctrl/Shift/Super。正常轻点、组合键、鼠标/滚动 flush、密码焦点和终端原有按键均不得回归。
- 跟随系统首选语言；Linux 的提示不能引导到 Apple 设置。

## 验证与交付

- worker 的协议、输入上限、无声/取消行为；真实模型与公开音频 fixture 验证识别，不采集用户麦克风作为自动化测试。
- Dart 下载完整性、worker 生命周期、迟到结果及错误恢复；Linux 热键/界面/终端整合回归，然后全量 Flutter 和 Linux 打包联调。
- 更新打包和完整性检查以包含新 worker 及本地识别依赖；发布新版本及网站备用快照。
- 网站 Cloudflare 当前未授权，静态部署仍需用户完成登录；正常联网时线上下载逻辑已能读取 GitHub 最新发布。不能把 dry-run 或备用快照提交称为部署完成。
