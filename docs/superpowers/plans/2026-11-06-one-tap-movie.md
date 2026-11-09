# 一键成片 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在手机内将本次所有原片合成带Titan配乐和淡入淡出的真实MP4，并在当前对话预览及保存。

**Architecture:** ArkTS独立剪辑状态机负责不可变素材组、去重、进度、取消及结果；Native工作线程负责视频探测/解码/逐帧处理/硬件编码与封装。配乐模块把官方Titan解码为PCM、循环和淡入淡出、编码AAC，供同一影片封装器写入。

**Tech Stack:** ArkTS、C++17、API21 AVSource/AVDemuxer/VideoCodec/AudioCodec/AVMuxer、现有GalleryVideoReceiver。

**Spec:** docs/superpowers/specs/2026-11-06-one-tap-movie-design.md

## Global Constraints

- 本地生成，保留全部原片和顺序，不上传录像，不改动飞行流程。
- 最高1080p/30fps，MP4/H.264/AAC，保留原比例；视频头尾0.6秒、配乐头尾1秒淡入淡出。
- 固定Titan，界面/文件授权信息及作品末尾和metadata保留署名。
- 组合只有completed且全量回传完成才允许完整成片；部分素材仍可播放保存。
- 用户已要求直接执行；复用当前包含大量已验证未提交工作的工作区，不切换分支、不自动提交或推送，不再次请求方案确认。

## Review Focus

- 旧异步导出不得覆盖新素材组，重复点击不得启动第二个并行导出。
- 取消/失败不能覆盖、删除原片或影响飞机控制；未封装完成不能当成品。
- 不同尺寸/方向、解码stride和短视频淡入淡出不能导致越界、变形或黑片。
- BGM循环边界、真实音频格式、AAC配置和视频尾部必须真实可播放。
- 保存授权取消可重试，原片与成片的保存目标必须明确区分。

### Task 1: 音乐与Native音轨

**Files:** Create MovieAudio.h/.cpp、resources/rawfile/titan.mp3、THIRD_PARTY_NOTICES.md；Test Native纯PCM淡入淡出/循环测试。

**Interfaces:** namespace neo::movie；MusicTrack BuildMusicTrack(const std::string &musicPath, int64_t durationUs, const std::atomic_bool &cancelled, const std::function<void(double)> &progress)。MusicTrack持有shared_ptr<OH_AVFormat> format和vector<AudioSample> samples；AudioSample含vector<uint8_t> bytes及OH_AVCodecBufferAttr attr。

- [ ] 核验官方授权和音源，下载并记录来源、hash和署名。
- [ ] 先测试PCM循环、极短音轨淡入淡出和取消，再实现MP3解码、48k立体声S16归一化和AAC编码；资源RAII释放。
- [ ] 编译真实SDK，进度真实、无静默无配乐降级。

### Task 2: Native影片导出器

**Files:** Create MovieExport.h/.cpp、MovieFrames.h/.cpp；Modify CMakeLists.txt、VideoPreview.cpp Init注册、types/libneovideo/index.d.ts；Test tests/native/movie_*。

**Interfaces:** startMovieExport(sources:string[], outputPath:string, musicPath:string):number；movieExportSnapshot(id:number):{id,stage,progress,durationMs,error,outputPath}；cancelMovieExport(id:number):void。stage为probing/rendering/finalizing/completed/failed/cancelled。

- [ ] 先测试帧比例/旋转/黑色淡入淡出/时间线纯算法，再实现有界逐帧处理与编码。首版采用缓冲区CPU处理，保证正确后依据真机耗时优化，不引入FFmpeg依赖。
- [ ] 探测本次最多8段真实视频，逐段完整解码、连续时间戳、保留比例、最高1080p30、头尾淡入淡出；视频原声替换为Task1音轨。
- [ ] 一个后台导出worker，不阻塞UI。输出新文件，取消与异常清临时文件；muxer Stop及文件检验成功才完成，加入Titan署名metadata和末尾简短可见署名。
- [ ] 使用API21头文件编译；真实样本验证实际输出音视频轨、方向、总时长、淡入淡出及取消。

### Task 3: ArkTS状态与成片闭环

**Files:** Create core/media/MovieComposer.ets、core/platform/NativeMovieExport.ets；Modify AppController.ets、AssistantSheet.ets；Test tests/movie-composer.test.cjs、movie-controller.test.cjs。

**Interfaces:** MovieComposer持有port.start/snapshot/cancel，start(sources,outputDirectory,musicPath)、cancel()、snapshot()；task key包含不可变源列表与模板版本。AppController提供composeMovie(context)、cancelMovie()、saveMovieToGallery(context)和snapshot.movie；不复用飞行busy或取消令牌。

- [ ] 先测重复点击、旧组返回、新组隔离、取消待完成、完成验证、重试、断连后本地播放。
- [ ] rawfile音乐复制到App私有目录，启动Native后台导出并250ms轮询；缓存结果清单仅恢复已存在且完成的作品。
- [ ] 接入真实“一键成片”，展示阶段/真实进度、可取消、成片/原片切换；成片模式保存单成片，原片模式保留组保存；音乐署名可复制。
- [ ] 关闭大框只停止播放，不取消合成；现有语音/飞行入口保持可用。

### Task 4: 构建与验证

- [ ] 运行核心测试、Native算法测试和git diff --check。
- [ ] 完整签名构建，输出diagnostics/one-tap-movie-signed.hap。
- [ ] 只读审查状态隔离、文件安全、音视频尾部及资源释放，修复阻断项。
- [ ] 设备若可用先做不发飞行指令的真实素材离线导出测试；未经要求不自动覆盖安装正式应用。记录已测范围与尚需用户实测项，不把构建通过描述成画面效果验证通过。

## Execution ledger

- 2026-11-06: 用户明确要求直接执行并指定Titan。沿用当前checkout；不提交已有未提交改动。并行实现独立Native视频/音频及ArkTS调度，接口以上述声明为准。
- 实现完成：MovieComposer、完整视频与音频Native管线、真实按钮/进度/取消/原片成片切换/单成片保存和本地完成缓存。加入官方Titan及授权记录。每帧处理源码在debug演示包也启用O2，不改变原图传模块编译选项。
- 审查修正：music准备A→B→A异步失效、旧取消结束恢复新组缓存、空对话显示恢复作品、自动重连保留已开始/完成的有效本地成片；保留旧原片保存跨会话回归语义。Native分别验证两轨实际包和EOS覆盖，源PTS异常不静默截掉1秒，AAC提前EOS/缺包不得报告完成。
- 本机验证：核心测试284/284通过；真实执行C++帧/时间线42项与音频26组夹具检查通过；API21 Native严格编译通过；git diff --check通过。完整签名构建成功（23.847秒）。正式HAP不含NeoMovieTest离线入口；独立验证HAP含不初始化AppRuntime/不连接飞机的自动测试入口。
- 正式包：diagnostics/one-tap-movie-signed.hap，10,991,821字节，SHA256 B7B6C3C6AFD280CB39FCB2D3C44B7561E869853EDA0788C3DB63493160A6E096。
- 离线验证包：diagnostics/one-tap-movie-verification-signed.hap，10,548,056字节，SHA256 68A945EE5372342635B6965CFF3F410C8018081F8A2C4B9FA04204EDB36D1134。只读取手机现有0155/0156两段原片并本地合成、自动播放，不启动飞行控制。
- 真素材探测：手机0155/0156原片均3840×2160、HEVC Main8bit4:2:0、BT709，无音轨，附djmd/dbgi元数据轨会忽略；时长4.871533秒/6.2062秒，146/186帧。预计生成334帧/11.133333秒，帧级取整共增加约55.6毫秒。仅探测容器参数，不声称已真机完成编解码或看到效果。
- 待安装验证：已向用户请求确认飞机落地停桨、手机解锁后，安装离线验证包跑真实编解码和播放，再恢复正式包。未获回复前不覆盖手机；系统拒绝shell直接执行上传的Native测试程序，未尝试绕过。

## 2026-11-09 真机失败定位与修复

- 历史日志确认11月6日15:43:23/26两次失败均为 `Music: AAC encoder produced discontinuous timestamps`。本次在用户确认落地停桨、允许离线测试后，用手机原有0155/0156两段原片复现，不初始化飞行控制。
- AAC目标11133333µs、534400个PCM帧，需要522个访问单元。手机输出前522包连续，随后两个额外收尾包中出现42666µs间隔；旧逻辑在裁掉超时长数据前先校验，误拒完整音轨。新增TrackTimeline严格验证目标前缀，前缀齐全后只排空、检查尾包格式，不把补齐数据写入MP4；EOS、提交帧数、真实包数与尾部覆盖检查保留。本轮保持原首包PTS归零策略，没有另行重做AAC预热对齐。
- 真机完整测试进一步定位并修正：MP3解码的正常PCM透传flags=10，被错误过滤为纯配置数据；改为读取经过布局与内存检查的非空PCM，并检查解码总时长最多偏差一个MP3帧。修复前仅1152帧静音；修复后7754112帧、44100Hz、peak32450、meanAbs4495，源时长175804082µs、解码175830204µs。
- H.264硬件输出格式未提供MIME，导致AddTrack返回3；补充实际固定编码器的video/avc标识。收到EOS后不再查询下一输出；仅当全部输入画面已写完且EOS时间等于提交结束时间时，忽略设备保留非零size的单独结束标记，避免多计一帧。末帧与EOS合包、欠帧失败及缓冲释放逻辑保留。
- 成片重开验证修复两处误判：解复用flags=10的首关键帧属于媒体样本，必须计入时间线；同一解复用器逐轨读完后需要选轨并SeekToTime(0)，否则第二轨从全局EOF开始。首帧、间隔、数量、EOS和两轨尾覆盖阈值均未放宽。
- 回归证据：原Timeline重放真实522+2包序列退出27（RED）；新TrackTimeline及其他音频边界41组通过（GREEN）。完整核心测试300/300通过；Native画面算法和图传恢复测试通过；完整签名构建通过，git diff --check通过。
- 真机最终验证：`diagnostics/movie-phone-09-success.log`，PID31506。09:36:01成片completed，耗时17559ms；视频334帧、音频522包从0开始读至EOS，09:36:02播放器准备完成，09:36:13播放结束，无PLAYER_ERROR。成片时长11133ms、1920×1080，输出位于手机私有目录的neo_movie_verify_1794188143866.mp4。
- 正式包：`diagnostics/one-tap-movie-aac-fix-signed.hap`，11043873字节，SHA256 `5B6CD4D6E79668B141A1B9FDED5EF6C371705A123C95D5C9494BFE78B413BCEA`。与测试包Native库SHA256均为 `0C9709E41A0AD24B71FDAF135AD245844D27CE136DACAFC0E495303B2E13341C`；正式字节码不含NeoMovieTest入口。已覆盖恢复正式App并成功启动，未提交或推送Git。
