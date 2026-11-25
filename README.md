# NMR Studio

面向 Apple 芯片 Mac 的轻量一维核磁谱工作台。可读取 Bruker 原始 FID 和处理谱，完成化学位移定标、积分、标峰和专业谱图文本导出。谱图在本机处理。

## 下载与安装

1. 在[发行版](https://github.com/StephenQiu628/NMR-Studio/releases/latest)中下载 `NMR-Studio-0.5.1-macOS-arm64.zip`。
2. 解压后，将 `NMR Studio.app` 拖入「应用程序」，再打开。
3. 启动时会显示模拟氢谱，可以直接试用积分和标峰。

需要 **Apple 芯片 Mac，macOS 13 或更新版本**。下载包使用本地签名，尚未经过 Apple 公证。发行版附有 SHA-256 校验值，可用 `shasum -a 256 NMR-Studio-0.5.1-macOS-arm64.zip` 核对。

## 处理谱图

1. **打开**　直接打开 Bruker `fid`，保留同目录的 `acqus`。软件自动展宽、2 倍零填充、傅里叶变换、调相并评估基线。打开实验目录时优先读取已有的处理谱。也可直接打开 `1r`、双列 CSV、TSV、TXT 或 `.nmrstudio` 工程。
2. **定标**　选择「溶剂参考」和参考位点，在谱图上点峰并确认偏移。支持峰顶吸附、TFA-d 和自定义目标位移。
3. **积分与标峰**　沿 ppm 轴拖选积分区间，底部显示括线和数值。框选标峰时同时限定 ppm 和强度，顶部显示峰位，松手后矩形消失。可在「审阅峰组」检查峰形、半高宽、J 值和积分关联。
4. **导出**　「专业 TXT」使用当前标峰和积分生成可编辑草稿。核对频率与样品溶剂，再点「确认并导出」。可单独导出 ¹H 或 ¹³C。另支持全谱或当前范围 CSV、矢量 PDF，以及 1200 或 3600 像素 PNG。
5. **保存工程**　用 ⌘S 保存 `.nmrstudio`，保留输入数据、自动处理记录、定标、测量和报表草稿。操作记录可从「编辑」菜单查阅。

当前支持一维复数采集模式 QSIM 和 DQD，以及显式 `GRPDLY` 和部分旧式数字滤波参数。其他采集模式可尝试读取仪器导出的全幅 `1r` 或双列谱图。自动处理结果可结合谱图和状态栏核对。

## 从源码构建

在装有 Xcode 命令行工具的 Apple 芯片 Mac 上运行：

```bash
bash build.sh
bash test.sh
```

构建产物位于仓库根目录的 `NMR Studio.app`。测试使用合成谱，覆盖文件读写、频域处理、标峰与积分、工程保存和导出。

| 路径 | 内容 |
| --- | --- |
| `Sources/` | SwiftUI 界面、Bruker 读取、谱图处理、测量和导出 |
| `Tests/` | 自动化检查 |
| `Resources/` | macOS 应用图标 |
| `Tools/` | 图标生成工具 |

## 第三方致谢

ACME 调相代码包含对 [OpenReadout](https://github.com/openreadout/openreadout) 相关实现的适配。对应 MIT 许可证见 [第三方许可证](OpenReadout-LICENSE-MIT.txt)。
