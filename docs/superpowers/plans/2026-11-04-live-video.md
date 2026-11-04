# Live Video Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** 在当前 HarmonyOS 控制台内显示飞机的实时 HEVC 视频。

**Architecture:** ArkTS 保留 UDP 和完整组帧，N-API 快速复制并入队；Native 视频工作线程处理 HEVC 并驱动系统解码器输出到 XComponent Surface。视图只管理生命周期和统计。

**Tech Stack:** ArkTS / C++17 / N-API / HarmonyOS API 21 AVCodec / XComponent。

**Spec:** docs/superpowers/specs/2026-11-04-live-video-design.md（用户已批准开始）。

## Global Constraints

- 保留现有后台安全断开及所有飞控语义。
- 视频队列最多 16 个帧、8 MiB；单帧最多 2 MiB。
- 原版有限整理 3 帧、120 ms；显示过期阈值 2 秒。
- 不新增 FFmpeg、HTTP 预览依赖。
- 当前目录继续开发，不创建额外 worktree；用功能分支隔离已上传 main。

## Review Focus

- Surface 释放与异步回调并发不得使用失效指针。
- 丢包、乱序及 POC 回绕不得倒退解码参考链。
- 积压清理后不得继续把依赖丢失帧的 P 帧当成可解码画面。
- 参数变化与未知语法不得被过滤成错误的旧配置。
- 旧会话数据和旧显示计数不得延续到新会话。

### Task 1: HEVC 码流处理

Files: entry/src/main/cpp/HevcStream.h/.cpp, tests/native/hevc_test.cpp, tests/fixtures/video/。
Interface: namespace neo; Bytes=std::vector<uint8_t>; struct AccessUnit { Bytes bytes; bool randomAccess; }; class HevcStream { std::vector<AccessUnit> Feed(const Bytes&,int64_t nowMs); void Reset(); int Width() const; int Height() const; uint64_t Suppressed() const; uint64_t Reordered() const; }。

- [ ] 从原版回归样本创建过滤、乱序、截断、回绕、参数变化测试，先确认缺失实现导致失败。
- [ ] 移植 timing filter 和有限 POC 整理，正确拆分多个 access unit，提取 SPS 尺寸，保守处理未知语法。
- [ ] 用真实样本和合成边界测试确认实现。

### Task 2: 原生解码及有界队列

Files: entry/src/main/cpp/VideoPreview.cpp, CMakeLists.txt, types/libneovideo/index.d.ts, entry/oh-package.json5, entry/build-profile.json5。
Interface: libneovideo.so exposes start(surfaceId:string):void, stop():void, submit(bytes:ArrayBuffer):void, snapshot():VideoPreviewStats。统计字段在类型文件中集中定义。

- [ ] 先验证队列容量和溢出恢复测试（独立可移植队列类）。
- [ ] 实现 N-API 输入校验、视频线程、AVCodec 生命周期、输入输出回调、随机访问恢复及有界重试。
- [ ] 使用 API 21 arm64 工具链构建，检查错误码、线程退出及 NativeWindow 释放顺序。

### Task 3: ArkTS 集成与界面

Files: core/media/VideoPreview.ets, AppController.ets, DroneSession.ets, pages/Index.ets, entryability/EntryAbility.ets, tests/video-preview.test.cjs。
Interface: VideoPreview(native:VideoPreviewBackend), attach(surfaceId), detach(), setSession(identity), submit(frame), snapshot(nowMs); 独立后端注入便于无设备测试。

- [ ] 测试 Surface 重建、会话变化、过期状态、停止后迟到帧先失败。
- [ ] 绑定完整组帧、有效会话状态和 Surface；页面按尺寸保持比例并显示真实统计及过期遮罩。
- [ ] 原有 suite 全通过并完成 HAP 构建。

### Task 4: 集成验证与审查

- [ ] 使用原版样本离线回放和测试；可用手机上验证静态相机至少 5 分钟、重连和后台。
- [ ] 独立代码审查修复重要问题，更新使用说明及验证记录。
- [ ] 手机不可用则明确列出未验证项，不声称真机预览成功。

## Execution ledger

Ruling: 用户已批准开始；在当前 checkout 创建功能分支，保留所有现有工作，不额外要求 worktree/执行方式确认。
Ruling: HEVC 处理和 Native 解码通过上面的固定接口分工，并行部分遵循 dispatching-parallel-agents；主线程负责集成和最终验证。
