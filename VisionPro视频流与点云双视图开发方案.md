# Vision Pro 视频流与点云双视图开发方案

## 一、文档目标

在现有 Vision Pro 视频流 App 中同时展示：

- D435i 实时彩色视频；
- ROS 实时点云；
- 一个主视图和一个右下角子视图；
- 视频与点云的一键互换；
- 点云作为主视图时的平移、旋转和缩放。

本方案不将子视图实现为独立的 visionOS 系统窗口，而是在同一个 `WindowGroup` 内使用 SwiftUI 叠加布局实现画中画。这样可以稳定控制右下角位置、互换动画和手势优先级。

---

## 二、现有工程基础

当前工程已具备：

| 能力 | 现有实现 |
|---|---|
| 视频连接 | `StreamSession` |
| WHEP / WebRTC | `WHEPClient`、`WebRTCEngine` |
| 视频渲染 | `RemoteVideoView` + `MetalVideoView` |
| 视频连接配置 | `ConnectionSettingsView` |
| 主窗口 | `ContentView` |
| 窗口默认尺寸 | 960 × 680 |

现有 `ContentView` 已经使用 `ZStack` 展示视频，可以将该区域替换为新的 `DualStreamViewport`，不需要重构视频接收和解码链路。

点云部分尚未实现工程代码，建议按两步接入：

1. 首先用 `WKWebView` 加载现有点云网页，快速完成双视图交互验证。
2. 之后使用 WebSocket + VPPC + Metal/RealityKit 替换为原生点云。

---

## 三、产品交互设计

### 3.1 默认布局

```text
┌────────────────────────────────────────┐
│ D435i RGB        视频状态     连接设置 │
├────────────────────────────────────────┤
│                                        │
│                                        │
│              视频主视图                │
│                                        │
│                         ┌──────────┐ │
│                         │ 点云子视图 │ │
│                         │     ⇄     │ │
│                         └──────────┘ │
├────────────────────────────────────────┤
│ 分辨率  FPS  网络指标             操作按钮 │
└────────────────────────────────────────┘
```

建议样式：

- 子视图宽度为内容区宽度的 28%，建议限制在 240–360 pt。
- 子视图默认使用 16:9，边距 20 pt。
- 子视图使用 16 pt 圆角、浅色边框和空间阴影。
- 交换按钮放在子视图内部右上角，图标使用 `arrow.triangle.2.circlepath`。
- 子视图继续显示简化连接状态，但不显示大面积设置或错误面板。

### 3.2 主子视图互换

用户可通过以下任一操作互换：

- 点击子视图中的交换按钮；
- 直接点击子视图的非交互区域。

互换行为必须满足：

- 仅改变两个视图的尺寸、位置和层级；
- 不断开 WebRTC 视频连接；
- 不断开点云 WebSocket 或重新加载网页；
- 不重置点云当前的位置、旋转和缩放；
- 使用 0.3–0.4 秒的平滑动画；
- 动画进行中忽略重复交换请求。

### 3.3 点云手势

| 点云状态 | 允许操作 |
|---|---|
| 主视图 | 拖动、旋转、缩放、重置视角 |
| 子视图 | 点击互换，默认禁用点云变换手势 |

子视图状态禁用点云手势，可以避免拖动点云与点击互换产生冲突。如后续需要在子视图内操作点云，应使用独立“解锁交互”按钮，不要默认开启。

---

## 四、技术架构

```text
ContentView
   │
   ├─ Header / Footer / Metrics
   │
   └─ DualStreamViewport
        │
        ├─ VideoPanel
        │    └─ RemoteVideoView
        │         └─ StreamSession
        │
        ├─ PointCloudPanel
        │    ├─ 第一阶段：WebPointCloudView
        │    └─ 第二阶段：NativePointCloudView
        │         └─ PointCloudSession
        │
        └─ SwapControl
             └─ ViewportLayoutState
```

### 4.1 核心状态

```swift
enum PrimaryContent: String, Codable {
    case video
    case pointCloud
}

@MainActor
@Observable
final class ViewportLayoutState {
    var primary: PrimaryContent = .video
    private(set) var isSwapping = false

    func swap() {
        guard !isSwapping else { return }
        isSwapping = true
        primary = primary == .video ? .pointCloud : .video
    }

    func animationCompleted() {
        isSwapping = false
    }
}
```

`ViewportLayoutState` 只管理布局，不直接调用 `StreamSession.connect()` 或点云连接方法。

### 4.2 视图常驻原则

视频和点云视图应始终同时存在于视图树中，不要使用下列方式互换：

```swift
// 不推荐：切换时可能销毁 UIViewRepresentable 内部视图
if primary == .video {
    RemoteVideoView(...)
} else {
    PointCloudView(...)
}
```

应同时声明两个视图，根据状态修改 `frame`、`position`、`clipShape` 和 `zIndex`。这可以避免 `RemoteVideoView` 执行 `dismantleUIView`，也可以避免 `WKWebView` 重新加载。

### 4.3 双视图布局骨架

```swift
struct DualStreamViewport<Video: View, PointCloud: View>: View {
    @Binding var primary: PrimaryContent
    private let video: Video
    private let pointCloud: PointCloud

    init(
        primary: Binding<PrimaryContent>,
        @ViewBuilder video: () -> Video,
        @ViewBuilder pointCloud: () -> PointCloud
    ) {
        _primary = primary
        self.video = video()
        self.pointCloud = pointCloud()
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let inset: CGFloat = 20
            let pipWidth = min(max(size.width * 0.28, 240), 360)
            let pipSize = CGSize(width: pipWidth, height: pipWidth * 9 / 16)

            ZStack(alignment: .bottomTrailing) {
                video
                    .modifier(PanelLayout(
                        isPrimary: primary == .video,
                        containerSize: size,
                        pipSize: pipSize,
                        inset: inset
                    ))

                pointCloud
                    .modifier(PanelLayout(
                        isPrimary: primary == .pointCloud,
                        containerSize: size,
                        pipSize: pipSize,
                        inset: inset
                    ))
            }
            .animation(.smooth(duration: 0.35), value: primary)
        }
    }
}
```

`PanelLayout` 负责主视图与子视图的几何变换。实现时要保证子视图始终处于更高的 `zIndex`，否则它会被主视图遮挡。

---

## 五、点云接入设计

### 5.1 第一阶段：网页点云

新建 `WebPointCloudView.swift`，使用 `WKWebView` 加载现有点云页面。

要求：

- `WKWebView` 实例在主子视图互换时不重建；
- 页面 URL 由配置界面管理，不长期写死在代码中；
- 子视图状态可屏蔽网页的拖动和缩放手势；
- 加载失败时仅在点云面板内显示错误，不影响视频流；
- 视频和点云连接状态分开管理。

该阶段用于验证布局、互换动画、真机局域网访问和同时渲染能力。

### 5.2 第二阶段：原生点云

使用原生实现替换 `WebPointCloudView`：

```text
PointCloudSession
      │
      ├─ VPPCWebSocketClient
      ├─ VPPCDecoder
      ├─ LatestFrameStore
      └─ PointCloudRenderer
```

建议统一对外提供 `PointCloudPanel`，使顶层双视图布局不关心底层是网页还是原生渲染。

```swift
struct PointCloudPanel: View {
    let interactionEnabled: Bool
    // 内部可在迁移期间选择 Web 或 Native 实现
}
```

原生渲染时，点云所有顶点由单个 GPU Buffer 管理，不要为每个点创建独立 Entity。

---

## 六、连接与生命周期

视频和点云是两条独立数据链路：

```text
WHEP / WebRTC ──→ StreamSession     ──→ RemoteVideoView
WebSocket/VPPC ──→ PointCloudSession ──→ PointCloudView
```

生命周期规则：

- App 进入 `active` 时，根据用户配置恢复两条连接。
- App 进入后台时，两条连接分别暂停或释放。
- 主子视图互换不影响任何连接。
- 其中一条连接失败时，另一条继续工作。
- 两条连接分别重连，不共用重连计数器。
- 用户主动断开某条连接后，该链路不自动重连。

配置项建议拆分为：

| 配置 | 示例 |
|---|---|
| 视频 WHEP URL | `http://server:8889/d435i/whep` |
| 点云网页 URL | `http://server:8080/` |
| 点云 WebSocket URL | `ws://server:8765/` |
| 默认主视图 | `video` |
| 是否记住上次布局 | `true/false` |

---

## 七、错误与空状态

| 场景 | 界面行为 |
|---|---|
| 视频未连接 | 视频面板显示连接按钮，点云继续展示 |
| 点云未连接 | 点云面板显示重连按钮，视频继续展示 |
| 两者都失败 | 两个面板各自显示错误原因 |
| 子视图失败 | 保留子视图，允许互换到主视图进行处理 |
| 正在互换 | 禁用交换按钮，动画完成后恢复 |

不应因一个子系统失败而在整个窗口上显示全屏遮罩。

---

## 八、性能策略

当前点云约 7500 点/帧、5 Hz，计算压力较小，但视频和点云同时运行时仍需遵守：

- 视频继续使用现有 Metal 零拷贝优先路径。
- 点云只保留最新帧，不累积历史帧。
- 原生点云使用双缓冲或可安全轮换的 GPU Buffer。
- 子视图可降低点大小、标注数量和统计信息更新频率。
- 视频和点云视图保持实例常驻，互换时不重建渲染器。
- 不在主线程执行 VPPC 二进制解析或大量顶点转换。

建议在调试面板增加：

- 视频 FPS、码率、RTT 和丢包率；
- 点云 FPS、当前点数、最后一帧时间；
- 视频与点云各自的重连次数；
- 当前主视图类型。

---

## 九、推荐工程目录

```text
Visonpro/
├── ContentView.swift
├── Layout/
│   ├── DualStreamViewport.swift
│   ├── PanelLayout.swift
│   └── ViewportLayoutState.swift
├── Views/
│   ├── RemoteVideoView.swift
│   ├── VideoPanel.swift
│   ├── PointCloudPanel.swift
│   └── SwapControl.swift
├── PointCloud/
│   ├── WebPointCloudView.swift
│   ├── PointCloudSession.swift
│   ├── VPPCWebSocketClient.swift
│   ├── VPPCDecoder.swift
│   └── PointCloudRenderer.swift
└── Streaming/
    ├── StreamSession.swift
    ├── WHEPClient.swift
    └── WebRTCEngine.swift
```

Web 过渡阶段只需创建 `Layout` 目录与 `WebPointCloudView.swift`；原生点云相关文件在第二阶段加入。

---

## 十、分阶段开发计划

### 阶段 A：静态画中画

1. 从 `ContentView` 拆分 `VideoPanel`。
2. 新建临时 `PointCloudPanel`，先显示静态占位内容。
3. 实现视频主画面和右下角点云子视图。
4. 验证窗口缩放时子视图不越界。

### 阶段 B：主子互换

1. 引入 `PrimaryContent` 状态。
2. 实现互换按钮和过渡动画。
3. 保证 `RemoteVideoView` 不在互换时销毁。
4. 增加 VoiceOver 标签和焦点效果。

### 阶段 C：接入网页点云

1. 实现 `WebPointCloudView`。
2. 配置局域网、HTTP 和 WebSocket 访问权限。
3. 使视频与点云同时连接和渲染。
4. 验证连续互换不导致网页刷新或视频重连。

### 阶段 D：点云交互

1. 点云为主视图时开启拖动、旋转和缩放。
2. 点云为子视图时禁用上述手势。
3. 增加“重置视角”按钮。
4. 设置最小/最大缩放范围和合理的拖动边界。

### 阶段 E：原生点云替换

1. 实现 VPPC 接收与解析。
2. 实现 GPU Buffer 点云渲染。
3. 保持 `PointCloudPanel` 的对外接口不变。
4. 删除 Web 过渡实现前，完成原生版画面、坐标和性能对比。

---

## 十一、测试清单

### 11.1 功能测试

- [ ] App 启动后视频默认为主视图。
- [ ] 点云默认位于右下角。
- [ ] 点击交换后点云成为主视图。
- [ ] 再次交换后视频恢复为主视图。
- [ ] 互换过程无黑屏、闪烁和内容重新加载。
- [ ] 点云变换在互换前后保留。
- [ ] 视频断线不影响点云。
- [ ] 点云断线不影响视频。
- [ ] 窗口改变尺寸后子视图位置正确。

### 11.2 手势测试

- [ ] 点云为主视图时可拖动、旋转和缩放。
- [ ] 点云为子视图时不误触变换手势。
- [ ] 交换按钮不与点云手势同时响应。
- [ ] 连续快速点击交换不会产生布局错乱。
- [ ] 重置视角能恢复默认位置、旋转和缩放。

### 11.3 稳定性测试

- [ ] 视频与点云同时运行 30 分钟无持续内存增长。
- [ ] 前后台切换后两条链路可恢复。
- [ ] Wi-Fi 短暂断开后两条链路独立重连。
- [ ] 连续互换 100 次不产生渲染器或网页实例泄漏。
- [ ] 主视图和子视图的帧更新都保持正常。

---

## 十二、验收标准

第一个可交付版本应满足：

1. Vision Pro 真机上可同时看到实时视频和实时点云。
2. 默认为“视频主视图 + 点云右下角子视图”。
3. 一次操作可完成主子视图互换，动画连续。
4. 互换不导致视频或点云断线、重连、刷新或状态丢失。
5. 点云为主视图时支持拖动、旋转、缩放和重置。
6. 任意一条数据链路失败时，另一条仍可独立使用。
7. 连续运行 30 分钟无明显内存泄漏、持续卡顿或应用崩溃。

---

## 十三、建议的近期里程碑

首个里程碑建议定义为：

> 在不修改现有 WebRTC 视频链路的前提下，将现有点云网页作为右下角子视图接入，完成视频/点云主子互换，并确认互换过程中两条数据链路始终连续。

该里程碑完成后，再开始实现原生 VPPC 解析和 Metal/RealityKit 点云渲染，可以降低布局、网络和渲染问题同时出现带来的调试复杂度。
