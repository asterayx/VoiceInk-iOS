# VoiceInk iOS - 架构设计与功能分析文档

## 1. 项目概述

VoiceInk 是一款 iOS 语音转文字应用，核心功能是将语音录音实时转录为文本，并支持 AI 增强处理和多语言翻译。应用包含两个目标（Target）：

- **VoiceInk-ios**：主应用，提供录音、转录、翻译、笔记管理的完整体验
- **VoiceInkKeyboard**：键盘扩展，允许用户在任意应用中通过自定义键盘触发语音录入

**技术栈：** Swift / SwiftUI / SwiftData / whisper.cpp / llama.cpp / Google ML Kit / KeyboardKit

**最低部署版本：** iOS 17.0

---

## 2. 整体架构

```
┌─────────────────────────────────────────────────────────────────┐
│                        VoiceInk 主应用                          │
│                                                                 │
│  ┌───────────┐   ┌───────────────┐   ┌───────────────────────┐ │
│  │   Views    │──▶│   Services    │──▶│   Native Libraries    │ │
│  │ (SwiftUI)  │   │  (业务逻辑)    │   │ (whisper.cpp/llama)  │ │
│  └───────────┘   └───────────────┘   └───────────────────────┘ │
│        │               │                       │                │
│        ▼               ▼                       ▼                │
│  ┌───────────┐   ┌───────────────┐   ┌───────────────────────┐ │
│  │  Models   │   │  Utilities    │   │   Cloud APIs          │ │
│  │(SwiftData)│   │ (工具/日志)    │   │(Groq/OpenAI/Deepgram)│ │
│  └───────────┘   └───────────────┘   └───────────────────────┘ │
│                          │                                      │
│                          ▼                                      │
│              ┌───────────────────────┐                          │
│              │  AppGroupCoordinator  │◀─── Darwin Notifications │
│              │   (进程间通信中枢)     │◀─── App Group Defaults   │
│              └───────────────────────┘                          │
└──────────────────────────┬──────────────────────────────────────┘
                           │
              App Group (共享 UserDefaults)
              Darwin Notifications (实时信号)
              URL Scheme (voiceink://)
                           │
┌──────────────────────────▼──────────────────────────────────────┐
│                    VoiceInkKeyboard 键盘扩展                     │
│                                                                 │
│  ┌──────────────────────────────────────┐                       │
│  │      KeyboardViewController          │                       │
│  │  ├─ 录音按钮 (Idle/Recording/Activate)│                       │
│  │  ├─ 状态轮询 (0.5s)                   │                       │
│  │  └─ 文本插入 (逐词)                    │                       │
│  └──────────────────────────────────────┘                       │
└─────────────────────────────────────────────────────────────────┘
```

---

## 3. 目录结构

```
VoiceInk-ios/
├── VoiceInk_iosApp.swift          # 应用入口, URL Scheme 处理
├── AppGroupCoordinator.swift      # 主应用⇔键盘扩展 进程间通信
├── LibWhisper.swift               # whisper.cpp Swift 封装 (Actor)
├── LibLlama.swift                 # llama.cpp Swift 封装 (Actor)
│
├── Models/                        # 数据模型层
│   ├── Transcription.swift        #   转录记录 (SwiftData @Model)
│   ├── Mode.swift                 #   录音模式配置
│   ├── Provider.swift             #   服务提供商枚举
│   ├── PromptTemplate.swift       #   AI 后处理提示词模板
│   └── LanguageConfiguration.swift#   语言配置 + 40+ 语言支持
│
├── Services/                      # 业务服务层
│   ├── RecordingManager.swift     #   录音流程编排 (状态机)
│   ├── AudioRecorder.swift        #   音频录制 (WAV 16kHz mono)
│   ├── AudioPlayer.swift          #   音频回放
│   ├── AudioSessionManager.swift  #   AVAudioSession 生命周期
│   ├── TranscriptionOrchestrator.swift  # 转录→增强→翻译 流水线
│   ├── TranscriptionServiceFactory.swift# 转录服务工厂
│   ├── WhisperTranscriptionService.swift# 本地 Whisper 转录
│   ├── GroqTranscriptionService.swift   # Groq/OpenAI/Cerebras API 转录
│   ├── DeepgramTranscriptionService.swift# Deepgram API 转录
│   ├── LLMPostProcessor.swift     #   LLM 文本后处理/纠错
│   ├── TranslationService.swift   #   翻译 (ML Kit → LLM 降级)
│   ├── TranscriptionRetryService.swift  # 重试/重新翻译
│   ├── LanguageDetectionService.swift   # 语言检测 (词频启发式)
│   ├── TextCleaningService.swift  #   文本清理 (正则)
│   ├── SpeechSynthesisService.swift#   文本转语音 (TTS)
│   ├── ClipboardService.swift     #   剪贴板 + Toast 通知
│   ├── NotificationManager.swift  #   本地通知 (键盘模式)
│   ├── OpenAICompatibleClient.swift#   通用 OpenAI 兼容 API 客户端
│   ├── AppSettings.swift          #   全局设置门面 (Facade)
│   ├── APIKeyManager.swift        #   API 密钥安全存储
│   ├── ModeManager.swift          #   模式管理 (防抖持久化)
│   ├── LocalModelManager.swift    #   本地模型下载/管理
│   └── VADModelManager.swift      #   VAD 模型路径管理
│
├── Views/                         # 视图层 (SwiftUI)
│   ├── ContentView.swift          #   根视图
│   ├── NotesListView.swift        #   主界面 - 笔记列表 + 录音
│   ├── NoteRowView.swift          #   单条笔记行
│   ├── NoteDetailView.swift       #   笔记详情 + 音频播放
│   ├── RecordingSheetView.swift   #   录音中界面 (计时/模式/停止)
│   ├── SettingsView.swift         #   设置主页
│   ├── ModeConfigurationView.swift#   模式创建/编辑
│   ├── ModesView.swift            #   模式列表
│   ├── ModeSelectionView.swift    #   快速模式切换
│   ├── OnboardingView.swift       #   新用户引导 (3步)
│   ├── APIKeysView.swift          #   API 密钥管理列表
│   ├── ProviderAPIKeyView.swift   #   单个提供商密钥输入/验证
│   ├── LanguageSelectionView.swift#   语言选择器
│   ├── LocalModelManagementView.swift # 本地模型管理
│   ├── AudioVisualizerView.swift  #   音频波形可视化
│   ├── AudioPlayerView.swift      #   音频播放器控件
│   ├── ProcessingView.swift       #   处理中遮罩
│   └── ToastView.swift            #   Toast 通知组件
│
├── Utilities/                     # 工具层
│   ├── Logger.swift               #   日志 (DEBUG print / RELEASE os_log)
│   ├── KeychainService.swift      #   Keychain 安全存储
│   ├── RiffWaveUtils.swift        #   WAV 文件解码 → Float 采样
│   ├── ViewUtilities.swift        #   UI 工具 (格式化/剪贴板/Spinner)
│   └── DefaultModeManager.swift   #   首次启动默认模式创建
│
└── Resources/                     # 资源文件

VoiceInkKeyboard/
└── KeyboardViewController.swift   # 键盘扩展控制器
```

---

## 4. 核心功能模块详解

### 4.1 语音录制

| 组件 | 职责 |
|------|------|
| `RecordingManager` | 录音流程状态机，管理权限检查、启动/停止/取消、键盘扩展回调 |
| `AudioRecorder` | 底层录音，输出 16kHz 单声道 WAV（Whisper 兼容格式），环形缓冲区管理音频电平 |
| `AudioSessionManager` | AVAudioSession 激活/延迟停用，重试逻辑，键盘扩展模式超时 |

**录音状态机：**
```
idle → requestingPermission → recording → processing → idle
                                  ↓
                              cancelled → idle
```

**关键设计决策：**
- WAV 格式 16kHz mono 直接适配 Whisper 输入要求
- 环形缓冲区（pre-allocated）避免录音期间内存分配
- 串行 DispatchQueue 保证状态转换的原子性
- 最多保留最近 10 条录音文件，自动清理旧文件

### 4.2 语音转文字（转录）

应用支持**本地转录**和**云端转录**两种模式，通过工厂模式统一接口：

```
TranscriptionService (Protocol)
├── WhisperTranscriptionService   # 本地: whisper.cpp + Core ML + Metal GPU
├── GroqTranscriptionService      # 云端: Groq / OpenAI / Cerebras / Gemini API
└── DeepgramTranscriptionService  # 云端: Deepgram Nova API
```

**TranscriptionServiceFactory** 根据 `Provider` 枚举返回对应实例。

**本地转录 (WhisperContext):**
- 基于 whisper.cpp 的 Actor 封装，保证线程安全
- 支持 Metal GPU 加速，CPU 自动降级
- 可选 Core ML 编码器加速
- VAD (Voice Activity Detection) 语音活动检测
- 支持英语/西班牙语检测，温度参数自适应（西班牙语 0.0 保守，英语 0.2）
- 线程数：`min(8, max(1, cpuCount - 2))`

**云端转录:**
- OpenAI 兼容协议（Multipart form-data 上传音频）
- Deepgram 独立协议（Query 参数 + 音频 Body）
- 均实现 API Key 验证方法

### 4.3 AI 文本后处理

`LLMPostProcessor` 通过 `OpenAICompatibleClient` 调用云端 LLM 对转录文本进行增强：

- **自定义后处理：** 用户通过 PromptTemplate 定义提示词（摘要/要点/重写/清理/自定义）
- **自动纠错：** 基于语言特征的发音纠错（如中文拼音→汉字、西班牙语重音）
- **支持的 LLM 提供商：** Groq (Llama)、OpenAI (GPT-4o)、Cerebras (Llama)、Gemini

### 4.4 翻译

`TranslationService` 实现两级降级策略：

```
ML Kit 本地翻译 (5s 超时)
        │ 失败
        ▼
LLM API 云端翻译 (15s 超时)
```

- Google ML Kit 提供离线设备端翻译
- 失败时自动降级到 LLM API 翻译
- 语言对缓存避免重复初始化

### 4.5 转录编排流水线

`TranscriptionOrchestrator` 管理完整的 **录音 → 转录 → 增强 → 翻译** 流程：

```
音频文件
   ↓
1. 转录 (TranscriptionService)
   ↓
2. 文本清理 (TextCleaningService, 正则)
   ↓
3. 语言检测 (LanguageDetectionService, 词频)
   ↓                           ↓
4a. LLM 后处理 (可选)     4b. 翻译 (并行启动)
   ↓                           ↓
5. 存储 SwiftData (Transcription @Model)
```

**关键设计：**
- 翻译与后处理并行执行（TaskGroup），15 秒超时竞赛
- SwiftData 批量操作减少 I/O
- 错误恢复：失败的步骤不阻塞后续步骤

### 4.6 笔记管理

**数据模型 `Transcription`** (SwiftData @Model)：
- 原文 (`text`)、增强文本 (`enhancedText`)、翻译 (`translatedText`)
- 音频文件路径、录音时长、时间戳
- 转录状态 (pending / completed / failed)
- 处理元数据（模型名称、处理耗时）

**视图层：**
- `NotesListView`：主列表，支持下拉刷新、滑动删除/复制、自动滚动到新笔记
- `NoteRowView`：单行展示，缓存 NoteData 避免 SwiftData 渲染崩溃，集成 TTS 和复制
- `NoteDetailView`：详情页，双语并排显示，音频回放，重试失败转录

### 4.7 模式系统

**Mode 模型：** 每个模式独立配置转录提供商/模型和后处理提供商/模型/提示词。

**ModeManager** 管理模式集合：
- 防抖持久化（200ms）到 UserDefaults
- deinit 时完成挂起的保存

**DefaultModeManager** 在首次启动时创建默认模式（本地 Whisper，无后处理）。

### 4.8 键盘扩展

**KeyboardViewController** 实现自定义键盘中的语音录入：

**按钮状态：**
| 状态 | 颜色 | 图标 | 操作 |
|------|------|------|------|
| Activate | 绿色 | power | 请求激活主应用 |
| Idle | 蓝色 | mic.fill | 开始录音 |
| Recording | 红色 | stop.fill | 停止录音 |

**通信机制（主应用⇔键盘）：**

```
键盘 → 主应用:
  1. App Group UserDefaults 设置标志位
  2. Darwin Notification 实时通知
  3. URL Scheme (voiceink://record) 拉起主应用

主应用 → 键盘:
  1. App Group UserDefaults 写入状态/转录文本
  2. Darwin Notification 通知状态变化/转录完成
```

**转录文本插入：** 逐词插入 textDocumentProxy（10ms 延迟），提高可靠性。

**状态同步：** 0.5 秒定时轮询 + Darwin Notification 实时回调双保险。

**过期检测：** 录音状态 30 秒过期，激活状态 10 分钟过期，转录文本 5 分钟过期。

---

## 5. 数据模型

### 5.1 Provider 枚举

| Provider | 转录模型 | LLM 模型 | 需要 API Key |
|----------|---------|---------|-------------|
| groq | whisper-large-v3/v3-turbo | llama-3.3-70b/llama-3.1-8b | 是 |
| openai | whisper-1 | gpt-4o/gpt-4o-mini | 是 |
| deepgram | nova-2/nova-3 | — | 是 |
| cerebras | — | llama-3.3-70b/llama-3.1-8b | 是 |
| gemini | — | gemini-2.0-flash/gemini-2.0-pro | 是 |
| local | whisper base | — | 否 |
| voiceink | whisper-large-v3 | gpt-oss-120b | 否 |

### 5.2 PromptTemplate 类型

| 类型 | 用途 |
|------|------|
| custom | 自定义提示词 |
| summary | 生成摘要 |
| keyPoints | 提取关键要点 |
| rewrite | 重写改善清晰度 |
| transcriptCleanup | 清理转录文本 |

### 5.3 LanguageConfiguration

支持 **40+ 种语言**，包含语言代码、名称、国旗 emoji、地区代码。源语言和目标语言独立配置，用于翻译方向判断。

---

## 6. 设计模式

| 模式 | 应用位置 | 说明 |
|------|---------|------|
| **Singleton** | AppSettings, APIKeyManager, ModeManager, AudioSessionManager, ClipboardService 等 12+ 个服务 | 全局共享实例，`@MainActor` 保证线程安全 |
| **Actor** | WhisperContext, LlamaContext | Swift Actor 封装 C++ 库，保证线程安全 |
| **Factory** | TranscriptionServiceFactory | 根据 Provider 创建对应转录服务实例 |
| **Facade** | AppSettings | 委托给 APIKeyManager 和 ModeManager 的统一门面 |
| **Observer** | Darwin Notifications, SwiftData @Query | 进程间通信 + 数据驱动 UI 更新 |
| **State Machine** | RecordingManager (RecordingState) | 管理录音状态转换 |
| **Bridge** | LlamaContext → LlamaBridge (ObjC++) | Swift → ObjC++ → C++ 桥接模式 |
| **Protocol** | TranscriptionService, ErrorHandlerProtocol | 统一接口，支持多实现 |
| **Graceful Degradation** | TranslationService (ML Kit → LLM API) | 多级降级容错 |

---

## 7. 关键技术特性

### 7.1 线程安全
- Swift Actor 封装 whisper.cpp / llama.cpp 保证单线程访问
- `@MainActor` 标注 UI 相关服务
- 串行 DispatchQueue 管理 AppGroupCoordinator 状态
- Double-checked locking 保证键盘扩展线程安全

### 7.2 性能优化
- 预编译正则表达式（TextCleaningService）
- 环形缓冲区避免录音期间内存分配（AudioRecorder）
- NSCache 自动内存管理（LanguageDetectionService）
- 数组预分配容量（RiffWaveUtils）
- 防抖持久化避免频繁 I/O（ModeManager，200ms）
- Metal GPU 加速转录，CPU 自动降级
- 并行任务组 + 超时竞赛（TranscriptionOrchestrator）

### 7.3 错误处理
- `ErrorHandler` 单例统一映射错误到用户友好消息
- 自定义错误类型：TranscriptionError, TranslationError, WhisperTranscriptionError, LlamaError
- 转录流水线中失败步骤不阻塞后续步骤
- AudioSession 激活失败自动重试

### 7.4 安全
- Keychain 存储 API 密钥（KeychainService）
- API Key 输入使用 SecureField
- 密钥显示时部分遮蔽（obfuscatedKey）

### 7.5 日志
- DEBUG 模式使用 `print()` 立即输出
- RELEASE 模式使用 `os_log()` 高性能日志
- 分级：debug / info / warning / error，含文件名/行号/方法名

---

## 8. 依赖项

| 依赖 | 用途 | 集成方式 |
|------|------|---------|
| whisper.cpp | 本地语音转文字 | C++ 编译集成 |
| llama.cpp | 本地 LLM 推理 | xcframework + ObjC++ Bridge |
| Google ML Kit Translate | 设备端翻译 | CocoaPods (~8.0) |
| KeyboardKit | 自定义键盘框架 | SPM |
| SSZipArchive | ZIP 解压 | CocoaPods (隐式依赖) |

---

## 9. 数据流总结

### 9.1 主应用录音流程
```
用户点击麦克风 → RecordingManager.startRecordingFlow()
  → 权限检查 → AudioRecorder.startRecording() (16kHz WAV)
  → 用户停止 → RecordingManager.stopRecording()
  → TranscriptionOrchestrator.processRecording()
    → TranscriptionService.transcribeAudioFile()    # 转录
    → TextCleaningService.cleanTranscriptionText()  # 清理
    → LanguageDetectionService.detectLanguage()      # 检测语言
    → LLMPostProcessor.postProcessTranscript()       # AI 增强 (可选)
    → TranslationService.translate()                 # 翻译 (并行)
  → SwiftData 存储 Transcription 记录
  → UI 自动更新 (@Query)
```

### 9.2 键盘扩展流程
```
用户在键盘点击录音 → AppGroupCoordinator.requestStartRecording()
  → Darwin Notification → 主应用收到信号
  → 主应用前台启动 → RecordingManager.startRecordingFlow()
  → 转录完成 → AppGroupCoordinator.storeTranscript()
  → Darwin Notification (transcriptReady)
  → 键盘收到通知 → getAndConsumeTranscript()
  → textDocumentProxy.insertText() (逐词插入)
```

### 9.3 新用户引导流程
```
首次启动 → OnboardingView (3 步)
  → Step 0: 欢迎 + 功能介绍
  → Step 1: 下载本地 Whisper 模型 (可选跳过)
  → Step 2: 使用说明 → DefaultModeManager.setupForFirstTimeUser()
  → hasCompletedOnboarding = true
  → 进入主界面 NotesListView
```

---

## 10. 代码质量指标

根据项目 planning 目录中的分析记录：

| 指标 | 重构前 | 重构后 |
|------|--------|--------|
| RecordingManager 行数 | 1,095 | 621 (-43%) |
| AppSettings 行数 | 405 | 319 (-21%) |
| 新增服务数 | 0 | 6 |
| 单元测试用例 | 0 | 31 |
| 代码质量评分 | 7.5/10 | 9/10 |

**提取的新服务：** LanguageDetectionService, TextCleaningService, TranscriptionOrchestrator, ErrorHandler, APIKeyManager, ModeManager

**测试覆盖：** LanguageDetectionServiceTests, ErrorHandlerTests, TextCleaningServiceTests, VoiceInk_iosTests
