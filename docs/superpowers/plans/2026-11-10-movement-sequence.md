# 八相运动顺序组合 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 将一句自然语言中的多步八相运动按顺序执行，保留现有单动作及拍摄路径。

**Architecture:** 新增 move_sequence 动作和独立校验/串行执行器，整条复用 AppController.run 互斥和取消；单步仍由 FlightCommandService.move 发送并回中。新路径增加执行中状态检查，默认参数不改变旧调用行为。

**Tech Stack:** ArkTS、现有 Node 离线核心测试、DevEco Hvigor。

**Spec:** docs/superpowers/specs/2026-11-10-movement-sequence-design.md

## Global Constraints

- 2–8 步，每步 0.1–10 秒，总计最多 30 秒，方向仅八相。
- 任何无效步骤导致首步前整条拒绝；有限重复展开后再校验；不自动起飞、混合拍摄或同时多轴。
- 现有单动作、主体选择、特写运镜及媒体路径保持原有行为；保留已有未提交改动，不提交或推送。

## Review Focus

- 最后一步非法时不得先飞前几步。
- 取消或降落发生在回中等待期间时不得继续下一步。
- 新鲜下行仍有但已落地/飞行模式变化时必须中断。
- 新请求、旧回复、轮次变化不得触发续跑或并发任务。
- 提示词不得误将混合拍摄语句截成运动子集，原主体选择专用协议保持隔离。

## Task 1: 动作协议与模型规则

- [x] 新增 tests/movement-sequence-schema.test.cjs，观察旧代码拒绝有效序列/缺少规则的失败。
- [x] 修改 AgentAction、AgentPrompt、DeepSeekPayload 和桌面接收器，复用 MovementSequence 导出的步骤校验。
- [x] 离线验证手机/桌面一致、字段与总时长限制、主体阶段隔离、原 move 和 recipe 回归。

## Task 2: 串行执行与实时中断

- [x] 新增 tests/movement-sequence.test.cjs，验证顺序、完整预检、失败和取消后不续跑，先观察失败。
- [x] 新增 MovementSequence.ets 的 MovementStep、validateMovementSteps 和 runMovementSequence。
- [x] FlightCommandService.move 增加可选 canContinue 回调，仅新路径使用，沿用 finally 回中。
- [x] 新增 tests/movement-sequence-controller.test.cjs 覆盖真实服务与调度整合，观察失败后接 AppController。
- [x] 整条序列使用单个 run 锁和取消 token，回中完成才推进；新路径状态检查不重用视觉样本超时。
- [x] AssistantProgress 显示进行中的步数与动作，原拍摄展示不受影响。

## Task 3: 回归与交付

- [x] 全量运行 tools/test-core.cjs，修复所有新引入失败并记录已有失败。
- [x] 独立审查执行中断、互斥、协议和旧路径兼容性。
- [x] 构建正式签名 HAP，确认源文件与构建副本一致、diff --check 通过，记录包哈希和未安装状态。
