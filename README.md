# Ruminote 如觅书摘 · KOReader 插件

**简体中文** | [English](README.en.md)

> 好句子，值得再嚼一遍。

[KOReader](https://github.com/koreader/koreader) 阅读器插件：把你在电子书上的划线自动同步到 **Rumi书摘** 云端，随时在微信小程序里回看、反复咀嚼。

## 🚧 当前状态

**Rumi书摘小程序尚未正式上线，同步功能暂时无法使用。** 小程序上线后本插件会更新说明，届时即可绑定使用。你现在可以先安装插件，等待上线通知。

## ⚠️ 使用前提

本插件是 **Rumi书摘** 微信小程序的 KOReader 同步客户端，**不是独立工具**：

- 需要先有 Rumi书摘小程序账号（微信搜索「Rumi书摘」，*上线后可用*）
- 绑定时需在小程序里生成 **6 位配对码**，插件输入后完成设备绑定
- 划线数据同步到 Rumi书摘云端，仅本人可见

如果你只想要纯本地的高亮导出、不接入 Rumi书摘，本插件不适合你。

## 功能

- KOReader 工具菜单加入「Ruminote 如觅书摘」入口：绑定账号 / 立即同步 / 查看待上传 / 关于
- **自动同步**：定时（每 10 分钟）+ 关书 / 挂起 / 唤醒 + 划线时（部分版本）+ 手动，全部静默；联网即传，离线留队列
- **增量上传**：本地记录已同步指纹，只传新增的划线，不重复上传
- **幂等去重**：每条书摘 `highlight_id` 由 `fingerprint.lua` 的 sha256 指纹计算，与云端一致，后端二次去重
- **6 位配对码绑定**：换取长期 `device_token`；一台设备全局唯一归属，换绑需先在原账号小程序解绑

## 安装

### 方式一：App Store 插件（推荐，需先装 AppStore）

如果你已安装社区的 [AppStore 插件](https://github.com/omer-faruq/appstore.koplugin)：

1. KOReader → 工具 → **App Store** → Plugins
2. 搜索 `ruminote` 或 `Ruminote`，找到本插件 → **Install**
3. 重启 KOReader

### 方式二：手动安装（通用）

1. 从 [Releases](https://gitee.com/ruminote/koreader-plugin/releases) 下载 `ruminote.koplugin.zip` 并解压，得到 `ruminote.koplugin/` 文件夹
2. 放进 KOReader 的 `plugins/` 目录：
   - **Android**：`/sdcard/koreader/plugins/`
   - **Kobo / Kindle**：`koreader/plugins/`
   - **桌面 (Linux)**：`~/.config/koreader/plugins/`
   - ⚠️ 确保是 `plugins/ruminote.koplugin/main.lua`，不要多套一层目录
3. 完全重启 KOReader（杀进程重开，非返回）
4. 阅读界面 → 工具菜单 → 找到「Ruminote 如觅书摘」

### 绑定

小程序「我的 → 我的设备 → 绑定新设备」生成 6 位配对码 → 插件「绑定账号」输入 → 绑定成功后划线自动同步。

## 文件

```
_meta.lua        # 插件元信息（显示名 / 描述 / 版本）
main.lua         # 主体：菜单、离线队列、增量/自动同步、绑定
fingerprint.lua  # sha256 书摘指纹（与云端一致，用于幂等去重）
```

> 内部标识符为 `ruminate`；用户可见品牌名为 **Ruminote 如觅书摘**。

## 兼容性

- 需要较新稳定版 KOReader（使用 `annotations` 表）
- `onSaveHighlight` 在部分版本不触发 → 已改为同步时主动扫描当前书 annotations（多来源兜底）+ 定时/关书兜底

## 相关

- 小程序端：微信搜索「Rumi书摘」（*上线后可用*）

## License

GPL-3.0（见 LICENSE）。
