# FrameLibrary

截图与录屏「设备外壳」的整图仓库，**不打进 app 包**。

- 应用包内只放最常用的几款整图（MacBook Pro 14/16、iPhone 17）和全部 320px 缩略图，
  清单在 `Resources/DeviceFrames/frames.json`，标了 `"remote": true` 的条目从这里下载。
- 下载地址：`https://raw.githubusercontent.com/CaryK753/Aurora/v<版本号>/FrameLibrary/<文件>`
  （版本 tag 里没有时退回 `main`）。落地到 `~/Library/Application Support/Aurora/DeviceFrames/`，之后和内置外壳一样用。
- 新增机型：把 Apple 官方设计资源里的 PNG 放进本目录（长边 ≤ 3400），
  在 `Resources/DeviceFrames/frames.json` 里补一条 `remote: true`，
  再用 `sips -Z 320 <file> --out Resources/DeviceFrames/thumbs/<file>` 生成缩略图。
- `build.sh` 会核对：内置款 PNG 在包里、`remote` 款 PNG 在本目录、每款都有缩略图，缺一个直接构建失败。
- 素材版权见 `Resources/DeviceFrames/LICENSE-Apple.rtf`（Apple 官方设计资源的使用条款）。
