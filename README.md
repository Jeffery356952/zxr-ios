# 镇邪人 iOS 客户端（免签名 IPA 构建）

这是一个极薄的 WKWebView 外壳，目标是把网页版客户端 + **922MB 资源包**打包成 iOS App，
效果和安卓「离线版 v5」一致：资源走本地，登录与战斗仍连服务器。

## 原理

```
┌──────────────────────────────────────────────┐
│ iOS App                                      │
│  ┌────────────────────────────────────────┐  │
│  │ WKWebView  →  http://127.0.0.1:18901/  │  │
│  └──────────────┬─────────────────────────┘  │
│                 │                            │
│      ┌──────────▼───────────┐                │
│      │ 内置 HTTP 服务        │                │
│      │  · 命中资源包 → 直接读│  web-static.pack│
│      │  · 其余请求 → 反向代理│───────────────►│ 118.89.182.49:81
│      └──────────────────────┘                │  (/  /auth/*  /ws)
└──────────────────────────────────────────────┘
```

- 资源包格式与安卓完全一致：`WebPack/web-static.pack` + `WebPack/web-index.json`
- 因为页面、接口、WebSocket 都从 `127.0.0.1` 同源出去，**登录 Cookie 和战斗长连接行为与网页版一致**
- 未命中资源包的文件会回落到线上，所以不会出现「缺文件进不去」

## 目录

```
ios/project.yml                  XcodeGen 工程描述
ios/Sources/AppDelegate.swift    启动
ios/Sources/GameViewController.swift  WebView 容器 / JS 弹窗 / 错误重试
ios/Sources/LocalHTTPServer.swift    本地 HTTP 服务 + 反向代理 + WebSocket 透传
ios/Sources/PackStore.swift      资源包索引与随机读
.github/workflows/build-ipa.yml  GitHub Actions：macOS 编译 → 未签名 ipa → 回传服务器
```

## 本地/CI 构建

CI 只编译**不含资源包**的空壳（~1MB），因为从国内往 GitHub 传 922MB 太慢。
资源包在服务器上注入：

1. Actions 里点 **Run workflow**（`with_pack` 保持 `false`）
2. 产物 `zxr-ios-unsigned-<note>.ipa` 会自动回传到服务器 `/data/zhengxiere/site/ipa/`
3. 在服务器上执行注入脚本，把 `WebPack/` 塞进 `Payload/ZXR.app/`：

```bash
bash /root/inject_pack.sh \
  /data/zhengxiere/site/ipa/zxr-ios-unsigned-app.ipa \
  /data/zhengxiere/site/ipa/zxr-ios-core922.ipa
```

4. 成品：`http://118.89.182.49:81/ipa/zxr-ios-core922.ipa`（约 923MB，未签名，送第三方签名）

`with_pack=true` 也能在 CI 里直接下载资源包，但国内带宽下要 40 分钟以上，不推荐。


## 签名

CI 产出的是**未签名** ipa（`CODE_SIGNING_ALLOWED=NO`），用于第三方签名服务或
Sideloadly 侧载。签名服务一般只需要 ipa 本体 + 他们自己的证书。

## 改服务器地址

`ios/Sources/LocalHTTPServer.swift` 顶部的两个常量：

```swift
static let upstreamHost = "118.89.182.49"
static let upstreamPort: UInt16 = 81
```

## 已知注意点

- iOS 内核进程被回收时（内存吃紧）WebView 会白屏，代码里已做自动重载
- 资源包以「不压缩」方式存放在 app bundle 里，安装后占用≈包体大小
- 首次进入仍需要联网（要登录、要握手）
