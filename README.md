# macOS 双摄像头采集工作台

在 macOS 上预览、调试和定时采集两路 USB 摄像头，按时间浏览配对原图。支持调焦、色彩匹配、镜头及透视校正与局部导出。

## 构建与使用

需要 macOS 和 Xcode Command Line Tools。可用 `xcode-select --install` 安装工具，然后从仓库根目录运行：

```bash
bash outputs/camera-preview/build.sh
open "outputs/camera-preview/双摄像头预览.app"
```

首次打开时，在系统提示中授权摄像头访问。详见[使用说明](outputs/camera-preview/使用说明.md)。预览程序会编译相邻目录中的 `CameraCollector.swift`，因此两个目录应保持当前相对位置。

## 独立采集

```bash
bash outputs/camera-collector/build.sh
bash outputs/camera-collector/camera-collector.sh probe
```

`probe` 用于检查设备。确认设备和权限后，可用 `setup` 安装每小时运行的后台任务，`status` 查看状态，`stop` 停止任务。首次运行应先检查现有采集设置。

采集数据、运行日志、设备配置和个人校准参数存放于本地的 `~/Library/Application Support/CameraCollector/`。源码中的 `uvc-write-verification.json` 默认为空对象，具体设备的写入验证记录由使用者自行维护。两个应用的二进制文件和签名由构建脚本生成。
