# Task Exception Notice Implementation Plan

**状态更新：** 本文为最初接入计划。原因确认、导航/速度门槛及验证结果以[正式避障提示实现](2026-11-12-confirmed-obstacle-notice.md)为准，不能只凭任务终态与相机空闲提示运动已中止。

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans.

**Goal:** 旁路保留 0A/39 的短暂 0B，仅在飞机自行结束本轮任务后弹出“检测到障碍物，任务已中止”，运镜流程保持原样。

**Architecture:** TelemetryStore 新增 observeEvent，保留 observe 的相机返回契约。Session 同步回调每条任务/异常，NativeTaskStopEvidence 只归并诊断证据。Native.snapshot 观察真实终态和相机新鲜连续空闲后发布只读通知，Index 唯一 owner 弹一次 toast；任何控制决策都不读取诊断结果。

**Tech Stack:** ArkTS、Node18 测试、现有 HarmonyOS 签名构建。

**Spec:** ../specs/2026-11-12-task-exception-notice-design.md

## Constraints and Review Focus

- 仅 92→02、flags0、0A/39、10B、当前已观察前六字节零。0B 内部仍标候选，展示文案按用户指定。
- 同批回报中 exception→00 和 terminal→idle 不丢证据；回调异常不影响后续包/ACK。
- 本轮 Dolly 实际执行、首次终态 ±500ms；不会跨 start、session generation 或 flight generation 关联。
- 0B 不发 stop、不阻止/延迟/失败任何任务、不写业务执行标记。后退受阻后继续执行或继续录像，不显示中止提示。
- 通知需要任务终态仍新鲜有效，且不同相机空闲回报跨至少 500ms；该确认不进入流程门槛。相机逐条记录清理暂退/恢复录像，UI 节流不得吞掉恢复边沿。
- 发布ID和可见通知分别保存；同事件不重复弹/重发，通知最多保留 10s。
- App stop intent 先于 await 记录；未知原因不误标避障。

### Task 1: 纯证据类

**Files:** NativeTaskStopEvidence.ets，tests/native-task-stop-evidence.test.cjs。

- [x] RED：两实际 payload、清零覆盖、前后关联、时间/任务边界、App stop、未知码。
- [x] GREEN：begin/reset/observeTask/observeException/markAppStopRequested/snapshot，异常最多 8 条，首次终态固定；恢复执行隔离旧异常，跨恢复去重身份最多 32 条。20 组通过。

### Task 2: 接收和业务接线

**Files:** TelemetryStore.ets、DroneSession.ets、NativeTaskService.ets、TaskStopNotice.ets、AppController.ets、AssistantSheet.ets、Index.ets，tests/task-exception-observation.test.cjs、task-stop-notice-presenter.test.cjs。

- [x] RED：新增无诊断流程拦截/等待、后退受阻继续不提示、真实结束后提示、snapshot 间录制边沿、10s 过期不重发。
- [x] GREEN：逐条证据/日志、只读通知与 Index 去重 toast；AppController 对接入前差异仅监听及诊断观察，原全部运镜函数与原失败文案不变。
- [x] 独立 review 并修复提示计时、过期重发两项问题；79 项定向测试通过。

### Task 3: 验证和交付

- [x] 最终只通知修正版签名 HAP 放 D:/无人机demo/Neo2，116 个构建源文件及根目录包哈希匹配。
- [x] 完整业务测试及最终 diff 检查：779 通过，0 失败/跳过/取消；独立复查确认通知逻辑无流程等待、拦截或额外飞机命令。
- [x] 不自动安装或发布。

最终包使用 `Neo2-obstacle-notice-only-20261112.hap`，以与先前存在组合拦截的试验包区分。本地记录：`diagnostics/notification-only-final-core.log`、`notification-only-targeted-final.log`、`notice-lifecycle-red.log`。0B 完整枚举及实际提示仍待真机确认。

最终包 16,816,594 字节；SHA256 `7998791E4996FB0926CCAA80EC49321F3FC5D62FCF6A4FB8D47DD01906B7C4BC`，未安装。构建/包记录 `diagnostics/obstacle-notice-only-artifact-verification.json`。
