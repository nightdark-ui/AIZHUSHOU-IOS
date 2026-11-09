# AI小助手 · iOS 独立版

纯本地运行的库存助手：数据直连 WPS 表格，本地查询，不依赖电脑和服务器。

## 现状（第一阶段）

- [x] 项目骨架（SwiftUI + XcodeGen + GitHub Actions）
- [x] 设置页：填 WPS 令牌 / 文件 ID / 脚本 ID
- [x] 同步：直连 WPS AirScript 拉库存 + 价格
- [x] 库存列表：搜索、下拉刷新
- [ ] 本地 SQLite 持久化（现在用 JSON）
- [ ] 补货计算 + 快照
- [ ] 编号查询规则（有没有300 / 多少钱 / 有货吗）
- [ ] DeepSeek 对话
- [ ] 与电脑版双向同步"已确认"

## 编译

推送到 `main` 后，GitHub Actions 自动编译，产物在 Actions 页面的 Artifacts 里下载 `AIZhushou.ipa`。

本地编译（需要 Mac）：

```bash
brew install xcodegen
xcodegen generate
open AIZhushou.xcodeproj
```

## 安装到 iPhone

用 Sideloadly（Windows）+ 免费 Apple ID 签名安装，7 天有效。
长期自动续签用 SideStore（需要电脑跑 AltServer）。

## 目录

```
Sources/
  AIZhushouApp.swift   入口
  Models.swift         数据模型
  WPSClient.swift      WPS AirScript 请求
  AppStore.swift       状态 + 本地存储
  RootView.swift       底部 Tab
  InventoryView.swift  库存列表
  SettingsView.swift   设置
```
