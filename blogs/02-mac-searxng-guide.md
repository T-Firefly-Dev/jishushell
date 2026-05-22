# [养虾指南 on Arm]Mac Mini玩转JishuShell - 搜索能力增强

---

> 上一篇我们完成了 JishuShell 的安装和第一次 AI 对话。本文将为 OpenClaw 配置 SearXNG 本地搜索引擎，让你的 AI Agent 拥有更精准、更省 Token 的搜索能力。

---

## 一、为什么需要搜索增强？

AI Agent 在回答实时性问题时需要联网搜索。默认情况下，OpenClaw 使用内置的 Web Fetch 工具逐页抓取网页内容，这种方式存在几个问题：

- **Token 消耗大**：每次搜索都要抓取完整网页，大量无关的 HTML 内容被送入模型上下文
- **多轮调用**：Agent 需要反复调用工具、逐个打开链接，一次简单搜索可能触发 5-6 次工具调用
- **结果不稳定**：直接抓取的网页结构各异，提取有效信息的质量参差不齐

**SearXNG** 是一个隐私优先的元搜索引擎，它聚合 Google、Bing、DuckDuckGo 等多个搜索引擎的结果，返回结构化的搜索摘要。配合 OpenClaw 使用后：

- **精准简洁**：直接返回搜索摘要，无需抓取完整网页
- **节省 Token**：单次工具调用即可获得高质量搜索结果，Token 消耗降低 80% 以上
- **响应更快**：减少多轮工具调用的延迟

---

## 二、安装 SearXNG

在 JishuShell 面板中，SearXNG 作为一个独立的容器应用安装，一键部署，无需手动配置 Docker。

### 2.1 安装应用

进入 JishuShell 面板，在应用列表中找到 **SearXNG**，点击安装。安装过程会自动拉取 Docker 镜像并启动服务。

![SearXNG 安装](./macos/02-searxng/searxng-install.png)

### 2.2 确认运行状态

安装完成后，SearXNG 会自动启动。在应用详情页可以看到运行状态为 **Running**。

![SearXNG 实例运行中](./macos/02-searxng/searxng-instance.png)

### 2.3 验证搜索功能

点击进入 SearXNG 的 Web 界面，输入关键词搜索，确认搜索功能正常工作。

![SearXNG 搜索界面](./macos/02-searxng/searxng-search.png)

---

## 三、配置 OpenClaw 使用 SearXNG

SearXNG 安装完成后，下一步不是去背 URL、记端口，而是让 JishuShell 帮你把 OpenClaw 和 SearXNG 连接起来。

这也是 JishuShell 很实用的一点: 应用和应用之间通过能力连接，配置视角更接近“把服务接起来”，而不是先去理解具体的地址、端口和 provider 细节。SearXNG 依然是独立应用，OpenClaw 只是绑定了一个“联网搜索”能力。以后换机器、迁移实例、重新导入或者替换搜索后端时，都不需要再手工回忆一遍 `localhost` 和端口号。

### 3.1 在概览页直接可看到本地能力

回到 JishuShell 概览页，可以看到系统已经自动识别出Searxng的搜索能力

![概览页推荐连接](./macos/02-searxng/overall-tips.png)

### 3.2 在 OpenClaw 实例中完成绑定

进入 OpenClaw 实例页后，顶部也能看到 **1项APP可连接** 的提示，说明 JishuShell 已经发现当前实例存在一个可直接接入的搜索能力。

![OpenClaw 实例提示可连接](./macos/02-searxng/app-connect.png)

打开连接配置，在 **联网搜索** 这一项里选择正在运行的 **SearXNG** 即可。

![在连接页选择 SearXNG](./macos/02-searxng/searxng-connect.png)

这样配置完成后，OpenClaw 使用的是 JishuShell 里的 SearXNG 实例，后续查看、切换和维护都在同一套连接界面里完成。它的好处很直接:

- **应用解耦**: OpenClaw 和 SearXNG 分别独立运行，各自升级和重装互不影响
- **连接可复用**: 同一台 SearXNG 可以继续提供给其他 Agent 实例使用
- **迁移更省心**: 导出、导入、迁移到另一台 Mac 时，不必重新手填搜索 URL

### 3.3 对比一下 OpenClaw 默认配置方式

如果按 OpenClaw 当前默认配置方式来接入搜索能力，可选 provider 其实很多。但这里有个很现实的问题: 多数 provider 要么本身就是付费服务，要么需要你手动申请 API Key，而且通常还带免费额度、调用次数或者速率限制。真正符合“免费、本地、无限制使用”这几个条件的，SearXNG 依然是最适合本地 AI 环境的一种方案。

如果要把它接到 OpenClaw 里，一般有两条路径。

第一种是在 `openclaw onboard` 阶段，先把搜索提供方切换成 **SearXNG Search**。

![Onboard 时选择 SearXNG 搜索提供方](./macos/02-searxng/searxng-openclaw-select.png)

然后继续填写 SearXNG 的 Base URL。

![Onboard 时填写 SearXNG Base URL](./macos/02-searxng/searxng-openclaw-config.png)

第二种是如果当时没有在 onboard 里配好，后面就需要进入 OpenClaw 的 **Config** 页面，手动修改 JSON，把搜索 provider 和插件配置补进去。

![OpenClaw JSON 配置](./macos/02-searxng/openclaw-json.png)

> **参考文档**: OpenClaw 官方 SearXNG 配置说明 👉 [https://docs.openclaw.ai/tools/searxng-search](https://docs.openclaw.ai/tools/searxng-search)

这种方式当然也能用，但前提是你需要自己理解 provider、URL 和对应配置项分别放在哪里。相比之下，JishuShell 的应用连接方式明显更便利: 先安装 SearXNG，再在界面里完成连接即可；后续要排查、替换、迁移，也都可以回到同一个连接入口处理，不需要重新走一遍 onboard，或者再回 JSON 文件里找配置字段。

---

## 四、效果对比：配了 SearXNG vs 没配 SearXNG

同样的搜索问题，配置 SearXNG 前后的差异非常明显。

### ✅ 配置 SearXNG 后：精准简洁

当 OpenClaw 配置了 SearXNG 后，搜索流程变得高效：

1. Agent 调用 `searxng-search` 工具，一次请求获取结构化搜索结果
2. 搜索引擎返回精炼的摘要信息，直接可用
3. Agent 基于摘要生成回答，整个过程仅需 **1 次工具调用**

![SearXNG 搜索 - 精准的搜索调用](./macos/02-searxng/search-with-searxng-1.png)

![SearXNG 搜索 - 简洁的结果返回](./macos/02-searxng/search-with-searxng-2.png)

可以看到，Agent 通过 SearXNG 获得了结构化的搜索摘要，直接给出了准确的回答，整个过程干净利落。

### ❌ 未配置 SearXNG：反复调用，大量无效信息

没有 SearXNG 时，OpenClaw 只能依赖内置的网页抓取工具。同样的问题，Agent 需要：

1. 使用web_fetch拼参数的方式，简洁使用搜索能力
2. 从大量 HTML 中提取有用信息
3. 如果信息不够，继续打开更多链接……

![无 SearXNG - 开始搜索](./macos/02-searxng/search-without-searxng-1.png)

![无 SearXNG - 反复抓取网页](./macos/02-searxng/search-without-searxng-2.png)

![无 SearXNG - 大量无关内容进入上下文](./macos/02-searxng/search-without-searxng-3.png)

![无 SearXNG - 继续抓取更多页面](./macos/02-searxng/search-without-searxng-4.png)

![无 SearXNG - 最终拼凑出回答](./macos/02-searxng/search-without-searxng-5.png)

可以看到，Agent 前后进行了 **3 次工具调用**，每次都抓取了大量网页内容，不仅响应速度慢，还消耗了大量 Token。

### 📊 对比总结

| 指标 | 配置 SearXNG | 未配置 SearXNG |
|------|-------------|---------------|
| 工具调用次数 | 1 次 | 3 次 |
| Token 消耗 | 低（结构化摘要） | 高（完整网页内容） |
| 响应速度 | 快（秒级） | 慢（多轮等待） |
| 结果质量 | 高（精准摘要） | 不稳定（依赖网页结构） |
| 上下文占用 | 小 | 大（容易超出上下文窗口） |

---

## 总结

SearXNG 是 JishuShell 上 OpenClaw 的最佳搜索搭档：

- **一键安装**：JishuShell 面板中直接安装，自动管理容器生命周期
- **零配置运维**：SearXNG 运行在本地容器中，隐私安全，无需外部 API Key
- **显著提升**：搜索 Token 消耗降低 80%+，工具调用次数大幅减少

如果你的 AI Agent 经常需要联网搜索，强烈建议安装 SearXNG。这可能是投入产出比最高的一次配置。
