# 自动寻人停稳后取新帧修复

## 现场与根因

用户报告“寻人未取得本次停稳后的有效帧”。读取当前USB手机HiLog及530–534归档，保留于`diagnostics/search-frame-archives-20261112`及`search-frame-latest-20261112.log`，未操作飞机。

16:34:15.873开始首轮识别，ticket2在15.985已提供921600字节RGBA，16.032失败；16:34:55.086第二次首轮识别，ticket4在55.219提供RGBA，55.280失败。两次还未自转，decoder epoch保持1，没有未附图像错误。

Native RequestFrame只替换ticket，不建立最小帧时间；FrameDecoder.Pump先读取已排队的输出，只限制年龄180ms，故可合法返回请求前的缓冲帧。寻人层要求帧时间不早于刚结束的settledAt，收到第一张旧帧立即失败，没有继续等新帧。日志未打印实际capturedAt/settledAt，无法直接断定命中哪条比较；源码与现场最集中指向这个边界。

时间戳整数检查没有问题：C++为int64 epoch毫秒，候选来自Date.now。保留安全整数、会话、候选200ms匹配与decoder epoch检查。

## 最小修复

- [x] 在captureAgentObservation/captureVlmFrame透传最小允许capturedAt及当前搜索有效性回调。
- [x] 同一600ms或更短外部deadline内，丢弃停稳前帧并换ticket继续等；旧帧不编码JPEG，不进入VLM，不触发旋转。
- [x] 等待及编码前后复核取消、会话/decoder epoch；有效新帧仍使用时间匹配的候选，不放宽旧帧门槛。
- [x] 增加诊断：帧时间、停稳时间、差值、候选时间、session、epoch及明确拒绝原因；严格取帧错误保留具体提示。
- [x] 离线回归、签名构建，先交autoSearchV1.hap，再完成必要收尾验证；不安装或飞行。

## 命名约定

用户要求自动寻人HAP使用`autoSearchV<N>.hap`，本次从`autoSearchV1.hap`开始，后续版本数字递增；不再以日期长文件名交付自动寻人包。

## 验证与交付

- 独立回归先RED：模拟停稳时间10000ms，旧实现返回9930ms队列帧。修复后7项新回归全部通过，覆盖续票等新帧、600/97ms预算、取消、会话/解码轮次变化、默认调用兼容及参数透传。日志`diagnostics/search-fresh-frame-red.log`、`search-fresh-frame-green.log`。
- 相关57项通过；完整893项通过，无跳过。完整记录`diagnostics/autoSearchV1-full-core.log`。独立只读复核通过。
- `autoSearchV1.hap`，16898752字节，SHA256 `FCD708EF6C6A4D10874477A92A452445AB18FA3B4CAE5AD226B515E03579ED60`。118份源码哈希及构建文件数一致，包内原生视频库仍为`1409021AAF54BDB59073538192461C8A346519FC321C56A6C897E232EA0E986E`。
- 当前仅修复ArkTS取帧衔接，没有修改C++、安装App或发出飞行命令。现场根因仍需用新增帧时间DFX复核，真机效果等待用户复测。
