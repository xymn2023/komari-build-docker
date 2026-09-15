# komari-build-docker

komari面板专用自动打包成Docker镜像并推送至Docker Hub

本脚本会帮你实现自给自足打包自己专属的Docker镜像，已更新打包逻辑 支持官方最新打包流程.

本脚本内置直接关联原项目[komari](https://github.com/komari-monitor/komari)  随时运行随时拉取最新项目

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xymn2023/komari-build-docker/main/build-docker-source.sh)
```
