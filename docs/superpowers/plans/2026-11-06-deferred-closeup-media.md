# 特写组合末尾统一回传 Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development for independent media and presentation tasks, then review integration.

**Goal:** 修复组合在首步回传后进入环绕的复核失败，并按用户要求将全部录像回传移至所有动作结束后。

**Architecture:** CaptureMedia用私有编号绑定一份组合拍前基线，在组合期间推迟自动/手动取回；原生任务仍逐步验证实际结束与相机空闲。接力仅允许已封存首步的同一编号pending例外，最终统一取回基线之后的全部片段。失败/取消释放推迟状态后允许取回已完成部分，不删除原片。

**Tech Stack:** ArkTS、现有NativeTaskService/CaptureMedia、手机直连VLM及ArkUI。

**Spec:** 用户2026-11-06新要求“取回录像的环节放到所有动作都拍摄完毕后”；仍必须同一主体、默认2m Circle、不可在状态未知时启动后续运动。

## Evidence

PID46527，13:04:34.388启动Dolly；34.558短暂空框后34.670恢复11，未出现保护stop；44.631任务结束，45.650录像停；50.514恢复mode26并跟踪11；53.966回传45,095,790字节一段录像。界面错误为requireTarget的“原拍摄主体跟踪已丢失或变化，未启动后续运镜”，不同于上次“已请求停止当前运镜”。没有Circle准备或启动记录。说明本次停于首步回传后的单次图像/跟踪快照复核；记录不能证明实际换人，需补明确交接诊断。

## Global Constraints

- 不再在两步之间列目录或下载录像；第一步只等待真实执行结束、相机空闲和首步素材封存。
- 一个组合共用首次拍前baseline；第二步重置本步ready/recordingSeen/请求时间，不能覆盖baseline或丢掉先前片段。
- CaptureMedia接口：beginVideoSequence(token):Promise<number>；isVideoSequenceCurrent(id):boolean；canContinueVideoSequence(id):boolean；continueVideoSequence(id,token):void；finishVideoSequence(id,token):void；releaseVideoSequence(id):void。
- deferred序列不被readyKind自动取回，显式retrieveAll也拒绝；finish必须当前序列已ready，release为失败/取消的幂等释放，不制造就绪证据。
- 普通begin仍拒绝旧pending；handoff只有显式提供有效、同会话同代、首步ready的序列ID才能豁免pending，普通路径不放宽。
- 环绕前最多8秒等待已确认原ID恢复，并重取匹配的fresh frame/telemetry；明确新鲜其他跟踪ID立即拒绝；不猜号、不用旧图片充当新画面。
- 每个未采用观察及时finish，取消/降落/断连立即使等待失效，禁止自动重试运动启动。
- 原启动过渡1秒保护保持，终止任务的正常空框不按执行中失跟处理。
- 最终统一下载所有新片；失败/取消后可下载已拍部分，呈现明确未完成。
- 不安装、不发送真实飞行动作、不提交推送。

### Task 1: CaptureMedia序列归属

- [x] 先写defer/续接/结束/取消/旧ID/会话代变化测试，验证失败。
- [x] 实现序列API，保持普通拍照录像和媒体完整性检查不变。

### Task 2: 调度与呈现

- [x] finishDolly/finishCircle仅结束本步，新returnMedia阶段在两步完成后调用一次，失败后不得调用后续动作。
- [x] 修改方案/进度文案为末尾统一回传，保留部分结果和停止入口；更新相关测试。

### Task 3: Controller接力

- [x] 组合使用一次baseline，内部显式传递序列ID给startNativeWithCapture；只有sealed同组允许handoff。
- [x] 新鲜同ID观察复核允许有界重取，明确不同ID或超时拒绝；新增原因日志。
- [x] 第二步结束后finish序列并等待统一返回，异常finally release；部分素材不覆盖。
- [x] 更新接力控制器测试：中间无取回、最后一次取回、错人/取消/无实际结束/旧pending禁止、部分回传。

### Task 4: 验证

- [x] 完整测试、审查、签名构建，记录实际两步衔接仍须真机复测。

## 验证记录

最终230项测试通过，签名构建成功。新增和改写用例先红后绿，包括共享拍前目录、defer时自动/显式下载都拒绝、不能用markReady伪造封存、仅sealed正确票据允许handoff、续接清本步状态但保留baseline、reset后旧票据不释放新组、第二步未启动失败保留首段、释放后相机仍录制时不下载、baseline后取消清空无动作组、未知启动状态变化时保守保留、丢帧有界重取且每次finish、明显异ID立即拒绝、所有动作后仅一次统一回传。

只读审查未发现重要问题。另补保守cleanup用例：如果perform已经尝试而飞行上下文变化，不能仅凭native startedAt重置后的相等值discard；现仅未尝试start或上下文仍有效且startedAt未变时传discardUnstarted，CaptureMedia仍额外要求无任何录像/封存才清理。

安装包为diagnostics/closeup-final-return-signed.hap。本轮未覆盖安装、未发送飞行动作。最终需真机复核Dolly结束后mode15→mode26恢复、same-ID重取与Circle接力、两步素材完整性和统一回传效果；8秒内无法恢复原主体时会中止并释放部分回传。

## 真机反馈：首步启动前的状态同步竞态

安装后用户反馈滑动变焦也未启动。PID57610归档显示13:32:26.860选人回复，27.120被NativeTaskService入口ensureReady拦截；27.133同ID11跟踪已确认，但飞行模式仍为6，27.384才到26。没有模式重写或真正0x23/0x13启动ACK，说明尚未进入5秒settle或任务执行，和前两次失败位置不同。此前选人到start之间的媒体目录读取曾隐含提供等待时间，改为组合拍前基线后暴露了选人回报与飞行状态异步到达的问题。

修复在startAgentSubjectTask的选人成功后新增waitAgentTaskTargetReady：最多2秒，每50ms等待同ID跟踪≤500ms、fresh flight26且空中电机运转、fresh task0/0、fresh cameraIdle；每轮验证token/session/flight/control代和起飞归属，降落/移动/已有原生任务或明确其他ID立即拒绝。就绪立即返回，不固定睡眠；超时不启动。NativeTaskService的原始入口和settle校验完全保留，单独选人语义不变。

集成测试先红后绿，覆盖跟踪先到/模式后到仅启动一次、其他ID拒绝、等待期间取消、一直mode6超时、session/flight/control/ownership变化、已就绪首快照直接通过。两项旧原生任务测试的mock补齐实际必需的takeoffSent、task/camera新鲜度和跟踪时间。最终236项测试全部通过，签名构建成功，只读复查未发现重要问题。修正版为diagnostics/closeup-start-ready-signed.hap，未安装，仍需真机复测真正Dolly启动及后续Circle接力。
