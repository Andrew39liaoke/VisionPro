# Vision Pro 实时点云展示开发方案

## 一、项目现状与总体思路

当前点云数据规模约为：

- 点数：约 **7500 点/帧**
- 帧率：约 **5 Hz**
- 数据带宽：约 **0.59 MB/s**

从数据规模来看，Vision Pro 的处理压力较小，可以优先关注网络连通、协议解析和渲染链路的正确性，而不需要一开始就进行复杂的性能优化。

建议整个开发过程分为两个阶段：

1. **先将现有点云网页封装成 visionOS App**，快速完成 Vision Pro 真机部署和局域网通信验证。
2. **再开发原生空间点云版本**，将点云真正放入 Vision Pro 的三维空间中，实现移动、旋转、缩放和沉浸式显示。

整体路线如下：

```text
现有 ROS / 点云服务器
        ↓
Web 页面实时显示
        ↓
WKWebView 封装为 visionOS App
        ↓
验证真机网络与部署
        ↓
原生 WebSocket 接收
        ↓
VPPC 协议解析
        ↓
Metal / RealityKit 点云渲染
        ↓
RealityView / ImmersiveSpace
```

---

# 二、方案一：使用 WKWebView 封装现有网页

该方案是最快可以安装到 Vision Pro 真机上的实现方式，基本不需要修改当前网页前端，只需要创建一个 visionOS App，并通过 `WKWebView` 加载现有点云网页。

## 2.1 创建 visionOS 工程

在 Xcode 中选择：

```text
File → New → Project → visionOS → App
```

推荐配置：

```text
Interface: SwiftUI
Language: Swift
Immersive Space: None
```

此阶段暂时不创建沉浸空间，只将现有网页作为普通 visionOS 窗口应用运行。

---

## 2.2 新建 WebPointCloudView.swift

创建文件：

```text
WebPointCloudView.swift
```

代码如下：

```swift
import SwiftUI
import WebKit

struct WebPointCloudView: UIViewRepresentable {
    let pageURL: URL

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(
            frame: .zero,
            configuration: configuration
        )

        webView.isInspectable = true
        webView.load(URLRequest(url: pageURL))

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}
```

该组件的作用是将现有网页直接嵌入 visionOS 的 SwiftUI 页面中。

Apple 支持在 visionOS App 中使用 `WKWebView` 显示网页内容。

官方文档：

- https://developer.apple.com/documentation/webkit/wkwebview/

---

## 2.3 修改 ContentView.swift

将默认 `ContentView.swift` 修改为：

```swift
import SwiftUI

struct ContentView: View {
    var body: some View {
        WebPointCloudView(
            pageURL: URL(string: "http://192.168.3.21:8080/")!
        )
        .ignoresSafeArea()
    }
}
```

其中：

```text
http://192.168.3.21:8080/
```

是当前点云网页服务器地址。

实际开发时，后续应当将服务器 IP 和端口从代码中抽离出来，改成可配置参数，而不是长期写死在代码中。

---

## 2.4 配置局域网访问权限

由于 Vision Pro 需要访问局域网中的 ROS / 点云服务器，因此需要在 `Info.plist` 中声明相关权限。

添加：

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>用于连接ROS点云服务器并接收实时建模数据</string>

<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
</dict>
```

作用分别为：

- `NSLocalNetworkUsageDescription`：说明 App 为什么需要访问局域网设备。
- `NSAllowsLocalNetworking`：允许访问局域网中的 HTTP / WebSocket 服务。

相关 Apple 文档：

- Local Network：
  https://developer.apple.com/documentation/bundleresources/information-property-list/nslocalnetworkusagedescription

- ATS Local Networking：
  https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking

---

## 2.5 Vision Pro 真机运行前检查

在通过 Xcode 安装到 Vision Pro 前，先检查整个局域网链路。

需要确保：

- Vision Pro 和服务器 `192.168.3.21` 处于同一个局域网。
- 网页服务监听：

```text
0.0.0.0:8080
```

- WebSocket 服务监听：

```text
0.0.0.0:8765
```

- 服务器防火墙允许：

```text
TCP 8080
TCP 8765
```

推荐首先使用 Vision Pro Safari 打开：

```text
http://192.168.3.21:8080/
```

如果 Safari 可以正常访问网页并显示实时点云，则说明：

```text
Vision Pro
   ↓
局域网
   ↓
Web Server
   ↓
WebSocket
   ↓
ROS 点云数据
```

这一整条链路已经基本打通。

随后再通过 Xcode 将 App 安装到 Vision Pro 真机。

---

## 2.6 方案一最终效果

完成后得到的是一个 **visionOS 窗口应用**。

其显示效果与当前浏览器中的点云网页基本一致：

```text
Vision Pro App
      ↓
WKWebView
      ↓
现有 Web 点云页面
      ↓
WebSocket
      ↓
ROS 点云服务器
```

该方案主要用于验证：

- Vision Pro 真机部署是否正常。
- 局域网访问是否正常。
- WebSocket 是否能够正常通信。
- 当前点云数据是否能够稳定显示。

它是后续原生开发前的重要过渡阶段。

---

# 三、方案二：开发原生空间点云 App

如果希望点云真正悬浮在用户面前，并能够：

- 在三维空间中查看；
- 进行移动；
- 进行旋转；
- 进行缩放；
- 进入沉浸式空间；

则需要将网页中的点云接收和渲染逻辑逐步替换为 visionOS 原生实现。

整体架构如下：

```text
ws://192.168.3.21:8765/
        ↓
URLSessionWebSocketTask
        ↓
VPPCDecoder
        ↓
PointCloudFrame
        ↓
Metal / RealityKit
        ↓
RealityView / ImmersiveSpace
```

---

# 四、推荐工程目录

建议将工程按网络、协议、数据模型、渲染和界面进行拆分：

```text
VisionProPointCloud/
├── App/
│   └── VisionProPointCloudApp.swift
│
├── Network/
│   ├── VPPCWebSocketClient.swift
│   └── VPPCDecoder.swift
│
├── Model/
│   └── PointCloudFrame.swift
│
├── Rendering/
│   ├── PointCloudRenderer.swift
│   └── CoordinateConverter.swift
│
└── Views/
    ├── ContentView.swift
    └── ImmersiveView.swift
```

各模块职责如下：

| 模块 | 主要职责 |
|---|---|
| App | visionOS App 入口、Scene 配置 |
| Network | WebSocket 建连、消息接收 |
| VPPCDecoder | 二进制 VPPC 数据解析 |
| Model | 点云帧数据结构 |
| Rendering | GPU Buffer、Metal / RealityKit 渲染 |
| CoordinateConverter | ROS 与 RealityKit 坐标转换 |
| Views | 普通窗口和沉浸空间界面 |

---

# 五、WebSocket 原生接收

visionOS 可以直接使用 Foundation 提供的：

```swift
URLSessionWebSocketTask
```

来连接现有 WebSocket 服务。

示例代码：

```swift
import Foundation

actor VPPCWebSocketClient {
    private var task: URLSessionWebSocketTask?

    func connect(to url: URL) {
        task = URLSession.shared.webSocketTask(with: url)
        task?.resume()
    }

    func receive() async throws -> Data {
        guard let task else {
            throw URLError(.notConnectedToInternet)
        }

        let message = try await task.receive()

        switch message {
        case .data(let data):
            return data

        case .string:
            throw VPPCError.unexpectedTextMessage

        @unknown default:
            throw VPPCError.unsupportedMessage
        }
    }

    func disconnect() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }
}

enum VPPCError: Error {
    case unexpectedTextMessage
    case unsupportedMessage
}
```

其工作流程为：

```text
connect()
   ↓
WebSocket 握手
   ↓
receive()
   ↓
接收二进制 Data
   ↓
交给 VPPCDecoder
```

Apple 官方文档：

- https://developer.apple.com/documentation/foundation/urlsessionwebsockettask

---

# 六、VPPC 点云协议解析

根据当前页面协议，当前实际使用的是：

```text
VPPC v1 · XYZ1
```

而不是之前文档中的：

```text
XYZRGBA
```

因此 visionOS 原生解析器必须严格与当前网页协议保持一致。

## 6.1 单点数据结构

每个点可以表示为：

```swift
struct PointXYZI {
    var x: Float
    var y: Float
    var z: Float
    var intensity: Float
}
```

单点数据包含：

```text
x           Float32   4 Byte
y           Float32   4 Byte
z           Float32   4 Byte
intensity   Float32   4 Byte
-----------------------------
总计                   16 Byte
```

因此当前协议关键参数为：

```text
Header：36 字节
Point：16 字节
字节序：Little Endian
```

原生解析器需要完成：

```text
WebSocket Data
      ↓
检查 VPPC Header
      ↓
读取点数 / 帧信息
      ↓
按 16 Byte 拆分 PointXYZI
      ↓
生成 PointCloudFrame
```

---

# 七、ROS 与 RealityKit 坐标转换

ROS、Web 页面和 RealityKit 使用的坐标系可能不同，因此必须统一处理坐标轴映射。

可以暂时采用：

```swift
let realityPosition = SIMD3<Float>(
    rosPoint.y,
    rosPoint.z,
    -rosPoint.x
)
```

即：

```text
RealityKit X ← ROS Y
RealityKit Y ← ROS Z
RealityKit Z ← -ROS X
```

但具体轴映射仍然需要通过当前网页和 RViz 做一次实际方向对照。

例如需要确认：

- 前方对应哪一个轴；
- 上方对应哪一个轴；
- 左右方向是否相反；
- 是否存在镜像问题。

坐标转换逻辑不应该分散写在多个渲染器中，而应统一放在：

```text
CoordinateConverter.swift
```

形成：

```text
ROS Point
    ↓
CoordinateConverter
    ↓
RealityKit Position
```

这样后续修改坐标系时只需要修改一个位置。

---

# 八、点云渲染方案

## 8.1 不推荐：一个点一个 Entity

不要针对每个点分别创建 RealityKit `Entity`。

例如：

```text
7500 点
 ↓
7500 个 Entity
```

这种方式会产生大量对象管理和 Scene Graph 开销，不适合持续刷新点云。

---

## 8.2 推荐：GPU Buffer 统一渲染

正确做法是：

```text
PointCloudFrame
      ↓
Vertex Buffer
      ↓
GPU
      ↓
一次性绘制全部点
```

所有点存入一个 GPU Buffer 中，每收到一帧只更新 Buffer 内容。

可以选择两种实现方案：

### 方案 A：Metal

直接使用 Metal 绘制 Point Primitive。

优点：

- 性能最高；
- 点大小、颜色等控制灵活；
- 适合后续高密度点云。

缺点：

- 开发复杂度较高。

### 方案 B：RealityKit LowLevelMesh

使用 RealityKit 的：

```text
LowLevelMesh
```

实现自定义顶点数据和动态更新。

优点：

- 能够与 RealityKit 场景体系结合；
- 适合频繁更新顶点数据；
- 便于接入 visionOS 空间交互。

Apple 官方文档：

- https://developer.apple.com/documentation/realitykit/lowlevelmesh

---

# 九、实时数据更新策略

由于点云属于实时数据，因此网络接收线程和渲染线程之间需要解耦。

推荐数据链路：

```text
WebSocket Thread
       ↓
VPPCDecoder
       ↓
Latest PointCloudFrame
       ↓
GPU Buffer
       ↓
Rendering Thread
```

重点策略如下。

## 9.1 只保留最新帧

当网络速度或渲染速度下降时，不应该把所有历史帧排队等待渲染。

例如：

```text
Frame 101
Frame 102
Frame 103
Frame 104
```

如果 GPU 当前只能处理最新数据，则直接丢弃旧帧：

```text
保留 Frame 104
```

因为对于实时点云来说：

> 实时性通常比逐帧完整播放更重要。

---

## 9.2 使用双缓冲

建议使用双 Buffer：

```text
Buffer A → GPU 正在渲染
Buffer B → 网络线程更新

下一帧：

Buffer B → GPU 渲染
Buffer A → 更新新数据
```

这样能够避免：

```text
网络线程
   ↓
直接修改 GPU 正在使用的数据
```

降低线程冲突和画面异常风险。

---

# 十、ImmersiveSpace 沉浸空间

当普通窗口中的原生点云显示完成后，可以进一步加入 `ImmersiveSpace`。

App 入口可以定义为：

```swift
import SwiftUI

@main
struct VisionProPointCloudApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }

        ImmersiveSpace(id: "PointCloudSpace") {
            ImmersiveView()
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}
```

这里使用：

```text
.mixed
```

表示在保留真实世界画面的同时，在真实环境中叠加点云。

最终可以形成：

```text
真实世界
   +
实时 ROS 点云
   +
空间坐标轴 / 网格 / 标注
```

点云可以通过 `RealityView` 加入 RealityKit 三维空间。

Apple 官方资料：

- https://developer.apple.com/documentation/SwiftUI/Immersive-spaces

---

# 十一、后续交互功能

在点云原生显示稳定以后，可以依次增加以下功能。

## 11.1 点云平移

通过手势改变点云整体位置：

```text
Drag Gesture
      ↓
Entity Translation
```

---

## 11.2 点云旋转

实现手势旋转：

```text
Rotation Gesture
       ↓
Entity Orientation
```

---

## 11.3 点云缩放

通过双手缩放或 Magnify Gesture：

```text
Magnify Gesture
       ↓
Entity Scale
```

---

## 11.4 重置视角

增加：

```text
Reset
```

按钮，将点云恢复到默认：

- 位置；
- 旋转；
- 缩放。

---

# 十二、视觉增强功能

点云基础渲染完成后，可以进一步添加：

- 灰度显示；
- 强度着色；
- 高度着色；
- 坐标轴；
- 地面网格；
- 点大小调节；
- 点云透明度；
- FPS 显示；
- 当前点数显示；
- 网络延迟显示。

例如：

```text
Intensity
    ↓
Color Mapping
    ↓
Point Vertex Color
```

这样可以逐步接近 RViz 中的点云显示效果。

---

# 十三、推荐开发顺序

推荐按照以下顺序推进。

## 第一阶段：真机网络链路验证

### Step 1

使用 Vision Pro Safari 打开现有网页：

```text
http://192.168.3.21:8080/
```

确认实时点云能够正常显示。

### Step 2

使用 `WKWebView` 将网页封装成 visionOS 窗口 App。

### Step 3

将 WebSocket URL 和服务器 IP 改为 App 内可编辑配置，而不是写死。

阶段目标：

```text
Vision Pro 真机
     ↓
visionOS App
     ↓
现有实时点云网页
```

---

## 第二阶段：原生通信与协议解析

### Step 4

实现：

```text
VPPCWebSocketClient
```

通过 `URLSessionWebSocketTask` 接收二进制消息。

### Step 5

实现：

```text
VPPCDecoder
```

完成：

```text
VPPC v1 · XYZ1
```

协议解析。

阶段目标：

```text
WebSocket
    ↓
二进制 Data
    ↓
PointCloudFrame
```

---

## 第三阶段：原生点云渲染

### Step 6

先使用固定灰度显示所有点。

暂时不考虑复杂颜色映射，只确认：

- 点数正确；
- 位置正确；
- 坐标方向正确；
- 实时刷新正常。

### Step 7

增加：

- 强度着色；
- 坐标轴；
- 网格；
- 点大小调节。

阶段目标：

```text
PointCloudFrame
      ↓
GPU Buffer
      ↓
RealityKit / Metal
      ↓
实时点云
```

---

## 第四阶段：空间交互

### Step 8

加入：

- 移动；
- 旋转；
- 缩放；
- 重置。

### Step 9

加入：

```text
ImmersiveSpace
```

将点云放入真实空间。

阶段目标：

```text
ROS 点云
   ↓
Vision Pro
   ↓
真实世界中的三维点云
```

---

## 第五阶段：稳定性优化

### Step 10

增加断线重连机制：

```text
连接失败
   ↓
等待
   ↓
重新连接
```

同时增加：

- 最新帧覆盖；
- 双缓冲；
- 网络状态显示；
- FPS 统计；
- 数据异常保护。

---

# 十四、当前最合适的里程碑

目前不建议直接跳到复杂的原生 Metal / RealityKit 点云渲染。

最合理的近期里程碑是：

> **先使用 WKWebView 在 Vision Pro 真机中成功显示现有实时点云网页。**

这一步主要验证：

```text
Vision Pro 真机部署
      +
局域网访问
      +
HTTP
      +
WebSocket
      +
实时点云数据
```

全部正常。

完成后，再将网页方案中的两部分：

```text
WebSocket 接收
+
WebGL 点云渲染
```

逐步替换为：

```text
URLSessionWebSocketTask
+
VPPCDecoder
+
Metal / RealityKit
```

最终形成真正的 visionOS 原生空间点云应用。

---

# 十五、最终技术路线总结

整个项目可以概括为两个核心阶段。

## 阶段一：网页快速迁移

```text
ROS 点云
   ↓
WebSocket
   ↓
Web 页面
   ↓
WKWebView
   ↓
Vision Pro App
```

特点：

- 开发快；
- 改动小；
- 适合真机验证。

---

## 阶段二：visionOS 原生空间点云

```text
ROS 点云服务器
       ↓
WebSocket
       ↓
URLSessionWebSocketTask
       ↓
VPPCDecoder
       ↓
PointCloudFrame
       ↓
CoordinateConverter
       ↓
GPU Buffer
       ↓
Metal / RealityKit
       ↓
RealityView
       ↓
ImmersiveSpace
```

特点：

- 原生性能更好；
- 能进入三维空间；
- 支持手势交互；
- 更适合后续实时建模、语义标注和空间增强显示。

因此，目前建议坚持以下开发策略：

> **先跑通 WKWebView 真机版本，再开发原生 VPPC + Metal / RealityKit 点云版本。**
