# komari-build-docker

komari面板专用自动打包成Docker镜像并推送至Docker Hub

本脚本会帮你实现自给自足打包自己专属的Docker镜像

本脚本内置直接关联原项目[komari](https://github.com/komari-monitor/komari)  随时运行随时拉取最新项目

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xymn2023/komari-build-docker/main/build-docker.sh)
```

**说明**：脚本中内置了可以在运行脚本目录生成docker-compose.yml文件


****

**常见问题**



[INFO] 开始编译过程...

[INFO] 执行基础编译测试...

[ERROR] 基础编译测试失败，请检查Go环境和项目代码

[ERROR] 后端构建失败，停止构建流程


解决方法：安装 C 语言的构建工具包  

```
sudo apt-get update
```

```
sudo apt-get install build-essential -y
```


