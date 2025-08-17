#!/bin/bash

# Komari项目Docker镜像自动构建脚本
# 作者: AI Assistant
# 用途: 按照官方手工构建流程自动拉取、构建和推送komari项目的Docker镜像
# 系统: Linux (Debian/Ubuntu)
# 默认架构: x86_64/AMD64

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 全局变量
DOCKER_USERNAME=""
IMAGE_NAME=""
IMAGE_TAG="latest"
FULL_IMAGE_NAME=""
WORK_DIR=""
FRONTEND_PROJECT="komari-web"
BACKEND_PROJECT="komari"
FRONTEND_REPO="https://github.com/komari-monitor/komari-web.git"
BACKEND_REPO="https://github.com/komari-monitor/komari.git"
BUILDX_BUILDER="multiarch-builder"

# 系统架构检测和默认设置
SYSTEM_ARCH=$(uname -m)
case $SYSTEM_ARCH in
    x86_64)
        DEFAULT_PLATFORM="linux/amd64"
        PRIMARY_ARCH="amd64"
        SECONDARY_ARCH="arm64"
        ;;
    aarch64|arm64)
        DEFAULT_PLATFORM="linux/arm64"
        PRIMARY_ARCH="arm64"
        SECONDARY_ARCH="amd64"
        ;;
    *)
        DEFAULT_PLATFORM="linux/amd64"
        PRIMARY_ARCH="amd64"
        SECONDARY_ARCH="arm64"
        ;;
esac

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

# 显示系统信息
show_system_info() {
    print_info "=== 系统信息检测 ==="
    print_info "系统架构: $SYSTEM_ARCH"
    print_info "默认平台: $DEFAULT_PLATFORM"
    print_info "主要架构: $PRIMARY_ARCH"
    print_info "次要架构: $SECONDARY_ARCH"
    echo
}

# 初始化工作目录
init_work_directory() {
    print_info "初始化工作目录..."
    
    # 使用当前目录作为工作目录
    WORK_DIR="$(pwd)"
    print_info "工作目录: $WORK_DIR"
    
    # 检查是否有写权限
    if [ ! -w "$WORK_DIR" ]; then
        print_error "当前目录没有写权限: $WORK_DIR"
        return 1
    fi
    
    print_success "工作目录初始化完成"
    return 0
}

# 检查并安装必要的工具
check_requirements() {
    print_info "检查必要的工具..."
    local missing_tools=()
    local need_install=false
    
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
        local node_version=$(node --version | sed 's/v//')
        local major_version=$(echo $node_version | cut -d. -f1)
        if [ "$major_version" -lt 20 ]; then
            print_warning "Node.js版本过低 ($node_version)，需要20+，正在升级..."
            missing_tools+=("nodejs")
            need_install=true
        else
            print_success "Node.js已安装: $(node --version)"
        fi
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
        local go_version=$(go version | awk '{print $3}' | sed 's/go//')
        local major_version=$(echo $go_version | cut -d. -f1)
        local minor_version=$(echo $go_version | cut -d. -f2)
        if [ "$major_version" -lt 1 ] || ([ "$major_version" -eq 1 ] && [ "$minor_version" -lt 18 ]); then
            print_warning "Go版本过低 ($go_version)，需要1.18+，正在升级..."
            missing_tools+=("golang")
            need_install=true
        else
            print_success "Go已安装: $(go version)"
        fi
    fi
    
    # 检查git
    if ! command -v git &> /dev/null; then
        print_warning "Git未安装，正在自动安装..."
        missing_tools+=("git")
        need_install=true
    else
        print_success "Git已安装: $(git --version)"
    fi
    
    # 检查交叉编译工具
    check_cross_compile_tools
    
    # 如果有缺失的工具，自动安装
    if [ "$need_install" = true ]; then
        echo
        print_info "开始自动安装缺失的工具: ${missing_tools[*]}"
        install_missing_tools "${missing_tools[@]}"
    else
        print_success "所有必要工具检查通过"
    fi
    
    # 检查Docker Buildx
    check_docker_buildx
}

# 检查交叉编译工具
check_cross_compile_tools() {
    print_info "检查交叉编译工具..."
    
    # 根据系统架构检查对应的交叉编译工具
    if [ "$PRIMARY_ARCH" = "amd64" ] && [ "$SECONDARY_ARCH" = "arm64" ]; then
        # AMD64系统，检查ARM64交叉编译工具
        if ! command -v aarch64-linux-gnu-gcc &> /dev/null; then
            print_warning "ARM64交叉编译工具未安装，正在安装..."
            install_cross_compile_tools
        else
            print_success "ARM64交叉编译工具已安装"
        fi
    elif [ "$PRIMARY_ARCH" = "arm64" ] && [ "$SECONDARY_ARCH" = "amd64" ]; then
        # ARM64系统，检查AMD64交叉编译工具
        if ! command -v x86_64-linux-gnu-gcc &> /dev/null; then
            print_warning "AMD64交叉编译工具未安装，正在安装..."
            install_cross_compile_tools
        else
            print_success "AMD64交叉编译工具已安装"
        fi
    fi
}

# 安装交叉编译工具
install_cross_compile_tools() {
    print_info "安装交叉编译工具..."
    
    if command -v apt-get &> /dev/null; then
        sudo apt-get update -qq
        
        if [ "$PRIMARY_ARCH" = "amd64" ]; then
            # 在AMD64系统上安装ARM64交叉编译工具
            sudo apt-get install -y gcc-aarch64-linux-gnu g++-aarch64-linux-gnu
            print_success "ARM64交叉编译工具安装完成"
        elif [ "$PRIMARY_ARCH" = "arm64" ]; then
            # 在ARM64系统上安装AMD64交叉编译工具
            sudo apt-get install -y gcc-x86-64-linux-gnu g++-x86-64-linux-gnu
            print_success "AMD64交叉编译工具安装完成"
        fi
    else
        print_warning "无法自动安装交叉编译工具，将禁用CGO进行构建"
    fi
}

# 安装缺失的工具
install_missing_tools() {
    local tools=("$@")
    print_info "开始自动安装缺失的工具..."
    
    # 只支持Linux系统
    install_tools_linux "${tools[@]}"
}

# Linux系统安装工具
install_tools_linux() {
    local tools=("$@")
    
    if command -v apt-get &> /dev/null; then
        print_info "使用apt-get安装工具..."
        sudo apt-get update -qq
        
        for tool in "${tools[@]}"; do
            case $tool in
                "docker")
                    print_info "安装Docker..."
                    # 安装Docker官方GPG密钥
                    sudo apt-get install -y ca-certificates curl gnupg
                    sudo install -m 0755 -d /etc/apt/keyrings
                    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
                    sudo chmod a+r /etc/apt/keyrings/docker.gpg
                    
                    # 添加Docker仓库
                    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
                    
                    # 安装Docker
                    sudo apt-get update -qq
                    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
                    
                    # 添加用户到docker组
                    sudo usermod -aG docker $USER
                    
                    # 启动Docker服务
                    sudo systemctl start docker
                    sudo systemctl enable docker
                    
                    print_success "Docker安装完成"
                    ;;
                "nodejs")
                    print_info "安装Node.js 20+..."
                    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
                    sudo apt-get install -y nodejs
                    print_success "Node.js安装完成"
                    ;;
                "golang")
                    print_info "安装Go 1.21+..."
                    GO_VERSION="1.21.5"
                    
                    # 根据系统架构下载对应的Go版本
                    if [ "$SYSTEM_ARCH" = "x86_64" ]; then
                        GO_ARCH="amd64"
                    elif [ "$SYSTEM_ARCH" = "aarch64" ]; then
                        GO_ARCH="arm64"
                    else
                        GO_ARCH="amd64"  # 默认
                    fi
                    
                    wget -q https://go.dev/dl/go${GO_VERSION}.linux-${GO_ARCH}.tar.gz
                    sudo rm -rf /usr/local/go
                    sudo tar -C /usr/local -xzf go${GO_VERSION}.linux-${GO_ARCH}.tar.gz
                    
                    # 设置环境变量
                    if ! grep -q '/usr/local/go/bin' ~/.bashrc; then
                        echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
                    fi
                    
                    if ! grep -q '/usr/local/go/bin' ~/.profile; then
                        echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.profile
                    fi
                    
                    # 立即应用到当前会话
                    export PATH=$PATH:/usr/local/go/bin
                    
                    rm go${GO_VERSION}.linux-${GO_ARCH}.tar.gz
                    print_success "Go安装完成"
                    ;;
                "git")
                    print_info "安装Git..."
                    sudo apt-get install -y git
                    print_success "Git安装完成"
                    ;;
            esac
        done
    else
        print_error "不支持的Linux发行版，请手动安装必要工具"
        return 1
    fi
    
    print_success "所有工具安装完成"
}

# 检查并配置Docker Buildx（修复多架构构建问题）
check_docker_buildx() {
    print_info "检查并配置Docker Buildx..."
    
    # 检查Docker Buildx是否可用
    if ! docker buildx version &> /dev/null; then
        print_error "Docker Buildx未安装，请升级Docker到最新版本"
        return 1
    fi
    
    print_success "Docker Buildx已安装: $(docker buildx version)"
    
    # 检查是否已有多架构构建器
    if docker buildx ls | grep -q "$BUILDX_BUILDER"; then
        print_info "发现已存在的构建器: $BUILDX_BUILDER"
        # 检查构建器状态
        if docker buildx ls | grep "$BUILDX_BUILDER" | grep -q "running"; then
            print_success "构建器 $BUILDX_BUILDER 正在运行"
        else
            print_warning "构建器 $BUILDX_BUILDER 未运行，正在启动..."
            docker buildx inspect --bootstrap "$BUILDX_BUILDER" &> /dev/null || {
                print_warning "启动失败，重新创建构建器..."
                docker buildx rm "$BUILDX_BUILDER" &> /dev/null || true
                create_buildx_builder
            }
        fi
    else
        print_info "创建多架构构建器..."
        create_buildx_builder
    fi
    
    # 设置为默认构建器
    if docker buildx use "$BUILDX_BUILDER" &> /dev/null; then
        print_success "已切换到多架构构建器: $BUILDX_BUILDER"
    else
        print_error "无法切换到构建器: $BUILDX_BUILDER"
        return 1
    fi
    
    # 验证多架构支持
    print_info "验证多架构构建支持..."
    if docker buildx inspect | grep -q "linux/amd64" && docker buildx inspect | grep -q "linux/arm64"; then
        print_success "多架构构建支持已启用 (linux/amd64, linux/arm64)"
    else
        print_warning "多架构支持可能有问题，但将继续尝试构建"
    fi
}

# 创建Docker Buildx构建器
create_buildx_builder() {
    print_info "创建Docker Buildx构建器: $BUILDX_BUILDER"
    
    # 创建新的构建器实例
    if docker buildx create \
        --name "$BUILDX_BUILDER" \
        --driver docker-container \
        --platform linux/amd64,linux/arm64 \
        --use; then
        print_success "构建器创建成功: $BUILDX_BUILDER"
    else
        print_error "构建器创建失败"
        return 1
    fi
    
    # 启动并验证构建器
    print_info "启动构建器..."
    if docker buildx inspect --bootstrap "$BUILDX_BUILDER"; then
        print_success "构建器启动成功"
    else
        print_error "构建器启动失败"
        return 1
    fi
}

# 步骤1: 构建前端静态文件（按照官方文档）
build_frontend() {
    print_info "=== 步骤1: 构建前端静态文件 ==="
    
    cd "$WORK_DIR" || {
        print_error "无法切换到工作目录: $WORK_DIR"
        return 1
    }
    
    # 如果前端项目目录已存在，先删除
    if [ -d "$FRONTEND_PROJECT" ]; then
        print_warning "发现已存在的前端项目目录，正在删除..."
        rm -rf "$FRONTEND_PROJECT"
    fi
    
    # 克隆前端项目
    print_info "克隆前端项目: $FRONTEND_REPO"
    if git clone "$FRONTEND_REPO" "$FRONTEND_PROJECT"; then
        print_success "前端项目克隆成功"
    else
        print_error "前端项目克隆失败"
        return 1
    fi
    
    # 进入前端项目目录
    cd "$FRONTEND_PROJECT" || {
        print_error "无法进入前端项目目录"
        return 1
    }
    
    # 安装前端依赖
    print_info "安装前端依赖..."
    if npm install; then
        print_success "前端依赖安装成功"
    else
        print_error "前端依赖安装失败"
        return 1
    fi
    
    # 构建前端项目
    print_info "构建前端项目..."
    if npm run build; then
        print_success "前端项目构建成功"
    else
        print_error "前端项目构建失败"
        return 1
    fi
    
    # 验证构建结果
    if [ ! -d "dist" ]; then
        print_error "前端构建失败，未找到dist目录"
        return 1
    fi
    
    print_success "前端静态文件构建完成"
    return 0
}

# 步骤2: 构建后端（按照官方文档，优化架构支持）
build_backend() {
    print_info "=== 步骤2: 构建后端 ==="
    
    cd "$WORK_DIR" || {
        print_error "无法切换到工作目录: $WORK_DIR"
        return 1
    }
    
    # 如果后端项目目录已存在，先删除
    if [ -d "$BACKEND_PROJECT" ]; then
        print_warning "发现已存在的后端项目目录，正在删除..."
        rm -rf "$BACKEND_PROJECT"
    fi
    
    # 克隆后端项目
    print_info "克隆后端项目: $BACKEND_REPO"
    if git clone "$BACKEND_REPO" "$BACKEND_PROJECT"; then
        print_success "后端项目克隆成功"
    else
        print_error "后端项目克隆失败"
        return 1
    fi
    
    # 进入后端项目目录
    cd "$BACKEND_PROJECT" || {
        print_error "无法进入后端项目目录"
        return 1
    }
    
    # 验证项目结构
    if [ ! -f "go.mod" ] || [ ! -f "Dockerfile" ]; then
        print_error "后端项目结构不完整，缺少必要文件"
        return 1
    fi
    
    # 按照官方文档：将前端构建结果复制到后端项目的/public/dist目录
    print_info "复制前端静态文件到后端项目的/public/dist目录..."
    mkdir -p public/dist
    
    if [ -d "$WORK_DIR/$FRONTEND_PROJECT/dist" ]; then
        if cp -r "$WORK_DIR/$FRONTEND_PROJECT/dist"/* public/dist/; then
            print_success "前端静态文件复制成功"
        else
            print_error "前端静态文件复制失败"
            return 1
        fi
    else
        print_error "未找到前端构建结果目录: $WORK_DIR/$FRONTEND_PROJECT/dist"
        return 1
    fi
    
    # 获取版本信息
    VERSION=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    VERSION_HASH=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
    
    # 获取模块名称
    MODULE_NAME=$(grep '^module' go.mod | awk '{print $2}')
    print_info "Go模块: $MODULE_NAME"
    
    LDFLAGS="-s -w -X ${MODULE_NAME}/utils.CurrentVersion=${VERSION} -X ${MODULE_NAME}/utils.VersionHash=${VERSION_HASH}"
    
    # 构建主要架构二进制文件（优先构建当前系统架构）
    print_info "构建 linux/$PRIMARY_ARCH 二进制文件（主要架构）..."
    if [ "$PRIMARY_ARCH" = "amd64" ]; then
        if GOOS=linux GOARCH=amd64 CGO_ENABLED=1 go build -trimpath -ldflags="$LDFLAGS" -o komari-linux-amd64; then
            print_success "linux/amd64 二进制文件构建成功"
        else
            print_error "linux/amd64 二进制文件构建失败"
            return 1
        fi
    else
        if GOOS=linux GOARCH=arm64 CGO_ENABLED=1 go build -trimpath -ldflags="$LDFLAGS" -o komari-linux-arm64; then
            print_success "linux/arm64 二进制文件构建成功"
        else
            print_error "linux/arm64 二进制文件构建失败"
            return 1
        fi
    fi
    
    # 构建次要架构二进制文件（交叉编译）
    print_info "构建 linux/$SECONDARY_ARCH 二进制文件（次要架构）..."
    
    if [ "$SECONDARY_ARCH" = "arm64" ]; then
        # 构建ARM64版本
        if command -v aarch64-linux-gnu-gcc &> /dev/null; then
            print_info "使用交叉编译工具构建ARM64二进制文件..."
            if GOOS=linux GOARCH=arm64 CGO_ENABLED=1 CC=aarch64-linux-gnu-gcc CXX=aarch64-linux-gnu-g++ go build -trimpath -ldflags="$LDFLAGS" -o komari-linux-arm64; then
                print_success "linux/arm64 二进制文件构建成功（交叉编译）"
            else
                print_warning "交叉编译失败，尝试禁用CGO构建..."
                if GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -ldflags="$LDFLAGS" -o komari-linux-arm64; then
                    print_success "linux/arm64 二进制文件构建成功（禁用CGO）"
                else
                    print_error "linux/arm64 二进制文件构建失败"
                    return 1
                fi
            fi
        else
            print_info "未找到ARM64交叉编译工具，禁用CGO构建ARM64二进制文件..."
            if GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -ldflags="$LDFLAGS" -o komari-linux-arm64; then
                print_success "linux/arm64 二进制文件构建成功（禁用CGO）"
            else
                print_error "linux/arm64 二进制文件构建失败"
                return 1
            fi
        fi
    else
        # 构建AMD64版本
        if command -v x86_64-linux-gnu-gcc &> /dev/null; then
            print_info "使用交叉编译工具构建AMD64二进制文件..."
            if GOOS=linux GOARCH=amd64 CGO_ENABLED=1 CC=x86_64-linux-gnu-gcc CXX=x86_64-linux-gnu-g++ go build -trimpath -ldflags="$LDFLAGS" -o komari-linux-amd64; then
                print_success "linux/amd64 二进制文件构建成功（交叉编译）"
            else
                print_warning "交叉编译失败，尝试禁用CGO构建..."
                if GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags="$LDFLAGS" -o komari-linux-amd64; then
                    print_success "linux/amd64 二进制文件构建成功（禁用CGO）"
                else
                    print_error "linux/amd64 二进制文件构建失败"
                    return 1
                fi
            fi
        else
            print_info "未找到AMD64交叉编译工具，禁用CGO构建AMD64二进制文件..."
            if GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags="$LDFLAGS" -o komari-linux-amd64; then
                print_success "linux/amd64 二进制文件构建成功（禁用CGO）"
            else
                print_error "linux/amd64 二进制文件构建失败"
                return 1
            fi
        fi
    fi
    
    # 验证二进制文件
    if [ -f "komari-linux-amd64" ] && [ -f "komari-linux-arm64" ]; then
        print_success "后端二进制文件构建完成"
        print_info "生成的文件:"
        ls -la komari-linux-*
        return 0
    else
        print_error "二进制文件生成失败"
        return 1
    fi
}

# 构建Docker镜像（本地版本，优先构建当前架构）
build_docker_image_local() {
    print_info "=== 步骤3: 构建Docker镜像 ==="
    
    # 确保在后端项目目录中
    cd "$WORK_DIR/$BACKEND_PROJECT" || {
        print_error "无法进入后端项目目录"
        return 1
    }
    
    # 检查必要文件
    if [ ! -f "Dockerfile" ]; then
        print_error "未找到Dockerfile文件"
        return 1
    fi
    
    if [ ! -f "komari-linux-amd64" ] || [ ! -f "komari-linux-arm64" ]; then
        print_error "未找到后端二进制文件，请先构建后端"
        return 1
    fi
    
    # 确保使用正确的构建器
    if ! docker buildx use "$BUILDX_BUILDER" &> /dev/null; then
        print_warning "无法切换到构建器 $BUILDX_BUILDER，尝试重新配置..."
        check_docker_buildx
    fi
    
    # 构建本地镜像（优先构建当前系统架构）
    print_info "构建本地Docker镜像 ($DEFAULT_PLATFORM): $FULL_IMAGE_NAME"
    if docker buildx build \
        --platform "$DEFAULT_PLATFORM" \
        --tag "$FULL_IMAGE_NAME" \
        --load \
        . ; then
        print_success "本地Docker镜像构建成功: $FULL_IMAGE_NAME ($DEFAULT_PLATFORM)"
        
        # 如果不是latest标签，同时创建latest标签
        if [ "$IMAGE_TAG" != "latest" ]; then
            local latest_image="${DOCKER_USERNAME}/${IMAGE_NAME}:latest"
            print_info "创建latest标签: $latest_image"
            if docker tag "$FULL_IMAGE_NAME" "$latest_image"; then
                print_success "latest标签创建成功"
            fi
        fi
        return 0
    else
        print_error "本地Docker镜像构建失败"
        return 1
    fi
}

# 构建并推送Docker镜像（修复多架构构建问题）
build_docker_image() {
    print_info "=== 步骤3: 构建并推送Docker镜像 ==="
    
    # 确保在后端项目目录中
    cd "$WORK_DIR/$BACKEND_PROJECT" || {
        print_error "无法进入后端项目目录"
        return 1
    }
    
    # 检查必要文件
    if [ ! -f "Dockerfile" ]; then
        print_error "未找到Dockerfile文件"
        return 1
    fi
    
    if [ ! -f "komari-linux-amd64" ] || [ ! -f "komari-linux-arm64" ]; then
        print_error "未找到后端二进制文件，请先构建后端"
        return 1
    fi
    
    # 检查Docker Hub登录状态
    if ! docker info | grep -q "Username:" 2>/dev/null; then
        print_info "请先登录Docker Hub"
        if ! docker login; then
            print_error "Docker Hub登录失败"
            return 1
        fi
    fi
    
    # 确保使用正确的构建器
    if ! docker buildx use "$BUILDX_BUILDER" &> /dev/null; then
        print_warning "无法切换到构建器 $BUILDX_BUILDER，尝试重新配置..."
        if ! check_docker_buildx; then
            print_error "无法配置多架构构建器"
            return 1
        fi
    fi
    
    # 验证构建器状态
    print_info "验证构建器状态..."
    if ! docker buildx inspect "$BUILDX_BUILDER" | grep -q "running"; then
        print_info "启动构建器..."
        docker buildx inspect --bootstrap "$BUILDX_BUILDER" || {
            print_error "无法启动构建器"
            return 1
        }
    fi
    
    # 构建并推送多架构镜像
    print_info "构建多架构Docker镜像并推送: $FULL_IMAGE_NAME"
    print_info "支持的架构: linux/amd64, linux/arm64"
    print_info "主要架构: $DEFAULT_PLATFORM"
    
    if docker buildx build \
        --platform linux/amd64,linux/arm64 \
        --tag "$FULL_IMAGE_NAME" \
        --push \
        . ; then
        
        print_success "多架构Docker镜像构建并推送成功: $FULL_IMAGE_NAME"
        
        # 如果不是latest标签，同时构建latest标签
        if [ "$IMAGE_TAG" != "latest" ]; then
            local latest_image="${DOCKER_USERNAME}/${IMAGE_NAME}:latest"
            print_info "同时构建latest标签: $latest_image"
            if docker buildx build \
                --platform linux/amd64,linux/arm64 \
                --tag "$latest_image" \
                --push \
                . ; then
                print_success "latest标签构建成功"
            else
                print_warning "latest标签构建失败，但主镜像构建成功"
            fi
        fi
        
        echo
        print_success "Docker镜像推送完成!"
        print_info "您可以使用以下命令拉取镜像:"
        echo -e "${GREEN}docker pull $FULL_IMAGE_NAME${NC}"
        if [ "$IMAGE_TAG" != "latest" ]; then
            echo -e "${GREEN}docker pull ${DOCKER_USERNAME}/${IMAGE_NAME}:latest${NC}"
        fi
        echo
        print_info "Docker Hub链接:"
        echo -e "${BLUE}https://hub.docker.com/r/$DOCKER_USERNAME/$IMAGE_NAME${NC}"
        
        return 0
    else
        print_error "Docker镜像构建失败"
        print_info "可能的解决方案:"
        print_info "1. 检查网络连接"
        print_info "2. 确认Docker Hub登录状态"
        print_info "3. 验证仓库权限"
        print_info "4. 尝试重新创建构建器: docker buildx rm $BUILDX_BUILDER"
        return 1
    fi
}

# 生成docker-compose.yml文件（针对当前系统架构优化）
generate_docker_compose() {
    print_info "=== 生成docker-compose.yml文件 ==="
    
    local compose_file="docker-compose.yml"
    
    # 确保在工作目录中
    cd "$WORK_DIR" || {
        print_error "无法切换到工作目录: $WORK_DIR"
        return 1
    }
    
    # 检查是否已存在docker-compose.yml文件
    if [ -f "$compose_file" ]; then
        print_warning "发现已存在的docker-compose.yml文件"
        echo
        print_info "是否要覆盖现有文件? (y/n)"
        read -p "请选择: " overwrite_choice
        
        case $overwrite_choice in
            [Yy]* )
                print_info "覆盖现有文件..."
                ;;
            [Nn]* )
                print_info "跳过生成docker-compose.yml文件"
                return 0
                ;;
            * )
                print_warning "无效选择，跳过生成"
                return 0
                ;;
        esac
    fi
    
    # 生成docker-compose.yml内容（针对当前系统架构优化）
    print_info "生成docker-compose.yml文件（针对 $DEFAULT_PLATFORM 架构优化）..."
    cat > "$compose_file" << EOF
version: '3.8'
services:
  komari:
    image: $FULL_IMAGE_NAME
    platform: $DEFAULT_PLATFORM  # 明确指定架构以确保兼容性
    container_name: komari
    ports:
      - "25774:25774"
    volumes:
      - ./data:/app/data
    environment:
      - GIN_MODE=release
      - KOMARI_DB_TYPE=sqlite
      - KOMARI_DB_FILE=/app/data/komari.db
      # 自定义管理员账号密码
      - ADMIN_USERNAME=komari233
      - ADMIN_PASSWORD=Fcx331fcx331
    restart: unless-stopped
    # 系统信息注释
    # 目标架构: $DEFAULT_PLATFORM
    # 系统架构: $SYSTEM_ARCH
    # 构建时间: $(date '+%Y-%m-%d %H:%M:%S')
EOF
    
    if [ -f "$compose_file" ]; then
        print_success "docker-compose.yml文件生成成功: $WORK_DIR/$compose_file"
        echo
        print_info "文件内容预览:"
        echo -e "${YELLOW}$(cat $compose_file)${NC}"
        echo
        print_info "架构优化说明:"
        echo -e "${GREEN}✓ 已针对当前系统架构 ($SYSTEM_ARCH) 优化${NC}"
        echo -e "${GREEN}✓ 明确指定平台为 $DEFAULT_PLATFORM${NC}"
        echo -e "${GREEN}✓ 避免架构不匹配导致的运行错误${NC}"
        echo
        print_info "使用方法:"
        echo -e "${GREEN}# 创建数据目录${NC}"
        echo -e "${GREEN}mkdir -p data${NC}"
        echo -e "${GREEN}# 启动服务${NC}"
        echo -e "${GREEN}docker-compose up -d${NC}"
        echo
        print_info "管理命令:"
        echo -e "${GREEN}# 查看日志${NC}"
        echo -e "${GREEN}docker-compose logs -f komari${NC}"
        echo -e "${GREEN}# 停止服务${NC}"
        echo -e "${GREEN}docker-compose down${NC}"
        echo -e "${GREEN}# 重启服务${NC}"
        echo -e "${GREEN}docker-compose restart komari${NC}"
        echo
        print_info "访问地址: http://localhost:25774"
        print_info "管理员账号: komari233 / Fcx331fcx331"
        print_warning "请在首次登录后及时修改密码以确保安全！"
        return 0
    else
        print_error "docker-compose.yml文件生成失败"
        return 1
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
    
    # 验证用户名格式
    if [[ ! $DOCKER_USERNAME =~ ^[a-z0-9]+([._-][a-z0-9]+)*$ ]]; then
        print_error "用户名格式不正确，只能包含小写字母、数字、点、下划线和连字符"
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
        # 验证标签格式
        if [[ ! $input_tag =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
            print_error "标签格式不正确，只能包含字母、数字、点、下划线和连字符，且必须以字母或数字开头"
            get_image_tag
            return
        fi
        
        # 检查标签长度
        if [ ${#input_tag} -gt 128 ]; then
            print_error "标签长度不能超过128个字符"
            get_image_tag
            return
        fi
        
        IMAGE_TAG="$input_tag"
        print_success "自定义标签: $IMAGE_TAG"
    fi
}

# 获取镜像信息
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
    echo -e "  目标架构: ${GREEN}$DEFAULT_PLATFORM${NC}"
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

# 保存配置
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
            echo "DEFAULT_PLATFORM=$DEFAULT_PLATFORM" >> "$config_file"
            echo "SYSTEM_ARCH=$SYSTEM_ARCH" >> "$config_file"
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

# 加载配置
load_config() {
    local config_file=".docker-build-config"
    
    if [ -f "$config_file" ]; then
        print_info "发现已保存的配置文件"
        source "$config_file"
        
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
            if [ -n "$DEFAULT_PLATFORM" ]; then
                echo -e "  保存的架构: ${GREEN}$DEFAULT_PLATFORM${NC}"
            fi
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

# 推送到Docker Hub
push_to_dockerhub() {
    echo
    print_info "是否要推送镜像到Docker Hub? (y/n)"
    read -p "请选择: " PUSH_CHOICE
    
    case $PUSH_CHOICE in
        [Yy]* )
            build_docker_image
            ;;
        [Nn]* )
            print_info "跳过推送到Docker Hub"
            print_info "如需稍后推送，请使用以下命令:"
            echo -e "${GREEN}cd $WORK_DIR/$BACKEND_PROJECT${NC}"
            echo -e "${GREEN}docker buildx build --platform linux/amd64,linux/arm64 --tag $FULL_IMAGE_NAME --push .${NC}"
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
            cd "$WORK_DIR" || return
            
            if [ -d "$FRONTEND_PROJECT" ]; then
                rm -rf "$FRONTEND_PROJECT"
                print_success "前端项目目录已清理"
            fi
            
            if [ -d "$BACKEND_PROJECT" ]; then
                rm -rf "$BACKEND_PROJECT"
                print_success "后端项目目录已清理"
            fi
            
            print_success "临时文件清理完成"
            ;;
        [Nn]* )
            print_info "保留临时文件"
            print_info "前端项目目录: $WORK_DIR/$FRONTEND_PROJECT"
            print_info "后端项目目录: $WORK_DIR/$BACKEND_PROJECT"
            ;;
        * )
            print_warning "无效选择，保留临时文件"
            ;;
    esac
}

# 显示菜单
show_menu() {
    echo
    echo -e "${BLUE}=== Komari Docker 镜像构建脚本 (架构优化版) ===${NC}"
    echo -e "${YELLOW}工作目录: $WORK_DIR${NC}"
    echo -e "${YELLOW}系统架构: $SYSTEM_ARCH${NC}"
    echo -e "${YELLOW}默认平台: $DEFAULT_PLATFORM${NC}"
    if [ -n "$DOCKER_USERNAME" ] && [ -n "$IMAGE_NAME" ] && [ -n "$IMAGE_TAG" ]; then
        echo -e "${YELLOW}当前配置: $FULL_IMAGE_NAME${NC}"
    else
        echo -e "${YELLOW}尚未配置镜像信息${NC}"
    fi
    echo
    echo "请选择操作:"
    echo "1) 完整构建流程 (推荐) - 按照官方手工构建步骤"
    echo "2) 配置镜像信息"
    echo "3) 仅构建前端静态文件"
    echo "4) 仅构建后端"
    echo "5) 仅构建Docker镜像 (本地)"
    echo "6) 构建并推送Docker镜像"
    echo "7) 仅推送到Docker Hub"
    echo "8) 清理临时文件"
    echo "9) 重新配置Docker Buildx"
    echo "10) 生成docker-compose.yml文件"
    echo "0) 退出"
    echo
}

# 主函数
main() {
    echo -e "${GREEN}欢迎使用 Komari Docker 镜像自动构建脚本 (架构优化版)!${NC}"
    echo -e "${BLUE}此脚本已针对您的系统架构进行优化，支持多架构构建${NC}"
    echo -e "${BLUE}构建流程: 前端静态文件 → 后端项目 → 复制静态文件 → 构建二进制 → Docker镜像 → Docker Compose${NC}"
    echo
    
    # 显示系统信息
    show_system_info
    
    # 初始化工作目录
    if ! init_work_directory; then
        print_error "工作目录初始化失败，退出脚本"
        exit 1
    fi
    
    # 检查必要工具
    check_requirements
    
    # 尝试加载已保存的配置
    load_config
    
    # 主循环
    while true; do
        show_menu
        read -p "请输入选项 (0-10): " choice
        
        case $choice in
            1)
                # 完整构建流程（按照官方手工构建步骤）
                print_info "开始完整构建流程（针对 $DEFAULT_PLATFORM 架构优化）..."
                
                # 如果没有配置信息，先获取
                if [ -z "$DOCKER_USERNAME" ] || [ -z "$IMAGE_NAME" ] || [ -z "$IMAGE_TAG" ]; then
                    get_image_info
                fi
                
                # 步骤1: 构建前端静态文件
                if ! build_frontend; then
                    print_error "前端构建失败，停止构建流程"
                    continue
                fi
                
                # 步骤2: 构建后端（包含复制前端静态文件）
                if ! build_backend; then
                    print_error "后端构建失败，停止构建流程"
                    continue
                fi
                
                # 步骤3: 构建本地Docker镜像
                if ! build_docker_image_local; then
                    print_error "Docker镜像构建失败，停止构建流程"
                    continue
                fi
                
                # 询问是否推送
                push_to_dockerhub
                save_config
                
                # 生成docker-compose.yml文件
                generate_docker_compose
                
                cleanup
                
                echo
                print_success "完整构建流程完成！"
                print_info "您可以继续使用其他功能或选择0退出"
                ;;
            2)
                get_image_info
                ;;
            3)
                if build_frontend; then
                    print_success "前端静态文件构建完成！"
                    print_info "构建结果位于: $WORK_DIR/$FRONTEND_PROJECT/dist"
                else
                    print_error "前端构建失败！"
                fi
                ;;
            4)
                if build_backend; then
                    print_success "后端构建完成！"
                    print_info "构建结果位于: $WORK_DIR/$BACKEND_PROJECT"
                else
                    print_error "后端构建失败！"
                fi
                ;;
            5)
                if [ -z "$DOCKER_USERNAME" ] || [ -z "$IMAGE_NAME" ] || [ -z "$IMAGE_TAG" ]; then
                    get_image_info
                fi
                if build_docker_image_local; then
                    print_success "Docker镜像构建完成！"
                else
                    print_error "Docker镜像构建失败！"
                fi
                ;;
            6)
                if [ -z "$DOCKER_USERNAME" ] || [ -z "$IMAGE_NAME" ] || [ -z "$IMAGE_TAG" ]; then
                    get_image_info
                fi
                if build_docker_image; then
                    print_success "Docker镜像构建并推送完成！"
                else
                    print_error "Docker镜像构建失败！"
                fi
                ;;
            7)
                if [ -z "$DOCKER_USERNAME" ] || [ -z "$IMAGE_NAME" ] || [ -z "$IMAGE_TAG" ]; then
                    get_image_info
                fi
                push_to_dockerhub
                ;;
            8)
                cleanup
                ;;
            9)
                print_info "重新配置Docker Buildx..."
                # 删除现有构建器
                docker buildx rm "$BUILDX_BUILDER" &> /dev/null || true
                # 重新配置
                if check_docker_buildx; then
                    print_success "Docker Buildx重新配置完成！"
                else
                    print_error "Docker Buildx配置失败！"
                fi
                ;;
            10)
                if [ -z "$DOCKER_USERNAME" ] || [ -z "$IMAGE_NAME" ] || [ -z "$IMAGE_TAG" ]; then
                    get_image_info
                fi
                if generate_docker_compose; then
                    print_success "docker-compose.yml文件生成完成！"
                else
                    print_error "docker-compose.yml文件生成失败！"
                fi
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