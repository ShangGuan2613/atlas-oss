# P2-A Feel Fix — Canvas 对齐 Atlas/PureRef 手感（先模仿，再超越）

Repo: `~/devApple/atlas-oss`. Clean-room. **禁止**反编译 `/Applications/Atlas.app`；只对标公开行为 + PureRef/tldraw 机制。

## 用户原话
「错位，且不好用不流畅。Atlas究竟是怎么写的，你先模仿，然后超越」

## 已定位根因（ghost 实测代码，不是猜）

1. **几何错位**：`CanvasLayout` 按 **正方形** `tileSize×tileSize`（220）打包；`ItemCell` 图像区是 **`width × width*0.75`**，有 caption 时更高。打包间距、剔除包围盒、拖拽夹紧框都和屏幕上看到的格子不一致 → 视觉「错位」。
2. **流畅度**：每个 tile 每帧 `viewPoint(forWorld:)` + 独立 `.offset` + SwiftUI `ItemCell`。相机一动就重算整层。同类产品（含公开说「rebuilt on AppKit」的 canvas 类应用）是用 **一层原生变换** 推整板，不是几百个 SwiftUI view 各自跟手。
3. **P2-B 半成品**：Camera clamp 被拆掉、Infinity 已接线；Canvas 手感可能更飘。本任务以 **Canvas 手感优先**；Infinity 可保留开关但不抢修。

## 对标（机制，不是像素）

| 维度 | 对标 | 抄什么 | 不抄 |
|---|---|---|---|
| 相机 | PureRef | 单矩阵：pan/zoom 改 camera，内容在世界坐标静止 | 抄 UI 皮肤 |
| 布局 | Atlas 公开描述 + 我们网格 | 画布格子与 Grid 同 aspect；Reset = 整齐打包 | 拆 Atlas 二进制 |
| 性能 | AppKit/CALayer 画板 | 一层 transform；可见区才挂图 | Electron/WebView |
| 手势 | PureRef | 滚轮平移、⌘滚轮定点缩放、拖图、空格拖动画布 | — |

## 必须做的改动

### A. 几何对齐（先消错位）
- Core 引入与 Grid 一致的 `tileAspect = 0.75`（可放 `CanvasLayout`，避免 App 依赖循环）。
- `tileWidth = tileSize`，`tileHeight = tileSize * tileAspect`。
- `packedPositions` / `appendedPositions` / `pitch`：**行高用 tileHeight + gap**，列宽用 tileWidth + gap。
- 空间索引、`contentBounds`、拖拽 `board` 夹紧：用真实 footprint（宽×高×scale），不要再用正方形。
- Caption：LOD `.labeled` 时 footprint 高度再加固定 caption 预算（写死常量并测），或 Canvas 默认 `showsCaption: false` 直到 zoom 够大（更接近 moodboard）。**选更接近 Atlas/PureRef 的：画布默认不显示文件名条**，避免格子被文字撑歪；Grid 仍显示。
- 迁移：已有 `item_positions` 坐标保留；Reset Layout 用新几何重排。加测试：打包无重叠、行距 = tileHeight+gap。

### B. 单层相机变换（先模仿流畅）
- 世界层：tiles 用 **世界坐标** 定位（`.position` / offset 用 x,y，尺寸用 world tileWidth/Height * scale）。
- 外层 **只做一次** `scaleEffect(zoom, anchor: .topLeading)` + `offset(-origin.x*zoom, -origin.y*zoom)`（或等价 `GraphicsContext` / `CATransform3D`）。
- **禁止**在每个 tile 上调用 `viewPoint` 再 offset（那是当前卡顿源）。
- 剔除仍用 world `visibleWorldRect`；只实例化可见 ID。
- 拖拽预览：`liveDrag` 仍改世界 delta；松手写库。

### C. 原生层（超越 SwiftUI 瓶颈的方向，本切片能做多少做多少）
优先序：
1. 若 B 后 500 tiles 平移仍掉帧 → 抽出 `CanvasBoardNSView`（NSViewRepresentable）：`wantsLayer`，`sublayerTransform` 或单个 `CALayer` 仿射变换；缩略图用 `CALayer.contents`。
2. 滚轮/精确触控板走现有 `NSEvent` monitor；保证 60fps 目标下不每帧 `objectWillChange` 洪水——camera 可用 `Observable` 粗粒度或直接改 NSView。
3. 缩略图：拖/缩放中可用低 LOD（已有），保证 decode 不堵主线程。

### D. Canvas vs Infinity
- Canvas：可保留虚线 board 框；拖拽夹紧到 board。
- Infinity：无框、不夹紧。
- 两者共用同一套「单层变换」渲染路径。

## 验收（ghost 亲自跑）
1. `swift build --product AtlasOSSApp` + `swift test` 全绿。
2. Reset Layout 后格子整齐、无重叠、与视觉包围盒一致（截图或 UI 测试描述）。
3. 在约 200+ items 的库：指针对准缩放时，指针下的图不「滑走」；拖图跟手；平移无明显一顿一顿（主观 + 若有 `CanvasBench` 则更新数字）。
4. STATUS 增加 `## P2-A Feel`：写清改了几何 + 单层变换（以及是否上了 NSView）。
5. 短报告：还差什么才能「超越」Atlas（例如 Metal、惯性滚动）。

## Forbid
反编译 Atlas；复制 Atlas 资源；大范围无关重构；不要停在「再加一个 SwiftUI animation」。

## Out of scope
⌘K、Like、Links、浏览器扩展。
