# 一览

macOS 菜单栏小工具：分应用音量控制 + 系统状态（CPU / 内存 / 磁盘 / 网络 / 电池与实时功率）+ AI 用量（Claude Code、Codex）。

- 左键：弹出面板（音量 / 状态 / AI 三页）
- 右键：选择菜单栏显示项、登录时启动、退出

## 构建

```bash
./build.sh
cp -R "build/一览.app" /Applications/
```

需要 macOS 14.2+、Swift 5.9+。Claude 套餐百分比读取钥匙串中 Claude Code 的登录（只读，不刷新令牌）。
