# QuotaPulse · 额度脉搏

[English](./README_EN.md)

一个 macOS 菜单栏小工具，把 AI API 的额度/余额实时挂在你屏幕顶部，抬眼可见，不用切窗口、不用开网页。

目前支持 **GLM（智谱 BigModel）** 和 **DeepSeek**。

## 功能

- **GLM**：菜单栏直接显示 5 小时窗口和 7 天窗口的配额用量百分比（如 `32% / 18%`）。按剩余额度红黄绿变色（所剩无几 → 红色，快见底 → 黄色，充裕 → 绿色）。点开菜单看精确重置倒计时。
- **DeepSeek**：菜单栏显示账户余额 ¥。小圆点标示当前是否在高峰计费时段（每天 9:00–12:00、14:00–18:00 上海时间，×2 费率，红点 = 高峰，绿点 = 非高峰）。菜单内一键切换 Flash / Pro 模型。
- **自动刷新**：每 5 分钟拉取最新额度数据，每分钟更新显示颜色。
- **本地缓存**：离线也能显示上次成功拉取的数据。
- **纯菜单栏**：无 Dock 图标、无窗口、不打扰。菜单栏里一个数字，余光就知道状态。

## 环境要求

- macOS 12+
- Swift 工具链（从源码构建时需要）
- GLM（open.bigmodel.cn）或 DeepSeek 的 API key

## 快速开始

### 方式一：配合 CC Switch 使用（当前）

QuotaPulse 会自动从 [CC Switch](https://github.com/) 的本地数据库读取当前选中的渠道和 API key。如果你已经在用 CC Switch 管理多个 AI 编程工具渠道，装了 CC Switch 后直接启动 QuotaPulse 即可——它会自动识别你当前的 provider。

```bash
./build.sh
open ./outputs/QuotaPulse.app
```


### 方式二：独立使用（无需 CC Switch）

不想装 CC Switch？直接在 QuotaPulse 里填 API key 也能用。启动 app 后，如果没检测到任何 key，菜单里会出现「登录配置 API Key」项，点开一个登录窗口：

- **选择供应商**：GLM（智谱 BigModel）或 DeepSeek，下拉切换后下方会提示去哪获取 key（GLM 在 open.bigmodel.cn → API Keys，DeepSeek 在 platform.deepseek.com 用户中心）
- **粘贴 API Key**：安全输入框，内容不会明文显示
- **登录**：保存后立即刷新额度；key 存在 `~/.codex/.quota-pulse-config.json`

登录后菜单显示当前账号，并提供「重新登录」「退出登录」。退出登录会清除手动配置，自动回退到环境变量 / CC Switch 探测。

**配置优先级**：手动登录配置 > 环境变量（`GLM_API_KEY` / `ZHIPU_API_KEY` / `DEEPSEEK_API_KEY`）> CC Switch 数据库。也就是说不管你用哪种方式，QuotaPulse 都能拿到 key。

## 从源码构建

```bash
git clone https://github.com/Drok1015/quota-pulse.git
cd quota-pulse
./build.sh
open ./outputs/QuotaPulse.app
```

启动后静默运行在菜单栏，找到那个额度数字或余额金额即可。

## 工作原理

- 请求 GLM 的 `/api/monitor/usage/quota/limit` 或 DeepSeek 的 `/user/balance` 接口
- 从 CC Switch 的 SQLite 数据库（`~/.cc-switch/cc-switch.db`）读取 API key
- 在 macOS 菜单栏渲染一个数字或百分比，按剩余额度变色
- 下拉菜单展示详情：时间窗口、重置倒计时、高峰时段状态、余额明细、模型切换

## 技术栈

单文件 Swift 原生应用（约 500 行）。`swiftc -O` 编译。零外部依赖，仅使用 Foundation 和 Cocoa。

## License

MIT
