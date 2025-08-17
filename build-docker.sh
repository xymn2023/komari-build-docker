#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

DOCKER_USERNAME=""
IMAGE_NAME=""
IMAGE_TAG="latest"
FULL_IMAGE_NAME=""
WORK_DIR=""
FRONTEND_PROJECT="komari-web"
BACKEND_PROJECT="komari"
FRONTEND_REPO="https://github.com/komari-monitor/komari-web.git"
BACKEND_REPO="https://github.com/komari-monitor/komari.git"
BUILDX_BUILDER="amd64-builder"
TARGET_ARCH="linux/amd64"

# 全局标志，标记是否需要清理构建器
BUILDER_CREATED=false

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

print_debug() {
    echo -e "${YELLOW}[DEBUG]${NC} $1"
}

# 清理构建器函数
cleanup_builder() {
    if [ "$BUILDER_CREATED" = true ]; then
        print_info "清理Docker Buildx构建器: $BUILDX_BUILDER"
        
        # 检查构建器是否存在
        if docker buildx ls | grep -q "$BUILDX_BUILDER"; then
            # 停止并删除构建器
            docker buildx rm "$BUILDX_BUILDER" &> /dev/null || true
            print_success "构建器 $BUILDX_BUILDER 已清理"
        else
            print_info "构建器 $BUILDX_BUILDER 不存在，无需清理"
        fi
        
        BUILDER_CREATED=false
    fi
}

# 脚本退出时的清理函数
cleanup_on_exit() {
    echo
    print_info "脚本即将退出，执行清理操作..."
    
    # 清理构建器
    cleanup_builder
    
    print_success "清理完成，感谢使用 Komari Docker 构建脚本！"
    echo
}

# 设置退出时的清理陷阱
trap cleanup_on_exit EXIT

# 设置中断信号的清理陷阱
trap 'echo; print_warning "检测到中断信号，正在清理..."; cleanup_on_exit; exit 130' INT TERM

# 从GitHub API获取官方最新版本信息
get_official_version_info() {
    print_info "从GitHub API获取官方最新版本信息..."
    
    # 先获取最新release的tag名称
    local latest_api="https://api.github.com/repos/komari-monitor/komari/releases/latest"
    local tag_name=$(curl -s "$latest_api" | grep '"tag_name":' | sed -E 's/.*"tag_name":\s*"([^"]+)".*/\1/' | head -1)
    
    if [ -z "$tag_name" ] || [ "$tag_name" = "null" ]; then
        print_error "无法从GitHub API获取版本信息，请检查网络连接"
        return 1
    fi
    
    print_debug "获取到官方tag: $tag_name"
    
    # 使用Tags API获取该tag对应的提交哈希
    local tags_api="https://api.github.com/repos/komari-monitor/komari/git/refs/tags/${tag_name}"
    local commit_sha=$(curl -s "$tags_api" | grep '"sha":' | head -1 | sed -E 's/.*"sha":\s*"([^"]+)".*/\1/')
    
    if [ -z "$commit_sha" ] || [ "$commit_sha" = "null" ]; then
        print_error "无法从GitHub API获取提交哈希，请检查网络连接"
        return 1
    fi
    
    # 清理版本号和截取哈希
    local clean_version=$(echo "$tag_name" | sed 's/^v//')
    local short_hash=$(echo "$commit_sha" | cut -c1-7)
    
    print_success "获取官方版本信息成功:"
    print_debug "  官方版本: $clean_version"
    print_debug "  官方哈希: $short_hash"
    
    # 返回版本号和哈希（空格分隔）
    echo "$clean_version $short_hash"
    return 0
}

init_work_directory() {
    print_info "初始化工作目录..."
    WORK_DIR="$(pwd)"
    print_debug "工作目录: $WORK_DIR"
    
    if [ ! -w "$WORK_DIR" ]; then
        print_error "当前目录没有写权限: $WORK_DIR"
        return 1
    fi
    
    print_success "工作目录初始化完成"
    return 0
}

check_requirements() {
    print_info "检查必要的工具..."
    local missing_tools=()
    local need_install=false
    
    if ! command -v docker &> /dev/null; then
        print_warning "Docker未安装，正在自动安装..."
        missing_tools+=("docker")
        need_install=true
    else
        print_success "Docker已安装: $(docker --version)"
    fi
    
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
    
    if ! command -v npm &> /dev/null; then
        print_warning "npm未安装，正在自动安装..."
        missing_tools+=("npm")
        need_install=true
    else
        print_success "npm已安装: $(npm --version)"
    fi
    
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
    
    if ! command -v git &> /dev/null; then
        print_warning "Git未安装，正在自动安装..."
        missing_tools+=("git")
        need_install=true
    else
        print_success "Git已安装: $(git --version)"
    fi
    
    if [ "$need_install" = true ]; then
        echo
        print_info "开始自动安装缺失的工具: ${missing_tools[*]}"
        install_missing_tools "${missing_tools[@]}"
    else
        print_success "所有必要工具检查通过"
    fi
    
    check_docker_buildx
}

install_missing_tools() {
    local tools=("$@")
    print_info "开始自动安装缺失的工具..."
    install_tools_linux "${tools[@]}"
}

install_tools_linux() {
    local tools=("$@")
    
    if command -v apt-get &> /dev/null; then
        print_info "使用apt-get安装工具..."
        sudo apt-get update -qq
        
        for tool in "${tools[@]}"; do
            case $tool in
                "docker")
                    print_info "安装Docker..."
                    sudo apt-get install -y ca-certificates curl gnupg
                    sudo install -m 0755 -d /etc/apt/keyrings
                    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
                    sudo chmod a+r /etc/apt/keyrings/docker.gpg
                    
                    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
                    
                    sudo apt-get update -qq
                    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
                    
                    sudo usermod -aG docker $USER
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
                    wget -q https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz
                    sudo rm -rf /usr/local/go
                    sudo tar -C /usr/local -xzf go${GO_VERSION}.linux-amd64.tar.gz
                    
                    if ! grep -q '/usr/local/go/bin' ~/.bashrc; then
                        echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
                    fi
                    
                    if ! grep -q '/usr/local/go/bin' ~/.profile; then
                        echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.profile
                    fi
                    
                    export PATH=$PATH:/usr/local/go/bin
                    rm go${GO_VERSION}.linux-amd64.tar.gz
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

check_docker_buildx() {
    print_info "检查并配置Docker Buildx (AMD64架构)..."
    
    if ! docker buildx version &> /dev/null; then
        print_error "Docker Buildx未安装，请升级Docker到最新版本"
        return 1
    fi
    
    print_success "Docker Buildx已安装: $(docker buildx version)"
    
    # 先清理可能存在的旧构建器
    if docker buildx ls | grep -q "$BUILDX_BUILDER"; then
        print_warning "发现已存在的构建器 $BUILDX_BUILDER，正在清理..."
        docker buildx rm "$BUILDX_BUILDER" &> /dev/null || true
        print_success "旧构建器已清理"
    fi
    
    # 创建新的构建器
    print_info "创建新的AMD64构建器..."
    create_buildx_builder
}

create_buildx_builder() {
    print_info "创建Docker Buildx构建器: $BUILDX_BUILDER (AMD64)"
    
    if docker buildx create \
        --name "$BUILDX_BUILDER" \
        --driver docker-container \
        --platform linux/amd64 \
        --use; then
        print_success "构建器创建成功: $BUILDX_BUILDER"
        BUILDER_CREATED=true  # 标记构建器已创建
    else
        print_error "构建器创建失败"
        return 1
    fi
    
    print_info "启动构建器..."
    if docker buildx inspect --bootstrap "$BUILDX_BUILDER"; then
        print_success "构建器启动成功"
    else
        print_error "构建器启动失败"
        return 1
    fi
}

build_frontend() {
    print_info "=== 步骤1: 构建前端静态文件 ==="
    
    cd "$WORK_DIR" || {
        print_error "无法切换到工作目录: $WORK_DIR"
        return 1
    }
    
    if [ -d "$FRONTEND_PROJECT" ]; then
        print_warning "发现已存在的前端项目目录，正在删除..."
        rm -rf "$FRONTEND_PROJECT"
    fi
    
    print_info "克隆前端项目: $FRONTEND_REPO"
    if git clone "$FRONTEND_REPO" "$FRONTEND_PROJECT"; then
        print_success "前端项目克隆成功"
    else
        print_error "前端项目克隆失败"
        return 1
    fi
    
    cd "$FRONTEND_PROJECT" || {
        print_error "无法进入前端项目目录"
        return 1
    }
    
    print_info "安装前端依赖..."
    if npm install; then
        print_success "前端依赖安装成功"
    else
        print_error "前端依赖安装失败"
        return 1
    fi
    
    print_info "构建前端项目..."
    if npm run build; then
        print_success "前端项目构建成功"
    else
        print_error "前端项目构建失败"
        return 1
    fi
    
    if [ ! -d "dist" ]; then
        print_error "前端构建失败，未找到dist目录"
        return 1
    fi
    
    print_success "前端静态文件构建完成"
    return 0
}

build_backend() {
    print_info "=== 步骤2: 构建后端 (AMD64架构，CGO启用，动态获取官方版本标识) ==="
    
    cd "$WORK_DIR" || {
        print_error "无法切换到工作目录: $WORK_DIR"
        return 1
    }
    
    if [ -d "$BACKEND_PROJECT" ]; then
        print_warning "发现已存在的后端项目目录，正在删除..."
        rm -rf "$BACKEND_PROJECT"
    fi
    
    print_info "克隆后端项目: $BACKEND_REPO"
    if git clone "$BACKEND_REPO" "$BACKEND_PROJECT"; then
        print_success "后端项目克隆成功"
    else
        print_error "后端项目克隆失败"
        return 1
    fi
    
    cd "$BACKEND_PROJECT" || {
        print_error "无法进入后端项目目录"
        return 1
    }
    
    if [ ! -f "go.mod" ] || [ ! -f "Dockerfile" ]; then
        print_error "后端项目结构不完整，缺少必要文件"
        return 1
    fi
    
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
    
    # 动态获取官方版本信息
    print_info "动态获取官方版本信息..."
    local version_info=$(get_official_version_info)
    local get_version_result=$?
    
    if [ $get_version_result -ne 0 ] || [ -z "$version_info" ]; then
        print_error "无法获取官方版本信息，构建终止"
        print_error "请检查网络连接或GitHub API访问权限"
        return 1
    fi
    
    local official_version=$(echo "$version_info" | awk '{print $1}')
    local official_hash=$(echo "$version_info" | awk '{print $2}')
    
    print_debug "解析版本信息: '$version_info' -> 版本='$official_version', 哈希='$official_hash'"
    
    # 验证获取到的数据
    if [ -z "$official_version" ] || [ -z "$official_hash" ]; then
        print_error "获取到的版本信息不完整，构建终止"
        print_error "版本号: '$official_version', 哈希: '$official_hash'"
        return 1
    fi
    
    # 获取当前代码信息（仅用于构建日志）
    local current_hash=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    local current_full_hash=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
    
    print_debug "当前代码信息: 短哈希='$current_hash', 完整哈希='$current_full_hash'"
    
    # 使用动态获取的官方版本号和官方哈希值进行版本注入
    local display_version="$official_version"  # 网页显示的版本号
    local display_hash="$official_hash"        # 网页显示的哈希值
    
    print_info "版本信息汇总:"
    print_info "  动态获取的官方版本: $official_version ($official_hash)"
    print_info "  当前构建代码: $current_hash"
    print_info "  网页将显示版本: $display_version ($display_hash)"
    print_info "  构建基于: 当前代码 $current_full_hash"
    
    local module_name=$(grep '^module' go.mod | awk '{print $2}')
    print_debug "Go模块名: $module_name"
    
    # 检查Go环境
    print_debug "Go环境检查:"
    print_debug "  Go版本: $(go version)"
    print_debug "  GOPATH: $(go env GOPATH)"
    print_debug "  GOROOT: $(go env GOROOT)"
    print_debug "  CGO_ENABLED: $(go env CGO_ENABLED)"
    
    # 版本注入：使用动态获取的官方版本号和官方哈希值
    local version_flag="${module_name}/utils.CurrentVersion=${display_version}"
    local hash_flag="${module_name}/utils.VersionHash=${display_hash}"
    
    print_debug "LDFLAGS组件:"
    print_debug "  版本标志: $version_flag"
    print_debug "  哈希标志: $hash_flag"
    
    print_info "开始编译过程..."
    
    # 设置编译环境变量
    export CGO_ENABLED=1
    export GOOS=linux
    export GOARCH=amd64
    
    print_debug "编译环境变量:"
    print_debug "  CGO_ENABLED=$CGO_ENABLED"
    print_debug "  GOOS=$GOOS"
    print_debug "  GOARCH=$GOARCH"
    
    # 先进行基础编译测试
    print_info "执行基础编译测试..."
    if go build -o komari-test-basic 2>/dev/null; then
        print_success "基础编译测试通过"
        rm -f komari-test-basic
        
        # 测试带简单LDFLAGS的编译
        print_info "测试简单LDFLAGS编译..."
        if go build -ldflags="-s -w" -o komari-test-simple 2>/dev/null; then
            print_success "简单LDFLAGS编译测试通过"
            rm -f komari-test-simple
            
            # 执行完整编译
            print_info "执行完整编译（包含动态获取的官方版本信息）..."
            print_debug "执行命令: go build -trimpath -ldflags=\"-s -w -X '$version_flag' -X '$hash_flag'\" -o komari-linux-amd64"
            
            if go build -trimpath -ldflags="-s -w -X '$version_flag' -X '$hash_flag'" -o komari-linux-amd64; then
                print_success "完整编译成功（包含动态获取的官方版本信息）"
            else
                print_warning "完整编译失败，尝试不带trimpath..."
                if go build -ldflags="-s -w -X '$version_flag' -X '$hash_flag'" -o komari-linux-amd64; then
                    print_success "编译成功（不带trimpath）"
                else
                    print_warning "带版本信息编译失败，使用简化编译..."
                    if go build -ldflags="-s -w" -o komari-linux-amd64; then
                        print_warning "简化编译成功（版本信息可能不完整）"
                    else
                        print_error "所有编译尝试都失败了"
                        return 1
                    fi
                fi
            fi
        else
            print_warning "简单LDFLAGS编译失败，尝试最基础编译..."
            if go build -o komari-linux-amd64; then
                print_warning "基础编译成功（无优化，无版本信息）"
            else
                print_error "基础编译失败"
                return 1
            fi
        fi
    else
        print_error "基础编译测试失败，请检查Go环境和项目代码"
        print_debug "尝试显示编译错误:"
        go build -o komari-test-debug 2>&1 | head -20
        return 1
    fi
    
    # 验证编译结果
    if [ -f "komari-linux-amd64" ]; then
        print_success "后端二进制文件构建完成"
        print_info "生成的文件信息:"
        ls -la komari-linux-amd64
        
        # 检查文件类型
        if command -v file &> /dev/null; then
            print_debug "文件类型: $(file komari-linux-amd64)"
        fi
        
        # 尝试获取版本信息
        print_info "尝试验证版本信息..."
        if ./komari-linux-amd64 --version 2>/dev/null; then
            print_success "版本信息验证成功"
        else
            print_warning "无法验证版本信息（可能是正常的）"
        fi
        
        print_info "编译总结:"
        print_info "  网页显示版本: $display_version ($display_hash)"
        print_info "  基于官方版本: $official_version"
        print_info "  版本信息来源: 动态从GitHub API获取"
        print_info "  CGO已启用，支持SQLite数据库"
        print_info "  目标架构: linux/amd64"
        
        return 0
    else
        print_error "二进制文件生成失败"
        return 1
    fi
}

create_dockerfile() {
    print_info "创建兼容glibc的Dockerfile..."
    
    cd "$WORK_DIR/$BACKEND_PROJECT" || {
        print_error "无法进入后端项目目录"
        return 1
    }
    
    cat > Dockerfile << 'EOF'
FROM debian:bookworm-slim

WORKDIR /app

RUN apt-get update && apt-get install -y \
    ca-certificates \
    tzdata \
    && rm -rf /var/lib/apt/lists/*

COPY komari-linux-amd64 /app/komari
RUN chmod +x /app/komari

ENV GIN_MODE=release
ENV KOMARI_DB_TYPE=sqlite
ENV KOMARI_DB_FILE=/app/data/komari.db
ENV KOMARI_DB_HOST=localhost
ENV KOMARI_DB_PORT=3306
ENV KOMARI_DB_USER=root
ENV KOMARI_DB_PASS=
ENV KOMARI_DB_NAME=komari
ENV KOMARI_LISTEN=0.0.0.0:25774

EXPOSE 25774

CMD ["/app/komari", "server"]
EOF
    
    print_success "Dockerfile创建完成（使用Debian基础镜像）"
}

build_docker_image_local() {
    print_info "=== 步骤3: 构建Docker镜像 (AMD64) ==="
    
    cd "$WORK_DIR/$BACKEND_PROJECT" || {
        print_error "无法进入后端项目目录"
        return 1
    }
    
    create_dockerfile
    
    if [ ! -f "komari-linux-amd64" ]; then
        print_error "未找到后端二进制文件，请先构建后端"
        return 1
    fi
    
    if ! docker buildx use "$BUILDX_BUILDER" &> /dev/null; then
        print_warning "无法切换到构建器 $BUILDX_BUILDER，尝试重新配置..."
        check_docker_buildx
    fi
    
    print_info "构建本地Docker镜像 (linux/amd64): $FULL_IMAGE_NAME"
    if docker buildx build \
        --platform linux/amd64 \
        --tag "$FULL_IMAGE_NAME" \
        --load \
        . ; then
        print_success "本地Docker镜像构建成功: $FULL_IMAGE_NAME"
        
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

build_docker_image() {
    print_info "=== 步骤3: 构建并推送Docker镜像 (AMD64) ==="
    
    cd "$WORK_DIR/$BACKEND_PROJECT" || {
        print_error "无法进入后端项目目录"
        return 1
    }
    
    create_dockerfile
    
    if [ ! -f "komari-linux-amd64" ]; then
        print_error "未找到后端二进制文件，请先构建后端"
        return 1
    fi
    
    if ! docker info | grep -q "Username:" 2>/dev/null; then
        print_info "请先登录Docker Hub"
        if ! docker login; then
            print_error "Docker Hub登录失败"
            return 1
        fi
    fi
    
    if ! docker buildx use "$BUILDX_BUILDER" &> /dev/null; then
        print_warning "无法切换到构建器 $BUILDX_BUILDER，尝试重新配置..."
        if ! check_docker_buildx; then
            print_error "无法配置构建器"
            return 1
        fi
    fi
    
    print_info "验证构建器状态..."
    if ! docker buildx inspect "$BUILDX_BUILDER" | grep -q "running"; then
        print_info "启动构建器..."
        docker buildx inspect --bootstrap "$BUILDX_BUILDER" || {
            print_error "无法启动构建器"
            return 1
        }
    fi
    
    print_info "构建AMD64 Docker镜像并推送: $FULL_IMAGE_NAME"
    print_info "支持的架构: linux/amd64"
    
    if docker buildx build \
        --platform linux/amd64 \
        --tag "$FULL_IMAGE_NAME" \
        --push \
        . ; then
        
        print_success "AMD64 Docker镜像构建并推送成功: $FULL_IMAGE_NAME"
        
        if [ "$IMAGE_TAG" != "latest" ]; then
            local latest_image="${DOCKER_USERNAME}/${IMAGE_NAME}:latest"
            print_info "同时构建latest标签: $latest_image"
            if docker buildx build \
                --platform linux/amd64 \
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

generate_docker_compose() {
    print_info "=== 生成docker-compose.yml文件 (AMD64架构) ==="
    
    local compose_file="docker-compose.yml"
    
    cd "$WORK_DIR" || {
        print_error "无法切换到工作目录: $WORK_DIR"
        return 1
    }
    
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
    
    print_info "生成docker-compose.yml文件..."
    cat > "$compose_file" << EOF
version: '3.8'
services:
  komari:
    image: $FULL_IMAGE_NAME
    platform: linux/amd64
    container_name: komari
    ports:
      - "25774:25774"
    volumes:
      - ./data:/app/data
    environment:
      - GIN_MODE=release
      - KOMARI_DB_TYPE=sqlite
      - KOMARI_DB_FILE=/app/data/komari.db
      - ADMIN_USERNAME=admin
      - ADMIN_PASSWORD=admin123
    restart: unless-stopped
EOF
    
    if [ -f "$compose_file" ]; then
        print_success "docker-compose.yml文件生成成功: $WORK_DIR/$compose_file"
        echo
        print_info "文件内容预览:"
        echo -e "${YELLOW}$(cat $compose_file)${NC}"
        echo
        print_info "使用方法:"
        echo -e "${GREEN}mkdir -p data${NC}"
        echo -e "${GREEN}docker-compose up -d${NC}"
        echo
        print_info "管理命令:"
        echo -e "${GREEN}docker-compose logs -f komari${NC}"
        echo -e "${GREEN}docker-compose down${NC}"
        echo -e "${GREEN}docker-compose restart komari${NC}"
        echo
        print_info "访问地址: http://localhost:25774"
        print_info "管理员账号: admin / admin123"
        print_warning "请在首次登录后及时修改密码以确保安全！"
        print_info "架构信息: AMD64架构，CGO启用，动态获取官方版本标识"
        return 0
    else
        print_error "docker-compose.yml文件生成失败"
        return 1
    fi
}

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
    
    if [[ ! $DOCKER_USERNAME =~ ^[a-z0-9]+([._-][a-z0-9]+)*$ ]]; then
        print_error "用户名格式不正确，只能包含小写字母、数字、点、下划线和连字符"
        get_docker_username
        return
    fi
    
    print_success "Docker Hub用户名: $DOCKER_USERNAME"
}

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
    
    if [[ ! $IMAGE_NAME =~ ^[a-z0-9]+([._-][a-z0-9]+)*$ ]]; then
        print_error "镜像名称格式不正确，只能包含小写字母、数字、点、下划线和连字符"
        get_image_name
        return
    fi
    
    print_success "镜像名称: $IMAGE_NAME"
}

get_image_tag() {
    echo
    print_info "请输入镜像标签 (直接回车使用默认值 'latest'):"
    echo -e "${YELLOW}示例: latest, v1.0.0, dev, stable, $(date +%Y%m%d)${NC}"
    echo -e "${YELLOW}当前默认: latest${NC}"
    read -p "镜像标签 [latest]: " input_tag
    
    if [ -z "$input_tag" ]; then
        IMAGE_TAG="latest"
        print_success "使用默认标签: $IMAGE_TAG"
    else
        if [[ ! $input_tag =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
            print_error "标签格式不正确，只能包含字母、数字、点、下划线和连字符，且必须以字母或数字开头"
            get_image_tag
            return
        fi
        
        if [ ${#input_tag} -gt 128 ]; then
            print_error "标签长度不能超过128个字符"
            get_image_tag
            return
        fi
        
        IMAGE_TAG="$input_tag"
        print_success "自定义标签: $IMAGE_TAG"
    fi
}

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
    echo -e "  目标架构: ${GREEN}linux/amd64${NC}"
    echo -e "  编译方式: ${GREEN}CGO启用（支持SQLite）+ 动态获取官方版本标识${NC}"
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
            echo "TARGET_ARCH=$TARGET_ARCH" >> "$config_file"
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
            echo -e "  目标架构: ${GREEN}$TARGET_ARCH${NC}"
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
            echo -e "${GREEN}docker buildx build --platform linux/amd64 --tag $FULL_IMAGE_NAME --push .${NC}"
            ;;
        * )
            print_warning "无效选择，跳过推送"
            ;;
    esac
}

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
            
            if [ -f ".docker-build-config" ]; then
                rm -f ".docker-build-config"
                print_success "配置文件已清理"
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

show_menu() {
    echo
    echo -e "${BLUE}=== Komari Docker 镜像构建脚本 (AMD64架构专用 + 动态获取官方版本标识 + 自动清理 + 调试增强) ===${NC}"
    echo -e "${YELLOW}工作目录: $WORK_DIR${NC}"
    echo -e "${YELLOW}目标架构: linux/amd64 (CGO启用 + 动态获取官方版本标识)${NC}"
    echo -e "${YELLOW}构建器管理: 自动创建和清理 $BUILDX_BUILDER${NC}"
    if [ -n "$DOCKER_USERNAME" ] && [ -n "$IMAGE_NAME" ] && [ -n "$IMAGE_TAG" ]; then
        echo -e "${YELLOW}当前配置: $FULL_IMAGE_NAME${NC}"
    else
        echo -e "${YELLOW}尚未配置镜像信息${NC}"
    fi
    echo
    echo "请选择操作:"
    echo "1) 完整构建流程 (推荐) - 按照官方手工构建步骤 + 动态获取官方版本标识"
    echo "2) 配置镜像信息"
    echo "3) 仅构建前端静态文件"
    echo "4) 仅构建后端 (包含动态获取官方版本标识 + 调试信息)"
    echo "5) 仅构建Docker镜像 (本地)"
    echo "6) 构建并推送Docker镜像"
    echo "7) 仅推送到Docker Hub"
    echo "8) 清理临时文件"
    echo "9) 重新配置Docker Buildx"
    echo "10) 生成docker-compose.yml文件"
    echo "11) 手动清理构建器"
    echo "0) 退出 (自动清理构建器)"
    echo
}

main() {
    echo -e "${GREEN}欢迎使用 Komari Docker 镜像自动构建脚本 (AMD64架构专用 + 动态获取官方版本标识 + 自动清理 + 调试增强)!${NC}"
    echo -e "${BLUE}此脚本专门为AMD64/x86_64架构优化，启用CGO支持SQLite数据库${NC}"
    echo -e "${BLUE}新增功能: 动态从GitHub API获取最新官方版本号，网页显示实时官方版本标识${NC}"
    echo -e "${BLUE}构建器管理: 脚本启动时创建，退出时自动清理 $BUILDX_BUILDER${NC}"
    echo -e "${BLUE}调试增强: 详细的编译过程调试信息，多重编译回退机制${NC}"
    echo -e "${BLUE}构建流程: 前端静态文件 → 后端项目 → 复制静态文件 → CGO编译二进制 → Docker镜像 → Docker Compose${NC}"
    echo
    
    if ! init_work_directory; then
        print_error "工作目录初始化失败，退出脚本"
        exit 1
    fi
    
    check_requirements
    load_config
    
    while true; do
        show_menu
        read -p "请输入选项 (0-11): " choice
        
        case $choice in
            1)
                print_info "开始完整构建流程（按照官方手工构建步骤 + 动态获取官方版本标识 + 调试增强）..."
                
                if [ -z "$DOCKER_USERNAME" ] || [ -z "$IMAGE_NAME" ] || [ -z "$IMAGE_TAG" ]; then
                    get_image_info
                fi
                
                if ! build_frontend; then
                    print_error "前端构建失败，停止构建流程"
                    continue
                fi
                
                if ! build_backend; then
                    print_error "后端构建失败，停止构建流程"
                    continue
                fi
                
                if ! build_docker_image_local; then
                    print_error "Docker镜像构建失败，停止构建流程"
                    continue
                fi
                
                push_to_dockerhub
                save_config
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
                cleanup_builder  # 先清理旧的
                check_docker_buildx  # 重新创建
                if [ "$BUILDER_CREATED" = true ]; then
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
            11)
                print_info "手动清理构建器..."
                cleanup_builder
                print_success "构建器清理完成！"
                ;;
            0)
                print_info "正在退出脚本..."
                # EXIT trap 会自动调用 cleanup_on_exit
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

main "$@"