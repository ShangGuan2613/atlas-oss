# P1 Plan — 复刻 Atlas 细节 + UI/UX 对标迭代

## 现状（P0）
已有：SQLite 库、connected/copy 导入、CLI、最小侧栏+LazyVGrid、11 图已迁入。
没有：三视图手感、标签/Inbox、Info、外观 token、拖放采集、菜单栏 pin、画布……

## 原则
1. Clean-room：对标公开行为与 IA，不反编译、不搬品牌资源。
2. 先复刻可感知核心，再靠榜样超车（抄机制不抄皮）。
3. 可验收：每子阶段出门证；假设数字尽快本机实测替换。

## Atlas 公开能力 − 最小 viewer 缺口

来源：atlasformac.com / release notes。P1 = 日常网格库对等；Later = Canvas/采集生态/智能。

| 优先级 | 缺口 |
|---|---|
| **P1** | 指针锚定网格缩放；多选+批量；Space/箭头 lightbox；侧栏嵌套+拖排序；Inbox；标签；Info；主色色票；间距/圆角/背景/亮暗；窗与侧栏投放；菜单栏 drop→Inbox；排序与滚动/缩放记忆；Like/Trash；名/标签搜索；右键；GIF/视频可播；导入去重；Undo |
| **Later** | Canvas/Infinity；瀑布流可后移；浏览器扩展；链接卡片；语义搜；Smart folders；Notes；裁剪；多库；Eagle；MCP 深化；iOS |

## 维度｜榜样｜出门证（A–F）

| 维 | 榜样（优先 OSS） | 抄什么 | 不抄什么 | 出门证 |
|---|---|---|---|---|
| **A 网格 UX** | Immich Gallery（键盘/Shift 多选/lightbox 回位）；Eagle 布局语义（Grid/Justified/Waterfall）；PureRef 导航（指针锚定感） | 指针锚定 pinch/⌘-scroll 改密度；方向键走格；Space 快览；Esc 清选；⌘/⇧ 多选；打开不丢滚动位 | Immich 服务端相册；Eagle 闭源实现；PureRef 无集合 IA | 密度连续可调且锚定不跳；键盘走完视口；Space 开/关；多选≥2 底部操作可用；关 lightbox 回原位（假设动画 p95 <200ms） |
| **B 集合 IA** | Atlas 公开行为；Eagle 文件夹+标签；Are.na Channels（多归属/Inbox 感） | 嵌套；侧栏拖排序+投放线；Inbox 默认落入；标签侧栏+批量打标；一物多集合 | Are.na 无真文件夹；Eagle 智能文件夹规则（后置）；云协作 | 拖集合可见嵌套；拖图到侧栏打集合/标签；Inbox 未整理计数；重启序仍在 |
| **C 外观 tokens** | Obsidian CSS 变量；VS Code 可搜设置；Atlas Settings 可搜 | 间距/圆角/背景/选区/亮暗集中 token；Appearance 一页；设置可搜 | 主题市场；第一版不做用户 CSS 外挂 | 改间距/圆角即时反映；亮暗无闪白；搜 spacing 能跳到项（假设切主题 <100ms） |
| **D 采集 UX** | BCStatusItem / droplet；Atlas Menu bar pin；macOS Share/Services | 窗/侧栏/状态栏均为 drop；落 Inbox；拖拽预览叠+计数；粘贴文件/图 | 浏览器扩展（P2）；完整 Share Extension 商店流程可后置 | 拖到菜单栏 → Inbox（假设 <500ms 可见）；拖到集合行进该集合；重复有提示 |
| **E Info / 色票** | digiKam 右侧栏分层；Atlas 1.7 色板；系统「显示简介」密度 | `I` 开合 Info；尺寸/体积/类型大字；标签/集合 chip；主色 swatch；点色可搜（可先 hex） | digiKam 直方图/ICC 全套；云端建议标签 | 单选完整元数据；多选交集可编辑；色票≥3；点色出列表 |
| **F 滚动性能** | NSCollectionView+Diffable；Nuke；PhotoPrism「只渲可见」 | cell 复用；缩略图异步+LRU；尺寸阶梯；稳定 ID；视口外不解码原图 | 死磕纯 LazyVGrid 扛 1万+；Web IntersectionObserver 原样搬 | 库≥1k 快滑无明显堆帧（假设 frame p95 <16ms）；内存不随滚到底线性爆；无主线程解码尖峰 |

## 切片（复刻 → 超车）

| 切片 | 目标 | 对标主轴 | 验收 |
|---|---|---|---|
| **P1a 网格手感** | 缩放密度 + 多选 + lightbox + 键鼠 | A | A 出门证 |
| **P1b 组织** | 嵌套/拖拽/Inbox/标签 | B | B |
| **P1c Info+色** | 右栏元数据与色票 | E | E |
| **P1d 外观** | tokens + 可搜设置 | C | C |
| **P1e 采集** | 拖放全路径 + 菜单栏 pin | D | D |
| **P1f 性能底** | 复用网格 + 阶梯缩略图（可与 a 并行埋点） | F | F；数字本机实测替换假设 |

建议施工顺序：**P1a → P1f 穿插 → P1b → P1c → P1d → P1e**（先能用网格，再组织与外观，采集收口）。

## 明确不做（本 P1）
iOS、付费壳、搬 Atlas 图标/字体、反编译、浏览器扩展完整版、语义搜、Canvas/Infinity（除非用户把它们提前进 P1-A）。

## 施工工具
本机 `~/.local/bin/pi` + `~/.grok/bin/grok`；每子阶段由 ghost 工头亲自跑命令验收。
