# Ruminote 如觅书摘 · KOReader 插件

> 好句子，值得再嚼一遍。

[KOReader](https://github.com/koreader/koreader) 阅读器插件：把你在电子书上的划线自动收进 Ruminote 云端，随时在小程序里回看、反复咀嚼。

## 功能

- 在 KOReader 主菜单（工具）加入「Ruminote 如觅书摘」入口：绑定账号 / 立即同步 / 查看队列 / 关于
- **离线优先**：新增划线先写本地上传队列，联网时批量上传（应对 e-ink 设备间歇 Wi-Fi）
- **幂等上传**：每条书摘的 `highlight_id` 由 `fingerprint.lua` 的 sha256 指纹计算，与云端 JS 实现一致，后端去重
- **6 位配对码绑定**：换取长期 `device_token` 持久化到插件设置

## 文件

```
koplugin/
├── _meta.lua         # 插件元信息（显示名 / 描述）
├── main.lua          # 主体：菜单、离线队列、批量上传、绑定
└── fingerprint.lua   # sha256 书摘指纹（与云端一致，用于幂等去重）
```

> 内部标识符为 `ruminate`（`name = "ruminate"`）；用户可见品牌名为 **Ruminote 如觅书摘**。

## 安装

1. 把 `koplugin/` 打包为 `ruminote.koplugin`（或复制目录）放进 KOReader 的 `plugins/` 目录
   - 目录名须以 `.koplugin` 结尾，例如 `plugins/ruminote.koplugin/`
2. 重启 KOReader，在 阅读界面 → 工具菜单 找到「Ruminote 如觅书摘」
3. 首次使用：小程序生成 6 位配对码 → 插件「绑定账号」输入 → 绑定成功后划线自动同步

## 配置

- 插件顶部 `API_BASE` 指向 CloudBase HTTP 访问服务地址（`/ruminateapi` 路由）
- 上传请求带 `X-Device-Token` 头鉴权

## 兼容性

- 锁定较新稳定版 KOReader（使用 `annotations` 表）
- `onSaveHighlight` 在部分版本不触发 → 已改为同步时主动扫描当前书 annotations（多来源兜底）

## 相关仓库

- 小程序端：`gitee.com/ruminote/wx-miniprogram`
