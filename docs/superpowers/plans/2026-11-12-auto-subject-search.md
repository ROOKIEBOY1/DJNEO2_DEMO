# Automatic Subject Search Implementation Plan

**Goal:** 将现有自转、取帧和VLM选人组成有界闭环，固定同方向2秒，命中后保留原任务并等待用户确认。

**Spec:** ../specs/2026-11-12-auto-subject-search-design.md

**Architecture:** 新纯编排器拥有搜索生命周期；subject_selection协议显式区分not_found/ambiguous；AppController适配现有FlightCommandService、取帧与跟踪确认；SubjectTaskWorkflow与UI沿用。

## Tasks

- [x] 纯编排器与离线回放：AutoSubjectSearch.ets及tests/auto-subject-search.test.cjs。端口isCurrent/inspect/turn/settle，固定2秒、最多8段、120秒，歧义复核、取消、异常和迟到回调。
- [x] 选人协议：AgentAction/DeepSeekPayload支持subject_selection none.selectionStatus，仅not_found允许搜索继续；其他阶段拒绝该字段。覆盖协议、参数冻结、兼容旧none及提示词。
- [x] Controller接线：搜索准备、互斥、普通悬停/已跟踪退出、逐轮新帧与候选复核、转向2秒+回中等待、命中复用原有确认。旧候选等待竞态与取消路径回归。
- [x] 独立代码复核、定向离线验证、签名HAP与源码一致性；先给HAP后收尾完整业务回归，不自动安装或飞行。

## Rulings

- 沿用当前工作目录及未提交修改，不新建checkout、不提交或推送，避免丢失前面已交付的避障文案。
- 同方向默认turn_left，复用既有原地自转习惯；没有航向反馈，不以2秒推定固定转角。
- 不新增首次选人之外的用户操作；歧义和故障与真实未找到分流。
- 用户此前“不测试”针对改文案；本次新增运动编排使用必要离线回归，不操作设备。先交HAP的偏好持续有效。

## Implementation and verification

- 纯编排器38项、Controller闭环13项、Flight所有权5项、选人状态/desktop parity8项、云请求预算2项新增回归；完整业务886项全部通过、无跳过。记录：`diagnostics/auto-subject-search-full-core-verified.log`。
- 独立复核通过。补齐movementOwner/generation/session/token隔离：旧转向回调不得回中新会话/新动作，也不清新动作busy；正常取消与断链仍回中。相应旧连续运动测试仅更新已失效owner的回中预期。
- 保留初次inferred目标的生命周期及候选校验，不因旧ID消失再盲选其他候选。扫描屏障后仅空候选再poll，避免对已就绪画面重复准备。缺帧时间、跨session、候选时间差超200ms、停稳前旧帧与decoder epoch变化均拒绝。
- 旧测试冻结Date.now处同步推进定时器；参数/媒体专测只替代其原本未覆盖的停稳端口，保留全部任务确认和媒体票据断言；实际停稳/转向/取消由Controller真实路径回放覆盖。
- 最终交付：`Neo2-auto-subject-search-20261112.hap`，16890524字节，SHA256 `8561938F89CE36F649BE4BB5A89800A62E9D0957DA7BD18715859C58132314F0`。118份源码逐项哈希、构建文件总数及交付包哈希一致。
- 原生视频库SHA256仍为`1409021AAF54BDB59073538192461C8A346519FC321C56A6C897E232EA0E986E`；本次不改解码层。
- 构建记录`diagnostics/auto-subject-search-delivery-20261112-build.log`；交付校验`diagnostics/auto-subject-search-artifact-verification.json`。未安装或操作飞机。实际2秒转幅、停稳及现场识别效果等待真机复测。
