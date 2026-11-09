# 室外组合拍摄误停与图传停滞排查

## 证据

已只读拉取手机最近40份hilog归档，覆盖2026-11-06 16:27–16:56；Neo相关记录位于diagnostics/outdoor-closeup-archives.log和outdoor-closeup-summary.log。归档二进制参数已按变长编码、signed zigzag还原，不把压缩参数字节当文字。

- 16:27:24.211 Dolly停录，24.714派生跟踪false，25.603本地保护发送stop；25.845同ID11恢复，25.969飞行模式26。
- 16:29:21.412停录，22.643跟踪false，23.572本地stop；23.899同ID12恢复。
- 16:33:49.959 Dolly真实结束并封存；50.180交接新画面同ID11确认，50.963 Circle启动。16:34:16.110 Circle执行、录像true、派生跟踪false，16.949本地stop；17.394同ID11恢复。
- 16:37:41.985 Dolly停录，43.376跟踪false，44.258本地stop；44.499同ID11恢复。

三次Dolly失败都在真实任务仍050d000100/模式37的原生收尾时段；Circle一次发生于录像true的执行期。错误来自waitForCloseupStep，不是8秒的waitForCloseupTarget交接等待。

原厂自动完成记录开发基地1/captures/dolly-zoom-20261102-142901.duml.subjects.jsonl：两个正常末段分别持续2.466秒和3.321秒0a95空框后才有0000000102终态，随后同ID恢复；用当前真实SubjectObservation和CloseupSubjectGuard以100ms轮询回放，会分别提前1469ms和2329ms误stop。原PC启动前严格确认同ID，运行期以任务终态为准，未把缺少tracking_box_candidate当已证实失锁。

图传另有独立故障：进程48395在16:29:07.263先出现解码停滞，约16秒后才有主体保护中止。16:29:10至30组帧从1354增长到1955，decoded/rendered一直686，到35秒才恢复；输入视频仍在来，不能等同Wi-Fi全断。另一个没有停滞的进程同样触发主体保护，两条故障不能混为一个因果链。

## 修正边界

1. 原生任务执行期：可显示跟踪框缺报为unknown，不生成同ID证据，不将其直接判成另一个人。新鲜明确他ID仍立即停止。启动及Circle交接保持原来的新鲜同ID、500ms与新画面检查；仍只在真实任务终态并录像封存后衔接，不能以camera false猜任务已完成（Dolly本来有两轮录像）。
2. 保留原有取消/降落/回中/断连协作；补最长等待截止时current且原生仍活动的显式stop与未确认错误处理。可靠链路整体失鲜时的既有退出策略本轮不扩展，以免在独立问题里改动飞行控制并发；该既有路径目前仅退出wait，不独立确认native stop，已记录待单独设计。
3. 解码错误首次触发原因旧日志尚不能确定。修正“恢复后故障计数从不清零”的独立缺陷：连续故障仍限3次，至少5秒持续有效送显且相邻帧间隔不超过1秒才清连续失败计数，单一偶发输出不重置。不改2500ms判定，不复用跨代参数，不在空中自动发实验指令。
4. 原PC空负载camera 02/b3关键帧请求来自SDK逆向，但原工具明确地面门槛且Neo2支持未确认。本轮未发送，也不把它直接接到空中自动恢复。
5. 增加恢复事件/codec epoch/参数mask/IRAP接收与接受/submit/decoded/等待关键帧/连续故障/暂停原因；App侧5秒只读诊断关联UDP、组帧、视频年龄与250ms轮询最大延迟，以供下一次复现区分无码流、缺IRAP、参数变化、硬解阻塞或主线程积压。

## 进度

已完成原厂回放回归与guard修正、纯Native恢复策略测试与诊断，独立只读复核通过。两段原厂真实类回放从RED到GREEN，分别覆盖真实TelemetryStore/NativeTaskService/CaptureMedia与waitForCloseupStep，真实terminal和封存前不返回。额外覆盖Circle录像中缺框、明确他ID、超时停止已回复/未确认、截止取消不竞争、终态未封存不重复stop、候选或旧同ID不得进入交接。

主代理最终验证：全核心300/300通过（21.720秒，含嵌套11项）、纯C++视频恢复策略实际执行通过、git diff --check通过、完整API21签名构建成功（24.487秒）。Native日志锁与跨codec输出句柄已复核。安装包diagnostics/outdoor-closeup-fix-signed.hap，同时包含此前宽度对齐与“飞行任务执行中”标题修改。

首次解码停滞触发原因仍待新版实际复现日志确认；本次不声称已验证室外画面连续恢复。未发送任何飞行或相机实验命令。

2026-11-09用户要求安装：HDC已覆盖安装diagnostics/outdoor-closeup-fix-signed.hap，返回install bundle successfully。包11,050,673字节，SHA256 C6E86C6968887CE85C457427E93E3A467686FA3589A30FA5B41D519841FFFE8C。aa start成功，随后系统任务列表显示App在后台，未声称本次看到了前台界面或完成实飞复测。
