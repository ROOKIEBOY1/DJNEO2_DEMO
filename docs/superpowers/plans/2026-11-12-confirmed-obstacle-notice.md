# Confirmed Obstacle Notice Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development or superpowers:executing-plans; test new behavior RED then GREEN.

**Goal:** 按官方已恢复的原因映射补齐提示，保持所有运动/组合/下载控制流程原样；不在仍前进返程时弹“任务已中止”。

**Architecture:** 严格解析0A/5A导航及0A/39活动状态，逐条观察FC速度/模式。原因类只确认本轮QuickShot退出原因；独立只读通知状态机保留候选到返程结束且速度近零、各状态稳定后，交现有单owner UI toast。通知不参与任何控制决策。

**Evidence:** `diagnostics/djifly-reverse-20261112/obstacle-diagnostic-conclusion.json`、`fc-osd-speed-field-verification.json`、`navigation-5a-enum-values.json`。0B=QM_OBSTACLE_AVOID→800013，官方gate为Mode8 OR MultiQuickShotEnabled。0A/5A byte13bit0为MultiQuickShotEnabled，不能改称执行；QuickShotInAction来自0A/39 byte9。FC18/20/22为有符号int16 ×0.1 m/s。

## Constraints

- 消息按用户指定：“检测到障碍物，任务已中止”。
- 原因需本轮Dolly/Circle真实执行、异常前已收到fresh官方导航gate、终态±500ms，App停止不归因；原码与上下文保留。
- 单独避障回报不等于整段运动停止。发布需最新task/camera idle、导航不处于QuickShot/GoHome活动、QuickShot最后action清零、fresh FC6/26或落地停桨且三轴速度每轴abs≤0.3m/s；用新task/nav/flight/camera回报最小时间跨500ms确认。
- SmartEye（NavMode1）允许主体保持启用，但需近静止速度；UNKNOWN、失鲜/未来回报或任一active短脉冲不能通过确认。
- 500ms和速度阈值是保守通知策略，不进入起飞、移动、任务、衔接或下载成功条件。
- pending跨正常completeForHover保留最多30s，新任务/主动控制/会话/飞行轮次取消；已发布通知10s且不重发。
- 不自动安装或触发飞行，不自动提交Github。先提供HAP再完成余下验证。

## Tasks

- [x] 只读复核正式协议/枚举/速度字段，并提取真实正常、避障、手停raw fixture（经纬度已删改）。
- [x] 原因类导航gate、Dolly/Circle及正式分类RED→GREEN（独立agent拥有Evidence和其测试）。
- [x] Store/Session严格逐条导航/flight/action接线，保留相机观察API契约；定向RED→GREEN。
- [x] 独立通知类RED→GREEN，per-frame撤销稳定窗、epoch/新任务/时限去重，不依赖控制。
- [x] Service/UI接线，真实raw避障到返程结束提示；正常/手停/缺导航/仍执行/仍返程不提示；旧三轮日志无导航不补造。
- [x] 独立review、签名HAP及源一致性核对、完整业务回归，记录结果。

## Verification and delivery

- 正式原因分类33项、导航/速度解析3项、独立通知16项、接收/UI接线20项、真实raw端到端4项均通过。完整业务回归820项全部通过，无跳过。
- 两次真实避障回放首弹分别位于首次终态后8165ms、6453ms，均发生在原始抓包窗口内；一轮在首次终态后清理原任务状态，仍保留待通知原因。正常和手动停止对照无提示。测试末尾800ms重放明确作为synthetic extension，仅检查不重发，不用于建立原因或首次弹窗。
- 独立复核发现并修复公开取消后的迟到提示，以及仅准备下一任务就提前清候选两处边界；各自先RED后GREEN。公开cancel抑制后续旧报告重建，内部交接保留候选。
- 签名HAP：`Neo2-confirmed-obstacle-notice-20261112.hap`，16850858字节，SHA256 `670C80C711A041D11A14606578D8605531F33EEF7D7A71AAD8B8FE0DE10697AB`。
- 117份源码逐文件哈希及构建目录文件数一致；包内原生视频库SHA256 `1409021AAF54BDB59073538192461C8A346519FC321C56A6C897E232EA0E986E`，本次未修改原生解码代码。
- 记录：`diagnostics/confirmed-obstacle-final-full-core.log`、`confirmed-obstacle-notice-integration.log`、`confirmed-obstacle-notice-final-20261112-build.log`、`confirmed-obstacle-artifact-verification.json`。未安装或操作飞机；真机复测尚待用户进行。
