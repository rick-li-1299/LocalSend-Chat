# LocalSend Chat

非官方 Windows / Android 局域网聊天版，基于 [LocalSend](https://github.com/localsend/localsend)，保留 Apache 2.0 许可证及原作者版权。

[下载最终 Windows 版](https://github.com/rick-li-1299/LocalSend-Chat/releases/latest)

[下载 Android 版](https://github.com/rick-li-1299/LocalSend-Chat/releases/tag/android-v1.0.0)（Android 8.1 及以上、ARM64 手机）

- 设备间聊天、群聊、文字与文件传输。
- 本地聊天记录、搜索、备注、置顶及明确授权的可信设备接收。
- Windows 双击、Android 点击本机名称即可直接改名。
- Windows 启动时检查 GitHub 新版，点击“立即更新”下载、校验并重启；Android 下载新版 APK 后通过系统安装器升级。

仓库当前只维护 Windows / Android 聊天版所需源码、依赖、测试及打包流程。旧版本运行包、Flutter/Rust 工具链、构建缓存和个人聊天数据不纳入发布。

Android 版支持点击名称改名、群聊、系统返回手势，以及通过系统文件选择器发送文件和文件夹。APK 使用独立应用标识，可与官方 LocalSend 共存。Android 安装包的签名密钥留在维护者本机，CI 仅接收公开证书和签名结果。

Windows 使用请选择 Release 中的 EXE 安装包或 ZIP 便携包其中一种；Android 手机请选择 APK。[构建与更新说明](README_CHAT.md)。
