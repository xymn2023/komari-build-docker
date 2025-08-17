#!/bin/bash

# Komari项目Docker镜像自动构建脚本
# 作者: AI Assistant
# 用途: 自动化构建和推送komari项目的Docker镜像

set -e  # 遇到错误立即退出

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 全局变量
DOCKER_USERNAME=""
IMAGE_NAME=""
IMAGE_TAG="latest"  # 默认标签
FULL_IMAGE_NAME=""

# 打印带颜色的消息
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查并安装必要的工具
check_requirements() {
    print_info "检查必要的工具..."
    local missing_tools=()
    local need_install=false
    local need_reload_env=false
    
    # 检查Docker
    if ! command -v docker &> /dev/null; then
        print_warning "Docker未安装，正在自动安装..."
        missing_tools+=("docker")
        need_install=true
    else
        print_success "Docker已安装: $(docker --version)"
    fi
    
    # 检查Node.js
    if ! command -v node &> /dev/null; then
        print_warning "Node.js未安装，正在自动安装..."
        missing_tools+=("nodejs")
        need_install=true
    else
        print_success "Node.js已安装: $(node --version)"
    fi
    
    # 检查npm
    if ! command -v npm &> /dev/null; then
        print_warning "npm未安装，正在自动安装..."
        missing_tools+=("npm")
        need_install=true
    else
        print_success "npm已安装: $(npm --version)"
    fi
    
    # 检查Go
    if ! command -v go &> /dev/null; then
        print_warning "Go未安装，正在自动安装..."
        missing_tools+=("golang")
        need_install=true
    else
        print_success "Go已安装: $(go version)"
    fi
    
    # 检查git
    if ! command -v git &> /dev/null; then
        print_warning "Git未安装，正在自动安装..."
        missing_tools+=("git")
        need_install=true
    else
        print_success "Git已安装: $(git --version)"
    fi
    
    # 如果有缺失的工具，自动安装
    if [ "$need_install" = true ]; then
        echo
        print_info "开始自动安装缺失的工具: ${missing_tools[*]}"
        install_missing_tools "${missing_tools[@]}"
        need_reload_env=true
    else
        print_success "所有必要工具检查通过"
    fi
    
    # 检查Docker Buildx
    check_docker_buildx
    
    # 如果安装了新工具，重新加载环境变量
    if [ "$need_reload_env" = true ]; then
        reload_environment
    fi
}

# 重新加载环境变量
reload_environment() {
    print_info "重新加载环境变量..."
    
    # 重新加载bashrc
    if [ -f ~/.bashrc ]; then
        source ~/.bashrc
    fi
    
    # 重新加载profile
    if [ -f ~/.profile ]; then
        source ~/.profile
    fi
    
    # 更新当前会话的PATH
    export PATH="/usr/local/go/bin:$PATH"
    export PATH="/usr/local/bin:$PATH"
    
    print_success "环境变量已重新加载"
    
    # 重新验证工具安装
    print_info "重新验证工具安装状态..."
    
    if command -v docker &> /dev/null; then
        print_success "Docker验证成功: $(docker --version)"
    fi
    
    if command -v node &> /dev/null; then
        print_success "Node.js验证成功: $(node --version)"
    fi
    
    if command -v npm &> /dev/null; then
        print_success "npm验证成功: $(npm --version)"
    fi
    
    if command -v go &> /dev/null; then
        print_success "Go验证成功: $(go version)"
    fi
    
    if command -v git &> /dev/null; then
        print_success "Git验证成功: $(git --version)"
    fi
}

# 安装缺失的工具（无需用户确认）
install_missing_tools() {
    local tools=("$@")
    print_info "开始自动安装缺失的工具..."
    
    # 检测操作系统
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        install_tools_linux_auto "${tools[@]}"
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        install_tools_macos_auto "${tools[@]}"
    elif [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "cygwin" ]] || [[ "$OSTYPE" == "win32" ]]; then
        install_tools_windows_auto "${tools[@]}"
    else
        print_error "不支持的操作系统: $OSTYPE"
        print_info "请手动安装以下工具:"
        for tool in "${tools[@]}"; do
            echo "  - $tool"
        done
        return 1
    fi
}

# Linux系统自动安装工具
install_tools_linux_auto() {
    local tools=("$@")
    
    # 检测包管理器
    if command -v apt-get &> /dev/null; then
        print_info "使用apt-get自动安装工具..."
        
        # 更新包列表
        print_info "更新包列表..."
        sudo apt-get update -qq
        
        for tool in "${tools[@]}"; do
            case $tool in
                "docker")
                    print_info "自动安装Docker..."
                    curl -fsSL https://get.docker.com -o get-docker.sh
                    sudo sh get-docker.sh > /dev/null 2>&1
                    sudo usermod -aG docker $USER
                    rm get-docker.sh
                    
                    # 启动Docker服务
                    sudo systemctl start docker > /dev/null 2>&1
                    sudo systemctl enable docker > /dev/null 2>&1
                    
                    print_success "Docker安装完成"
                    ;;
                "nodejs")
                    print_info "自动安装Node.js..."
                    curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash - > /dev/null 2>&1
                    sudo apt-get install -y nodejs > /dev/null 2>&1
                    print_success "Node.js安装完成"
                    ;;
                "npm")
                    print_info "npm通常随Node.js一起安装"
                    ;;
                "golang")
                    print_info "自动安装Go..."
                    
                    # 下载最新版本的Go
                    GO_VERSION="1.21.5"
                    wget -q https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz
                    
                    # 删除旧版本并安装新版本
                    sudo rm -rf /usr/local/go
                    sudo tar -C /usr/local -xzf go${GO_VERSION}.linux-amd64.tar.gz
                    
                    # 设置环境变量
                    if ! grep -q '/usr/local/go/bin' ~/.bashrc; then
                        echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
                    fi
                    
                    if ! grep -q '/usr/local/go/bin' ~/.profile; then
                        echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.profile
                    fi
                    
                    # 立即应用到当前会话
                    export PATH=$PATH:/usr/local/go/bin
                    
                    rm go${GO_VERSION}.linux-amd64.tar.gz
                    print_success "Go安装完成并已设置环境变量"
                    ;;
                "git")
                    print_info "自动安装Git..."
                    sudo apt-get install -y git > /dev/null 2>&1
                    print_success "Git安装完成"
                    ;;
            esac
        done
        
    elif command -v yum &> /dev/null; then
        print_info "使用yum自动安装工具..."
        
        for tool in "${tools[@]}"; do
            case $tool in
                "docker")
                    print_info "自动安装Docker..."
                    sudo yum install -y docker > /dev/null 2>&1
                    sudo systemctl start docker > /dev/null 2>&1
                    sudo systemctl enable docker > /dev/null 2>&1
                    sudo usermod -aG docker $USER
                    print_success "Docker安装完成"
                    ;;
                "nodejs")
                    print_info "自动安装Node.js..."
                    curl -fsSL https://rpm.nodesource.com/setup_lts.x | sudo bash - > /dev/null 2>&1
                    sudo yum install -y nodejs > /dev/null 2>&1
                    print_success "Node.js安装完成"
                    ;;
                "golang")
                    print_info "自动安装Go..."
                    sudo yum install -y golang > /dev/null 2>&1
                    print_success "Go安装完成"
                    ;;
                "git")
                    print_info "自动安装Git..."
                    sudo yum install -y git > /dev/null 2>&1
                    print_success "Git安装完成"
                    ;;
            esac
        done
    else
        print_error "未找到支持的包管理器 (apt-get/yum)"
        return 1
    fi
    
    print_success "所有工具安装完成"
}

# macOS系统自动安装工具
install_tools_macos_auto() {
    local tools=("$@")
    
    # 检查是否安装了Homebrew，如果没有则自动安装
    if ! command -v brew &> /dev/null; then
        print_info "自动安装Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" > /dev/null 2>&1
        
        # 设置Homebrew环境变量
        if [[ -f "/opt/homebrew/bin/brew" ]]; then
            eval "$(/opt/homebrew/bin/brew shellenv)"
            echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
        fi
        
        print_success "Homebrew安装完成"
    fi
    
    print_info "使用Homebrew自动安装工具..."
    
    for tool in "${tools[@]}"; do
        case $tool in
            "docker")
                print_info "自动安装Docker..."
                brew install --cask docker > /dev/null 2>&1
                print_success "Docker安装完成，请手动启动Docker Desktop"
                ;;
            "nodejs")
                print_info "自动安装Node.js..."
                brew install node > /dev/null 2>&1
                print_success "Node.js安装完成"
                ;;
            "golang")
                print_info "自动安装Go..."
                brew install go > /dev/null 2>&1
                print_success "Go安装完成"
                ;;
            "git")
                print_info "自动安装Git..."
                brew install git > /dev/null 2>&1
                print_success "Git安装完成"
                ;;
        esac
    done
}

# Windows系统自动安装工具
install_tools_windows_auto() {
    local tools=("$@")
    
    print_info "Windows系统检测到，尝试使用winget自动安装..."
    
    for tool in "${tools[@]}"; do
        case $tool in
            "docker")
                print_info "自动安装Docker Desktop..."
                if command -v winget &> /dev/null; then
                    winget install Docker.DockerDesktop --silent > /dev/null 2>&1
                    print_success "Docker Desktop安装完成"
                else
                    print_warning "winget不可用，请手动安装Docker Desktop"
                    print_info "下载地址: https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe"
                fi
                ;;
            "nodejs")
                print_info "自动安装Node.js..."
                if command -v winget &> /dev/null; then
                    winget install OpenJS.NodeJS --silent > /dev/null 2>&1
                    print_success "Node.js安装完成"
                else
                    print_warning "winget不可用，请手动安装Node.js"
                    print_info "下载地址: https://nodejs.org/en/download/"
                fi
                ;;
            "golang")
                print_info "自动安装Go..."
                if command -v winget &> /dev/null; then
                    winget install GoLang.Go --silent > /dev/null 2>&1
                    print_success "Go安装完成"
                else
                    print_warning "winget不可用，请手动安装Go"
                    print_info "下载地址: https://golang.org/dl/"
                fi
                ;;
            "git")
                print_info "自动安装Git..."
                if command -v winget &> /dev/null; then
                    winget install Git.Git --silent > /dev/null 2>&1
                    print_success "Git安装完成"
                else
                    print_warning "winget不可用，请手动安装Git"
                    print_info "下载地址: https://git-scm.com/download/win"
                fi
                ;;
        esac
    done
}

# 检查Docker Buildx
check_docker_buildx() {
    print_info "检查Docker Buildx..."
    
    if ! docker buildx version &> /dev/null; then
        print_warning "Docker Buildx未安装或未启用"
        print_info "尝试启用Docker Buildx..."
        
        # 创建并使用buildx实例
        docker buildx create --name multiarch --driver docker-container --use 2>/dev/null || true
        docker buildx inspect --bootstrap
        
        if docker buildx version &> /dev/null; then
            print_success "Docker Buildx已启用"
        else
            print_error "无法启用Docker Buildx，请检查Docker安装"
            exit 1
        fi
    else
        print_success "Docker Buildx已可用: $(docker buildx version)"
    fi
}

# 获取Docker Hub用户名
get_docker_username() {
    echo
    print_info "请输入您的Docker Hub用户名:"
    echo -e "${YELLOW}示例: myusername, mycompany, john-doe${NC}"
    read -p "Docker Hub用户名: " DOCKER_USERNAME
    
    if [ -z "$DOCKER_USERNAME" ]; then
        print_error "Docker Hub用户名不能为空"
        get_docker_username
        return
    fi
    
    # 验证用户名格式 (Docker Hub用户名规则)
    if [[ ! $DOCKER_USERNAME =~ ^[a-z0-9]+([._-][a-z0-9]+)*$ ]]; then
        print_error "用户名格式不正确，只能包含小写字母、数字、点、下划线和连字符，且不能以特殊字符开头或结尾"
        get_docker_username
        return
    fi
    
    print_success "Docker Hub用户名: $DOCKER_USERNAME"
}

# 获取镜像名称
get_image_name() {
    echo
    print_info "请输入Docker镜像名称 (不包含用户名和标签):"
    echo -e "${YELLOW}示例: komari, komari-monitor, my-komari${NC}"
    read -p "镜像名称: " IMAGE_NAME
    
    if [ -z "$IMAGE_NAME" ]; then
        print_error "镜像名称不能为空"
        get_image_name
        return
    fi
    
    # 验证镜像名称格式
    if [[ ! $IMAGE_NAME =~ ^[a-z0-9]+([._-][a-z0-9]+)*$ ]]; then
        print_error "镜像名称格式不正确，只能包含小写字母、数字、点、下划线和连字符"
        get_image_name
        return
    fi
    
    print_success "镜像名称: $IMAGE_NAME"
}

# 获取镜像标签
get_image_tag() {
    echo
    print_info "请输入镜像标签 (直接回车使用默认值 'latest'):"
    echo -e "${YELLOW}示例: latest, v1.0.0, dev, stable, $(date +%Y%m%d)${NC}"
    echo -e "${YELLOW}当前默认: latest${NC}"
    read -p "镜像标签 [latest]: " input_tag
    
    # 如果用户直接回车，使用默认值
    if [ -z "$input_tag" ]; then
        IMAGE_TAG="latest"
        print_success "使用默认标签: $IMAGE_TAG"
    else
        # 验证标签格式 (Docker标签规则)
        if [[ ! $input_tag =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
            print_error "标签格式不正确，只能包含字母、数字、点、下划线和连字符，且必须以字母或数字开头"
            get_image_tag
            return
        fi
        
        # 检查标签长度 (Docker标签最大128字符)
        if [ ${#input_tag} -gt 128 ]; then
            print_error "标签长度不能超过128个字符"
            get_image_tag
            return
        fi
        
        IMAGE_TAG="$input_tag"
        print_success "自定义标签: $IMAGE_TAG"
    fi
}

# 获取镜像信息 (用户名 + 镜像名 + 标签)
get_image_info() {
    get_docker_username
    get_image_name
    get_image_tag
    
    FULL_IMAGE_NAME="${DOCKER_USERNAME}/${IMAGE_NAME}:${IMAGE_TAG}"
    
    echo
    print_info "镜像信息确认:"
    echo -e "  Docker Hub用户名: ${GREEN}$DOCKER_USERNAME${NC}"
    echo -e "  镜像名称: ${GREEN}$IMAGE_NAME${NC}"
    echo -e "  镜像标签: ${GREEN}$IMAGE_TAG${NC}"
    echo -e "  完整镜像名: ${GREEN}$FULL_IMAGE_NAME${NC}"
    echo
    
    print_info "信息是否正确? (y/n)"
    read -p "请确认: " confirm
    
    case $confirm in
        [Yy]* )
            print_success "镜像信息确认完成"
            ;;
        [Nn]* )
            print_info "重新输入镜像信息"
            get_image_info
            ;;
        * )
            print_warning "无效选择，默认确认"
            ;;
    esac
}

# 保存配置到文件 (包含标签)
save_config() {
    local config_file=".docker-build-config"
    
    echo
    print_info "是否保存配置以便下次使用? (y/n)"
    read -p "请选择: " save_choice
    
    case $save_choice in
        [Yy]* )
            echo "DOCKER_USERNAME=$DOCKER_USERNAME" > "$config_file"
            echo "IMAGE_NAME=$IMAGE_NAME" >> "$config_file"
            echo "IMAGE_TAG=$IMAGE_TAG" >> "$config_file"
            print_success "配置已保存到 $config_file"
            ;;
        [Nn]* )
            print_info "跳过保存配置"
            ;;
        * )
            print_warning "无效选择，跳过保存"
            ;;
    esac
}

# 加载已保存的配置 (包含标签)
load_config() {
    local config_file=".docker-build-config"
    
    if [ -f "$config_file" ]; then
        print_info "发现已保存的配置文件"
        source "$config_file"
        
        # 如果配置文件中没有标签，设置默认值
        if [ -z "$IMAGE_TAG" ]; then
            IMAGE_TAG="latest"
        fi
        
        if [ -n "$DOCKER_USERNAME" ] && [ -n "$IMAGE_NAME" ]; then
            FULL_IMAGE_NAME="${DOCKER_USERNAME}/${IMAGE_NAME}:${IMAGE_TAG}"
            
            echo
            print_info "上次使用的配置:"
            echo -e "  Docker Hub用户名: ${GREEN}$DOCKER_USERNAME${NC}"
            echo -e "  镜像名称: ${GREEN}$IMAGE_NAME${NC}"
            echo -e "  镜像标签: ${GREEN}$IMAGE_TAG${NC}"
            echo -e "  完整镜像名: ${GREEN}$FULL_IMAGE_NAME${NC}"
            echo
            
            print_info "是否使用上次的配置? (y/n)"
            read -p "请选择: " use_saved
            
            case $use_saved in
                [Yy]* )
                    print_success "使用已保存的配置"
                    return 0
                    ;;
                [Nn]* )
                    print_info "重新输入配置"
                    DOCKER_USERNAME=""
                    IMAGE_NAME=""
                    IMAGE_TAG="latest"
                    FULL_IMAGE_NAME=""
                    ;;
                * )
                    print_warning "无效选择，重新输入配置"
                    DOCKER_USERNAME=""
                    IMAGE_NAME=""
                    IMAGE_TAG="latest"
                    FULL_IMAGE_NAME=""
                    ;;
            esac
        fi
    fi
    
    return 1
}

# 构建前端
build_frontend() {
    print_info "开始构建前端..."
    
    # 检查是否已存在web目录
    if [ -d "web" ]; then
        print_warning "发现已存在的web目录，正在删除..."
        rm -rf web
    fi
    
    # 克隆前端项目
    print_info "克隆前端项目..."
    git clone https://github.com/komari-monitor/komari-web web
    
    # 构建前端
    cd web
    print_info "安装前端依赖..."
    npm install
    
    print_info "构建前端项目..."
    npm run build
    
    cd ..
    
    # 复制构建结果
    print_info "复制前端构建结果..."
    mkdir -p public/dist
    cp -r web/dist/* public/dist/
    
    print_success "前端构建完成"
}

# 构建后端二进制文件
build_backend() {
    print_info "开始构建后端二进制文件..."
    
    # 设置环境变量
    export GOOS=linux
    export CGO_ENABLED=1
    export GIN_MODE=release
    
    # 获取版本信息
    VERSION=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    VERSION_HASH=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
    
    LDFLAGS="-s -w -X github.com/komari-monitor/komari/utils.CurrentVersion=${VERSION} -X github.com/komari-monitor/komari/utils.VersionHash=${VERSION_HASH}"
    
    print_info "构建 linux/amd64 二进制文件..."
    GOARCH=amd64 go build -trimpath -ldflags="$LDFLAGS" -o komari-linux-amd64
    
    print_info "构建 linux/arm64 二进制文件..."
    GOARCH=arm64 go build -trimpath -ldflags="$LDFLAGS" -o komari-linux-arm64
    
    print_success "后端二进制文件构建完成"
}

# 构建Docker镜像 (支持自定义标签)
build_docker_image() {
    print_info "开始构建Docker镜像: $FULL_IMAGE_NAME"
    
    # 构建多架构镜像
    docker buildx build \
        --platform linux/amd64,linux/arm64 \
        --tag "$FULL_IMAGE_NAME" \
        --load \
        .
    
    if [ $? -eq 0 ]; then
        print_success "Docker镜像构建成功: $FULL_IMAGE_NAME"
        
        # 如果不是latest标签，同时创建latest标签
        if [ "$IMAGE_TAG" != "latest" ]; then
            local latest_image="${DOCKER_USERNAME}/${IMAGE_NAME}:latest"
            print_info "同时创建latest标签: $latest_image"
            docker tag "$FULL_IMAGE_NAME" "$latest_image"
            
            if [ $? -eq 0 ]; then
                print_success "latest标签创建成功"
                echo
                print_info "可用的镜像标签:"
                echo -e "  ${GREEN}$FULL_IMAGE_NAME${NC} (主标签)"
                echo -e "  ${GREEN}$latest_image${NC} (latest标签)"
            fi
        fi
    else
        print_error "Docker镜像构建失败"
        return 1
    fi
}

# 推送到Docker Hub (支持多标签)
push_to_dockerhub() {
    echo
    print_info "是否要推送镜像到Docker Hub? (y/n)"
    read -p "请选择: " PUSH_CHOICE
    
    case $PUSH_CHOICE in
        [Yy]* )
            print_info "开始推送镜像到Docker Hub..."
            
            # 检查是否已登录Docker Hub
            if ! docker info | grep -q "Username: $DOCKER_USERNAME"; then
                print_info "请先登录Docker Hub (用户名: $DOCKER_USERNAME)"
                docker login --username "$DOCKER_USERNAME"
                
                if [ $? -ne 0 ]; then
                    print_error "Docker Hub登录失败"
                    return 1
                fi
            fi
            
            # 推送主标签
            print_info "推送镜像: $FULL_IMAGE_NAME"
            docker push "$FULL_IMAGE_NAME"
            
            if [ $? -eq 0 ]; then
                print_success "主标签推送成功: $FULL_IMAGE_NAME"
                
                # 如果存在latest标签且不是latest，也推送latest
                if [ "$IMAGE_TAG" != "latest" ]; then
                    local latest_image="${DOCKER_USERNAME}/${IMAGE_NAME}:latest"
                    if docker images --format "table {{.Repository}}:{{.Tag}}" | grep -q "$latest_image"; then
                        print_info "推送latest标签: $latest_image"
                        docker push "$latest_image"
                        
                        if [ $? -eq 0 ]; then
                            print_success "latest标签推送成功"
                        else
                            print_warning "latest标签推送失败"
                        fi
                    fi
                fi
                
                echo
                print_success "镜像推送完成!"
                print_info "您可以使用以下命令拉取镜像:"
                echo -e "${GREEN}docker pull $FULL_IMAGE_NAME${NC}"
                if [ "$IMAGE_TAG" != "latest" ]; then
                    echo -e "${GREEN}docker pull ${DOCKER_USERNAME}/${IMAGE_NAME}:latest${NC}"
                fi
                echo
                print_info "Docker Hub链接:"
                echo -e "${BLUE}https://hub.docker.com/r/$DOCKER_USERNAME/$IMAGE_NAME${NC}"
            else
                print_error "镜像推送失败"
                return 1
            fi
            ;;
        [Nn]* )
            print_info "跳过推送到Docker Hub"
            print_info "如需稍后推送，请使用以下命令:"
            echo -e "${GREEN}docker push $FULL_IMAGE_NAME${NC}"
            if [ "$IMAGE_TAG" != "latest" ]; then
                echo -e "${GREEN}docker push ${DOCKER_USERNAME}/${IMAGE_NAME}:latest${NC}"
            fi
            ;;
        * )
            print_warning "无效选择，跳过推送"
            ;;
    esac
}

# 清理临时文件
cleanup() {
    print_info "清理临时文件..."
    
    echo
    print_info "是否要清理构建过程中的临时文件? (y/n)"
    read -p "请选择: " CLEANUP_CHOICE
    
    case $CLEANUP_CHOICE in
        [Yy]* )
            print_info "清理中..."
            rm -rf web
            rm -f komari-linux-amd64 komari-linux-arm64
            print_success "临时文件清理完成"
            ;;
        [Nn]* )
            print_info "保留临时文件"
            ;;
        * )
            print_warning "无效选择，保留临时文件"
            ;;
    esac
}

# 显示菜单 (显示完整镜像信息)
show_menu() {
    echo
    echo -e "${BLUE}=== Komari Docker 镜像构建脚本 ===${NC}"
    if [ -n "$DOCKER_USERNAME" ] && [ -n "$IMAGE_NAME" ] && [ -n "$IMAGE_TAG" ]; then
        echo -e "${YELLOW}当前配置: $FULL_IMAGE_NAME${NC}"
    else
        echo -e "${YELLOW}尚未配置镜像信息${NC}"
    fi
    echo
    echo "请选择操作:"
    echo "1) 完整构建流程 (推荐)"
    echo "2) 配置镜像信息"
    echo "3) 仅构建前端"
    echo "4) 仅构建后端"
    echo "5) 仅构建Docker镜像"
    echo "6) 仅推送到Docker Hub"
    echo "7) 清理临时文件"
    echo "0) 退出"
    echo
}

# 主函数（修正版本 - 确保进入菜单循环）
main() {
    echo -e "${GREEN}欢迎使用 Komari Docker 镜像构建脚本!${NC}"
    
    # 检查必要工具
    check_requirements
    
    # 尝试加载已保存的配置
    load_config
    
    # 确保进入主循环，不自动退出
    while true; do
        show_menu
        read -p "请输入选项 (0-7): " choice
        
        case $choice in
            1)
                # 如果没有配置信息，先获取
                if [ -z "$DOCKER_USERNAME" ] || [ -z "$IMAGE_NAME" ] || [ -z "$IMAGE_TAG" ]; then
                    get_image_info
                fi
                
                build_frontend
                build_backend
                build_docker_image
                push_to_dockerhub
                save_config
                cleanup
                
                # 构建完成后不退出，继续显示菜单
                echo
                print_success "构建流程完成！"
                print_info "您可以继续使用其他功能或选择0退出"
                ;;
            2)
                get_image_info
                ;;
            3)
                build_frontend
                print_success "前端构建完成！"
                ;;
            4)
                build_backend
                print_success "后端构建完成！"
                ;;
            5)
                if [ -z "$DOCKER_USERNAME" ] || [ -z "$IMAGE_NAME" ] || [ -z "$IMAGE_TAG" ]; then
                    get_image_info
                fi
                build_docker_image
                print_success "Docker镜像构建完成！"
                ;;
            6)
                if [ -z "$DOCKER_USERNAME" ] || [ -z "$IMAGE_NAME" ] || [ -z "$IMAGE_TAG" ]; then
                    get_image_info
                fi
                push_to_dockerhub
                ;;
            7)
                cleanup
                ;;
            0)
                print_info "感谢使用 Komari Docker 构建脚本！"
                print_info "再见！"
                exit 0
                ;;
            *)
                print_error "无效选项，请重新选择"
                ;;
        esac
        
        echo
        read -p "按回车键继续..."
    done
}

# 运行主函数
main "$@"