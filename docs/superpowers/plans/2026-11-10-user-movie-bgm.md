# User Movie BGM Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 使用用户提供的约 34.47 秒视频音轨替换一键成片的 Titan 配乐。

**Architecture:** 将音轨提取为已有原生导出器支持的 MP3，独立资源和私有文件名，从源开头播放，保留淡入淡出与按成片长度循环。升级模板缓存版本并移除不再适用的 Titan UI、烧录署名及 MP4 元数据，不改无人机控制或视频编解码路径。

**Tech Stack:** ArkTS、C++、本机 FFmpeg mp3_mf、Node 核心测试和 DevEco Hvigor。

## Global Constraints

- 新资源 movie-bgm-user-v1.mp3，48kHz、立体声、192kbps、828908 字节；从 0 秒开始。
- 模板版本 user-bgm-v5，旧 Titan 完成缓存不得直接复用。
- 不假定新音轨的歌名、作者或授权信息，不沿用 Scott Buckley 署名。
- 保留所有原片、现有运动和拍摄流程；无安装请求时不覆盖手机。

## Review Focus

- 手机已有旧配乐私有文件时仍应准备并使用新音轨。
- 被中断的资源复制不能被当作完整配乐。
- 更换音乐后新导出不显示或烧录旧作者信息。
- 短片保留首尾淡入淡出，长片循环新音轨而非旧资源。

## Tasks

- [x] 提取音轨，完整解码检查时长和非静音，记录资源哈希。
- [x] 先运行新私有配乐准备及模板缓存测试，观察旧资源路径/旧版本导致的失败。
- [x] 更新 ArkTS 资源、UI 与缓存版本；更新原生 offset 和署名策略并跑原生测试。
- [x] 全量核心回归、原生音频/帧/AVC 检查和独立审查。
- [x] 构建正式签名 HAP，核对源副本一致与包哈希；标记尚未安装。
