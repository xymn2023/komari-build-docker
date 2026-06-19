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
    # 先获取最新release的tag名称
    local latest_api="https://api.github.com/repos/komari-monitor/komari/releases/latest"
    local tag_name=$(curl -s "$latest_api" | grep '"tag_name":' | sed -E 's/.*"tag_name":\s*"([^"]+)".*/\1/' | head -1)
    
    if [ -z "$tag_name" ] || [ "$tag_name" = "null" ]; then
        print_error "无法从GitHub API获取版本信息，请检查网络连接"
        return 1
    fi
    
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
    
    # 直接返回版本号和哈希（空格分隔）
    echo "$clean_version $short_hash"
    return 0
}

init_work_directory() {
    print_info "初始化工作目录..."
    WORK_DIR="$(pwd)"
    
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
        # 修改点：Node.js 环境依赖要求 20+
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
        # 修改点：Go 环境依赖要求 1.18+
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
    
    # 根据操作系统选择安装方式
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        install_tools_linux "${tools[@]}"
    else
        print_error "目前仅支持Linux系统自动安装依赖"
        return 1
    fi
}

install_tools_linux() {
    local tools=("$@")
    
    # 检查包管理器
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
                    
                    # 启动Docker并设置开机启动
                    sudo usermod -aG docker "$USER"
                    sudo systemctl start docker
                    sudo systemctl enable docker
                    
                    print_success "Docker安装完成"
                    ;;
                "nodejs")
                    print_info "安装Node.js..."
                    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
                    sudo apt-get install -y nodejs
                    print_success "Node.js安装完成"
                    ;;
                "golang")
                    print_info "安装Go..."
                    GO_VERSION="1.21.5"
                    wget -q https://go.dev/dl/go"${GO_VERSION}".linux-amd64.tar.gz
                    sudo rm -rf /usr/local/go
                    sudo tar -C /usr/local -xzf go"${GO_VERSION}".linux-amd64.tar.gz
                    
                    # 添加到PATH
                    if ! grep -q '/usr/local/go/bin' ~/.bashrc; then
                        echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
                    fi
                    
                    if ! grep -q '/usr/local/go/bin' ~/.profile; then
                        echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.profile
                    fi
                    
                    export PATH=$PATH:/usr/local/go/bin
                    rm go"${GO_VERSION}".linux-amd64.tar.gz
                    print_success "Go安装完成"
                    ;;
                "git")
                    print_info "安装Git..."
                    sudo apt-get install -y git
                    print_success "Git安装完成"
                    ;;
            esac
        done # <-- 闭合 for 循环
    else # <-- else 块紧随 if 命令之后
        print_error "不支持的包管理器，请手动安装: ${tools[*]}"
        return 1
    fi # <-- 闭合 if 命令
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
    
    # 创建新的构建器，指定 platform 为 linux/amd64
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
    
    # 引导构建器
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
    
    # 按照 Go 嵌入指令的要求，将前端静态文件复制到后端项目的 web/public/defaultTheme/dist 目录
    print_info "复制前端静态文件到后端项目的/web/public/defaultTheme/dist目录..."
    mkdir -p web/public/defaultTheme/dist
    
    # 清空目标目录，防止旧文件干扰
    if [ "$(ls -A web/public/defaultTheme/dist)" ]; then
        print_warning "web/public/defaultTheme/dist 目录非空，正在清理..."
        rm -rf web/public/defaultTheme/dist/*
    fi

    if [ -d "$WORK_DIR/$FRONTEND_PROJECT/dist" ]; then
        # 将前端项目 dist 目录下的所有内容复制到 .../defaultTheme/dist/
        if cp -r "$WORK_DIR/$FRONTEND_PROJECT/dist"/* web/public/defaultTheme/dist/; then
            print_success "前端静态文件复制成功到 web/public/defaultTheme/dist"
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
    
    if [ "$get_version_result" -ne 0 ] || [ -z "$version_info" ]; then
        print_error "无法获取官方版本信息，构建终止"
        print_error "请检查网络连接或GitHub API访问权限"
        return 1
    fi
    
    # 解析版本信息
    local official_version=$(echo "$version_info" | awk '{print $1}')
    local official_hash=$(echo "$version_info" | awk '{print $2}')
    
    # 验证获取到的数据
    if [ -z "$official_version" ] || [ -z "$official_hash" ]; then
        print_error "获取到的版本信息不完整，构建终止"
        print_error "版本号: '$official_version', 哈希: '$official_hash'"
        return 1
    fi
    
    # 验证哈希长度
    if [ "${#official_hash}" -ne 7 ]; then
        print_error "哈希值长度不正确: '$official_hash' (期望7位，实际${#official_hash}位)"
        return 1
    fi
    
    # 获取当前代码信息
    local current_hash=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    
    local display_version="$official_version"  # 网页显示的版本号
    local display_hash="$official_hash"        # 网页显示的哈希值
    
    print_info "版本信息汇总:"
    print_info "  动态获取的官方版本: $official_version ($official_hash)"
    print_info "  当前构建代码: $current_hash"
    print_info "  网页将显示版本: $display_version ($display_hash)"
    
    local module_name=$(grep '^module' go.mod | awk '{print $2}')
    
    # 版本注入
    local version_flag="${module_name}/utils.CurrentVersion=${display_version}"
    local hash_flag="${module_name}/utils.VersionHash=${display_hash}"
    
    print_info "开始编译过程..."
    
    # 设置编译环境变量
    export CGO_ENABLED=1
    export GOOS=linux
    export GOARCH=amd64
    
    # 执行编译
    if go build -trimpath -ldflags="-s -w -X '$version_flag' -X '$hash_flag'" -o komari-linux-amd64; then
        print_success "完整编译成功"
    else
        print_error "所有编译尝试都失败了"
        return 1
    fi
    
    # 验证编译结果
    if [ -f "komari-linux-amd64" ]; then
        print_success "后端二进制文件构建完成"
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

# 注意: 后端 `public/public.go` 中的 `DataDir` 是 `./data`
# 为了确保 Dockerfile 和 Go 代码中的路径一致，将卷挂载到 /app/data
VOLUME ["/app/data"]

ENV GIN_MODE=release
ENV KOMARI_DB_TYPE=sqlite
ENV KOMARI_DB_FILE=/app/data/komari.db
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
    
    # Ensures the buildx builder is available and used
    if ! docker buildx use "$BUILDX_BUILDER" &> /dev/null; then
        check_docker_buildx
    fi
    
    print_info "构建本地Docker镜像 (linux/amd64): $FULL_IMAGE_NAME"
    if docker buildx build \
        --platform linux/amd64 \
        --tag "$FULL_IMAGE_NAME" \
        --load \
        . ; then
        print_success "本地Docker镜像构建成功: $FULL_IMAGE_NAME"
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
    
    if ! docker info | grep -q "Username:" 2>/dev/null; then
        print_info "请先登录Docker Hub"
        if ! docker login; then
            print_error "Docker Hub登录失败"
            return 1
        fi
    fi
    
    if ! docker buildx use "$BUILDX_BUILDER" &> /dev/null; then
        check_docker_buildx
    fi
    
    print_info "构建AMD64 Docker镜像并推送: $FULL_IMAGE_NAME"
    if docker buildx build \
        --platform linux/amd64 \
        --tag "$FULL_IMAGE_NAME" \
        --push \
        . ; then
        print_success "AMD64 Docker镜像构建并推送成功: $FULL_IMAGE_NAME"
        return 0
    else
        print_error "Docker镜像构建失败"
        return 1
    fi
}

generate_docker_compose() {
    print_info "=== 生成docker-compose.yml文件 ==="
    local compose_file="docker-compose.yml"
    cd "$WORK_DIR" || return 1
    
    cat > "$compose_file" << EOF
version: '3.8'
services:
  komari:
    image: $FULL_IMAGE_NAME # 使用构建好的镜像名称
    container_name: komari
    ports:
      - "25774:25774"
    volumes:
      - ./data:/app/data
    environment:
      - GIN_MODE=release
      - KOMARI_DB_TYPE=sqlite
      - KOMARI_DB_FILE=/app/data/komari.db
      # 可选：自定义初始管理员账号密码，首次启动时生效
      # - ADMIN_USERNAME=admin
      # - ADMIN_PASSWORD=yourpassword_secure_password_here
    restart: unless-stopped
EOF
    print_success "docker-compose.yml文件生成成功"
}

get_docker_username() {
    echo
    print_info "请输入您的Docker Hub用户名:"
    while true; do # 使用循环直到输入有效用户名
        read -p "Docker Hub用户名: " DOCKER_USERNAME
        if [ -n "$DOCKER_USERNAME" ]; then # 检查用户名是否为空
            break # 如果不为空，则跳出循环
        else
            print_warning "Docker Hub用户名不能为空，请重新输入。"
        fi
    done # <-- 闭合 while 循环
}

get_image_name() {
    echo
    print_info "请输入Docker镜像名称 [komari]:"
    read -p "镜像名称: " input_image_name
    IMAGE_NAME=${input_image_name:-komari} # 如果用户输入为空，则使用 'komari'
    print_info "Docker镜像名称设置为: $IMAGE_NAME"
}

get_image_tag() {
    echo
    print_info "请输入镜像标签 [latest]:"
    read -p "标签: " input_tag
    IMAGE_TAG=${input_tag:-latest}
}

get_image_info() {
    get_docker_username
    get_image_name
    get_image_tag
    FULL_IMAGE_NAME="${DOCKER_USERNAME}/${IMAGE_NAME}:${IMAGE_TAG}"
    print_info "配置完成: $FULL_IMAGE_NAME"
}

save_config() {
    local config_file=".docker-build-config"
    echo "DOCKER_USERNAME=$DOCKER_USERNAME" > "$config_file"
    echo "IMAGE_NAME=$IMAGE_NAME" >> "$config_file"
    echo "IMAGE_TAG=$IMAGE_TAG" >> "$config_file"
    print_success "配置已保存"
}

load_config() {
    local config_file=".docker-build-config"
    if [ -f "$config_file" ]; then
        source "$config_file"
        FULL_IMAGE_NAME="${DOCKER_USERNAME}/${IMAGE_NAME}:${IMAGE_TAG}"
        print_info "已加载配置: $FULL_IMAGE_NAME"
    fi
}

push_to_dockerhub() {
    print_info "是否要推送镜像到Docker Hub? (y/n)"
    read -p "请选择: " PUSH_CHOICE
    case $PUSH_CHOICE in
        [Yy]* ) 
            build_docker_image
            ;;
        * ) 
            print_info "跳过镜像推送"
            ;;
    esac
}

cleanup() {
    print_info "清理临时文件..."
    rm -rf "$FRONTEND_PROJECT" "$BACKEND_PROJECT"
    print_success "清理完成"
}

show_menu() {
    echo
    echo -e "${BLUE}=== Komari Docker 镜像构建脚本 ===${NC}"
    echo "1) 完整构建流程 (推荐)"
    echo "2) 配置镜像信息"
    echo "3) 仅构建前端"
    echo "4) 仅构建后端"
    echo "5) 仅构建Docker本地镜像"
    echo "6) 构建并推送Docker镜像"
    echo "8) 清理临时文件"
    echo "10) 生成docker-compose.yml"
    echo "0) 退出"
    echo
}

main() {
    init_work_directory
    check_requirements
    load_config
    
    while true; do
        show_menu
        read -p "请输入选项: " choice
        
        case $choice in
            1)
                if [ -z "$DOCKER_USERNAME" ]; then
                    get_image_info
                fi
                if build_frontend && build_backend && build_docker_image_local; then
                    push_to_dockerhub
                    save_config
                    generate_docker_compose
                    cleanup
                    print_success "完整流程执行完毕！"
                fi
                ;;
            2)
                get_image_info
                ;;
            3)
                build_frontend
                ;;
            4)
                build_backend
                ;;
            5)
                if [ -z "$DOCKER_USERNAME" ]; then
                    get_image_info
                fi
                build_docker_image_local
                ;;
            6)
                if [ -z "$DOCKER_USERNAME" ]; then
                    get_image_info
                fi
                build_docker_image
                ;;
            8)
                cleanup
                ;;
            10)
                generate_docker_compose
                ;;
            0)
                print_info "正在退出..."
                exit 0
                ;;
            *)
                print_error "无效选项: $choice"
                ;;
        esac
    done
}

# 启动脚本
main "$@"
