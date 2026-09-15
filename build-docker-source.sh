#!/usr/bin/env bash
# Komari Docker 构建助手 v4.2 — 官方指南源码构建版
# 运行：bash build-docker-source.sh
# 依赖：Linux + Bash + Docker Engine + Buildx + Git。
# 按官方指南执行 npm install/build、tar、zstd、复制主题元数据、Go 编译。
# 编译工具在 Docker 中安装，无需在宿主机安装 Go/Node.js/zstd/GCC。
# 后端自动获取最新正式 Release 标签；前端使用官方默认分支；构建前重新克隆。
# 退出清理本工作区源码、本次专用 BuildKit 缓存及临时产物；保留最终结果和配置。
set -u
set -o pipefail
umask 077
ROOT="$(pwd -P)/komari-source-work"
CONFIG="$ROOT/settings.conf"
BACKEND_REF="latest"
FRONTEND_REF="default"
IMAGE="komari-local:latest"
PROXY=""
TEST_CONTAINER=""
BUILT_IMAGE=""
PLATFORMS="linux/amd64,linux/arm64"
OUTPUT_MODE="oci"
BUILDER="komari-source-session-$$-$RANDOM"
BUILDER_CREATED=false
LOCK_OWNED=false
TEMP_IMAGE=""
PARTIAL_EXPORT=""
GO_IMAGE="${KOMARI_GO_IMAGE:-}"
RUNTIME_IMAGE="${KOMARI_RUNTIME_IMAGE:-alpine:3.21}"
NODE_IMAGE="${KOMARI_NODE_IMAGE:-node:22-bookworm-slim}"
# 自定义 Go 镜像必须含 Go 和 apk；运行镜像必须支持 apk。
# 使用本次专用 docker-container 构建器，退出时删除，避免残留构建缓存。
log() { printf '[%s] %s\n' "$1" "$2"; }
info() { log INFO "$*"; }
ok() { log SUCCESS "$*"; }
err() { log ERROR "$*" >&2; }
warn() { log WARNING "$*"; }
pause() { local unused; read -r -p '按回车返回菜单...' unused || true; }
valid_ref() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,100}$ && "$1" != *..* ]]; }
valid_image() {
    [[ "$1" =~ ^([a-z0-9]+([._-][a-z0-9]+)*/)?[a-z0-9]+([._-][a-z0-9]+)*:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]
}
valid_proxy() { [[ -z "$1" || "$1" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[-A-Za-z0-9._~/]*)?$ ]]; }
clean_sources() {
    # 只处理固定工作区，拒绝沿符号链接删除其他位置。
    [[ "$ROOT" == */komari-source-work && ! -L "$ROOT" && ! -L "$ROOT/sources" ]] || {
        err '工作目录异常或存在符号链接，停止源码清理'; return 1;
    }
    if [[ -d "$ROOT/sources" ]]; then
        info '正在删除工作区内旧前端、后端源码及中间文件...'
        rm -rf -- "$ROOT/sources" || return 1
    fi
    rm -f -- "$ROOT/current" "$ROOT/current.tmp"
}
cleanup_exit() {
    local failed=0
    [[ "$LOCK_OWNED" == true ]] || return 0
    info '脚本退出，正在清理本次构建产物...'
    if [[ -n "$TEMP_IMAGE" ]]; then
        docker image rm "$TEMP_IMAGE" >/dev/null 2>&1 || { warn "临时镜像清理失败：$TEMP_IMAGE"; failed=1; }
    fi
    if [[ -n "$PARTIAL_EXPORT" ]]; then
        rm -f -- "$PARTIAL_EXPORT" || failed=1
    fi
    if [[ "$BUILDER_CREATED" == true ]]; then
        info '正在删除本次专用构建器及其构建缓存...'
        if docker buildx rm --force "$BUILDER"; then BUILDER_CREATED=false
        else warn "构建器清理失败，可稍后执行：docker buildx rm --force $BUILDER"; failed=1; fi
    fi
    clean_sources || failed=1
    rm -f -- "$ROOT/settings.conf.tmp" || failed=1
    rmdir "$ROOT/run.lock" 2>/dev/null || failed=1
    LOCK_OWNED=false
    if [[ "$failed" == 0 ]]; then
        ok '清理完成；最终镜像、完整导出包、配置和 Compose 已保留'
    else warn '部分清理未完成，请查看上方提示'; fi
}
trap cleanup_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
load_config() {
    [[ -f "$CONFIG" ]] || return 0
    local key value
    while IFS='=' read -r key value; do
        case "$key" in
            BACKEND_REF) BACKEND_REF=latest ;;
            FRONTEND_REF) FRONTEND_REF=default ;;
            IMAGE) valid_image "$value" && IMAGE="$value" ;;
            PROXY) valid_proxy "$value" && PROXY="$value" ;;
        esac
    done < "$CONFIG"
    return 0
}
configure() {
    local backend frontend image proxy
    info '源码策略：后端最新正式 Release；前端官方默认分支'
    backend=latest; frontend=default
    read -r -p "镜像名称 [$IMAGE]（例如 用户名/komari:latest）: " image || return 1
    info "GitHub 加速前缀：${PROXY:-直连}；输入 none 取消，留空保持"
    read -r -p '例如 https://gh.panell.pp.ua/ : ' proxy || return 1
    backend=${backend:-$BACKEND_REF}; frontend=${frontend:-$FRONTEND_REF}
    image=${image:-$IMAGE}; proxy=${proxy:-$PROXY}
    [[ "$proxy" == none ]] && proxy=""
    valid_ref "$backend" && valid_ref "$frontend" || { err '分支或标签格式无效'; return 1; }
    valid_image "$image" || { err '请输入小写镜像名，并包含 :标签'; return 1; }
    valid_proxy "$proxy" || { err '加速前缀必须为 HTTPS 地址'; return 1; }
    [[ -z "$proxy" ]] || proxy="${proxy%/}/"
    BACKEND_REF="$backend"; FRONTEND_REF="$frontend"; IMAGE="$image"; PROXY="$proxy"
    printf 'BACKEND_REF=%s\nFRONTEND_REF=%s\nIMAGE=%s\nPROXY=%s\n' \
        "$BACKEND_REF" "$FRONTEND_REF" "$IMAGE" "$PROXY" > "$CONFIG.tmp" &&
        mv -f "$CONFIG.tmp" "$CONFIG" || return 1
    BUILT_IMAGE=""
    ok '配置已保存；分支更改后请选择 1 或 7 拉取源码'
}
check_docker() {
    command -v docker >/dev/null 2>&1 || { err '请先安装 Docker Engine'; return 1; }
    docker info >/dev/null 2>&1 || { err '无法访问 Docker 服务，请检查服务或账号权限'; return 1; }
    local os
    os=$(docker info --format '{{.OSType}}') || return 1
    [[ "$os" == linux ]] || { err '需要 Linux 容器引擎'; return 1; }
    docker buildx version >/dev/null 2>&1 || { err '请安装 Docker Buildx 插件'; return 1; }
    info "脚本主机：$(uname -m)；目标架构由菜单选择，不要求与主机相同"
}
setup_builder() {
    check_docker || return 1
    if [[ "$BUILDER_CREATED" != true ]]; then
        # 不复用或删除其他构建器，避免清理影响其他项目。
        while docker buildx inspect "$BUILDER" >/dev/null 2>&1; do
            BUILDER="komari-source-session-$$-$RANDOM"
        done
        docker buildx create --name "$BUILDER" --driver docker-container || return 1
        BUILDER_CREATED=true
    fi
    docker buildx inspect --bootstrap "$BUILDER" || return 1
}
valid_platforms() {
    local item seen=, count=0
    local -a items
    [[ -n "$1" && "$1" != *, && "$1" != ,* && "$1" != *,,* ]] || return 1
    IFS=, read -r -a items <<< "$1"
    for item in "${items[@]}"; do
        case "$item" in linux/amd64|linux/arm64) ;; *) return 1 ;; esac
        [[ "$seen" != *",$item,"* ]] || return 1
        seen="$seen$item,"; ((count+=1))
    done
    ((count > 0))
}
select_platforms() {
    local choice selected
    printf '\n选择构建目标：\n1) AMD64 + ARM64（默认）\n2) 仅 AMD64\n3) 仅 ARM64\n0) 返回\n'
    read -r -p '请选择 [1]: ' choice || return 1
    case "${choice:-1}" in
        1) selected=linux/amd64,linux/arm64 ;;
        2) selected=linux/amd64 ;;
        3) selected=linux/arm64 ;;
        0) return 0 ;;
        *) err '无效选项'; return 1 ;;
    esac
    PLATFORMS="$selected"
    printf '%s\n' "$PLATFORMS" > "$ROOT/platforms.conf" || return 1
    ok "构建目标：$PLATFORMS"
}
prompt_image_info() {
    local username name tag answer default_user="" default_name=komari default_tag=latest
    local repository="${IMAGE%:*}"
    if [[ "$IMAGE" == */* ]]; then
        default_user="${repository%%/*}"
        default_name="${repository#*/}"
        default_tag="${IMAGE##*:}"
    fi
    while true; do
        printf '\n=== 构建前设置镜像信息 ===\n'
        read -r -p "Docker Hub 用户名${default_user:+ [$default_user]}: " username || return 1
        username=${username:-$default_user}
        if [[ ! "$username" =~ ^[a-z0-9]+$ ]]; then
            err 'Docker Hub 用户名不能为空，且只能包含小写字母和数字'
            continue
        fi
        read -r -p "镜像名称 [$default_name]: " name || return 1
        name=${name:-$default_name}
        read -r -p "镜像标签 [$default_tag]: " tag || return 1
        tag=${tag:-$default_tag}
        if ! valid_image "$username/$name:$tag"; then
            err '镜像名称或标签格式无效，请重新输入'
            continue
        fi
        printf '\nDocker 用户名：%s\n镜像名称：%s\n镜像标签：%s\n完整镜像地址：%s/%s:%s\n目标架构：%s\n' \
            "$username" "$name" "$tag" "$username" "$name" "$tag" "$PLATFORMS"
        read -r -p '确认使用以上信息？[Y/n，输入 0 取消]: ' answer || return 1
        case "$answer" in
            ''|y|Y)
                IMAGE="$username/$name:$tag"
                printf 'BACKEND_REF=%s\nFRONTEND_REF=%s\nIMAGE=%s\nPROXY=%s\n' \
                    "$BACKEND_REF" "$FRONTEND_REF" "$IMAGE" "$PROXY" > "$CONFIG.tmp" &&
                    mv -f "$CONFIG.tmp" "$CONFIG" || { err '镜像配置保存失败'; return 1; }
                ok "已确认镜像：$IMAGE"
                return 0 ;;
            0) info '已取消本次构建'; return 1 ;;
            n|N) default_user="$username"; default_name="$name"; default_tag="$tag" ;;
            *) warn '未确认，请重新填写并确认' ;;
        esac
    done
}
choose_output() {
    local choice
    printf '\n构建结果保存方式：\n1) 构建并推送 Docker Hub（多架构共用一个标签）\n2) 导出 OCI 镜像归档（默认，不上传）\n3) 加载到本地 Docker（仅选择一个架构时可用）\n0) 取消本次构建\n'
    read -r -p '请选择 [2]: ' choice || return 1
    case "${choice:-2}" in
        1) OUTPUT_MODE=push ;;
        2) OUTPUT_MODE=oci ;;
        3) [[ "$PLATFORMS" != *,* ]] || { err '本脚本的本地加载模式只接收单架构；多架构请选择推送或 OCI'; return 1; }; OUTPUT_MODE=load ;;
        0) info '已取消'; return 1 ;;
        *) err '无效选项'; return 1 ;;
    esac
}
show_summary() {
    local target="$1" item
    printf '\n========== 即将开始构建 ==========\n'
    info "阶段：$target"
    info "主机：$(uname -m)；构建器：$BUILDER"
    local -a items
    IFS=, read -r -a items <<< "$PLATFORMS"
    for item in "${items[@]}"; do info "即将构建 ${item#linux/} 镜像（$item）"; done
    info "镜像标签：$IMAGE；输出方式：$OUTPUT_MODE"
    info "编译环境：$EFFECTIVE_GO_IMAGE；运行环境：$RUNTIME_IMAGE"
    printf '==================================\n'
}
preflight() {
    local platform stage
    local -a items
    IFS=, read -r -a items <<< "$PLATFORMS"
    # 实际执行目标架构程序，验证基础镜像存在和模拟器/原生节点可用。
    # 不自动执行 privileged 命令，不强制修改宿主机 binfmt 配置。
    cat > "$DIR/Dockerfile.check" <<'CHECK'
ARG GO_IMAGE=golang:1.25.0-alpine
ARG RUNTIME_IMAGE=alpine:3.21
ARG NODE_IMAGE=node:22-bookworm-slim
FROM --platform=$BUILDPLATFORM ${NODE_IMAGE} AS nodecheck
RUN node --version && npm --version
FROM ${GO_IMAGE} AS gocheck
RUN go version && apk --version
FROM ${RUNTIME_IMAGE} AS runtimecheck
RUN uname -m && apk --version
CHECK
    [[ $? == 0 ]] || return 1
    for stage in nodecheck gocheck runtimecheck; do
        for platform in "${items[@]}"; do
            info "环境预检：$stage / $platform"
            if ! docker buildx build --builder "$BUILDER" --progress plain --platform "$platform" \
                --build-arg "GO_IMAGE=$EFFECTIVE_GO_IMAGE" --build-arg "RUNTIME_IMAGE=$RUNTIME_IMAGE" \
                --build-arg "NODE_IMAGE=$NODE_IMAGE" --target "$stage" \
                --output type=cacheonly -f "$DIR/Dockerfile.check" "$DIR"; then
                err "环境预检失败：$stage / $platform；尚未开始完整源码编译"
                info 'no matching manifest：基础镜像没有该架构，需更换对应基础镜像。'
                info 'exec format error：需要可执行该架构的 BuildKit 模拟器或原生构建节点。'
                info '网络错误：检查 Docker Hub 及基础镜像源连通性。'
                return 1
            fi
            # 前端固定在构建节点平台执行，不需要每个目标都重复检查。
            [[ "$stage" != nodecheck ]] || break
        done
    done
}
push_image() {
    info '重新获取源码，按所选架构构建并推送'
    prompt_image_info || return 1
    OUTPUT_MODE=push
    build_target runtime
}
generate_compose() {
    local file="$ROOT/docker-compose.yml" backup
    if [[ -e "$file" ]]; then
        backup="$file.bak.$(date +%Y%m%d-%H%M%S).$$"
        cp -p "$file" "$backup" || return 1
        info "旧 Compose 已备份：$backup"
    fi
    cat > "$file" <<COMPOSE
services:
  komari:
    image: "$IMAGE"
    ports:
      - "25774:25774"
    volumes:
      - ./data:/app/data
    environment:
      GIN_MODE: release
      KOMARI_LISTEN: "0.0.0.0:25774"
      TZ: Asia/Shanghai
    restart: unless-stopped
COMPOSE
    [[ $? == 0 ]] || return 1
    ok "Compose 已生成：$file"
    info '相对数据目录为 komari-source-work/data；更新已有部署时请改成原数据目录。'
    info '脚本不会自动启动、替换或停止你已有的服务。'
}

clone_repo() {
    local repo="$1" ref="$2" dest="$3"
    local -a ref_args=()
    [[ "$ref" == default ]] || ref_args=(--branch "$ref")
    info "正在克隆 $repo，分支/标签：$ref"
    if git clone --depth 1 "${ref_args[@]}" "https://github.com/komari-monitor/$repo.git" "$dest"; then return 0; fi
    if [[ -n "$PROXY" ]]; then
        warn '直连失败，使用配置的加速前缀重试'
        # dest 是本次 mktemp 工作区内的新目录，仅清理失败的克隆。
        rm -rf -- "$dest" || return 1
        git clone --depth 1 "${ref_args[@]}" "${PROXY}https://github.com/komari-monitor/$repo.git" "$dest" && return 0
    fi
    err '克隆失败，请检查网络和分支/标签是否存在'
    return 1
}
get_official_release() {
    command -v curl >/dev/null 2>&1 || { err '请安装 curl 和 ca-certificates 后重试'; return 1; }
    local effective="" url=https://github.com/komari-monitor/komari/releases/latest
    info '正在获取官方最新正式 Release 版本号...'
    effective=$(curl -fsSL --retry 2 --connect-timeout 20 --max-time 90 \
        --proto '=https' --proto-redir '=https' -o /dev/null -w '%{url_effective}' "$url") || effective=""
    if [[ "$effective" != */releases/tag/* && -n "$PROXY" ]]; then
        effective=$(curl -fsSL --retry 2 --connect-timeout 20 --max-time 90 \
            --proto '=https' --proto-redir '=https' -o /dev/null -w '%{url_effective}' "${PROXY}${url}") || effective=""
    fi
    [[ "$effective" == */komari-monitor/komari/releases/tag/* ]] || {
        err '无法解析官方最新正式版，已停止；不会使用 main 冒充正式版'; return 1;
    }
    OFFICIAL_TAG=${effective##*/}
    [[ "$OFFICIAL_TAG" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { err '官方版本号格式无效'; return 1; }
    ok "官方最新版本：$OFFICIAL_TAG"
}
prepare_sources() {
    command -v git >/dev/null 2>&1 || { err '缺少 Git：Debian/Ubuntu 可执行 sudo apt-get install -y git ca-certificates'; return 1; }
    local dir
    get_official_release || return 1
    clean_sources || return 1
    mkdir -p "$ROOT/sources" || return 1
    dir=$(mktemp -d "$ROOT/sources/build.XXXXXX") || return 1
    clone_repo komari "$OFFICIAL_TAG" "$dir/komari" &&
        clone_repo komari-web "$FRONTEND_REF" "$dir/komari-web" || {
        err "源码获取失败，保留现场：$dir"; return 1;
    }
    printf '%s\n%s\n' "$OFFICIAL_TAG" "$FRONTEND_REF" > "$dir/refs" || return 1
    printf '%s\n' "${dir##*/}" > "$ROOT/current.tmp" && mv -f "$ROOT/current.tmp" "$ROOT/current" || return 1
    BUILT_IMAGE=""
    ok "源码已准备：$dir"
}
load_sources() {
    local name backend frontend
    [[ -f "$ROOT/current" ]] || { err '请先选择 7 拉取源码，或选择 1 执行完整流程'; return 1; }
    read -r name < "$ROOT/current" || return 1
    [[ "$name" =~ ^build\.[A-Za-z0-9]+$ ]] || { err '工作区记录无效'; return 1; }
    DIR="$ROOT/sources/$name"
    { read -r backend; read -r frontend; } < "$DIR/refs" || return 1
    [[ "$backend" == "${OFFICIAL_TAG:-}" && "$frontend" == "$FRONTEND_REF" ]] || {
        err '配置的分支与当前源码不一致，请先选择 7 获取新源码'; return 1;
    }
    [[ -f "$DIR/komari/go.mod" && -f "$DIR/komari-web/package.json" ]] || {
        err '源码不完整，请重新获取'; return 1;
    }
    GO_VERSION=$(awk '$1 == "go" {print $2; exit}' "$DIR/komari/go.mod")
    [[ "$GO_VERSION" =~ ^1\.[0-9]+(\.[0-9]+)?$ ]] || { err '无法从 go.mod 解析 Go 版本'; return 1; }
    BACKEND_HASH=$(git -C "$DIR/komari" rev-parse HEAD) || return 1
    FRONTEND_HASH=$(git -C "$DIR/komari-web" rev-parse HEAD) || return 1
    local tag_commit
    tag_commit=$(git -C "$DIR/komari" rev-parse "refs/tags/$OFFICIAL_TAG^{commit}") || return 1
    [[ "$tag_commit" == "$BACKEND_HASH" ]] || { err '实际代码与官方 Release 标签不一致，停止构建'; return 1; }
    [[ -z "$(git -C "$DIR/komari" status --porcelain)" ]] || { err '正式版源码有本地改动，停止构建'; return 1; }
    VERSION="$OFFICIAL_TAG"
    SHORT_HASH="${BACKEND_HASH:0:7}"
    info "网页显示版本：$VERSION；网页显示提交：$SHORT_HASH"
    info "前端实际分支：$(git -C "$DIR/komari-web" branch --show-current)"
    info "后端版本：$VERSION，提交：${BACKEND_HASH:0:7}；前端提交：${FRONTEND_HASH:0:7}"
    info "Go 工具链要求：$GO_VERSION；Node.js 构建环境：22"
}
write_source_dockerfile() {
    EFFECTIVE_GO_IMAGE="${GO_IMAGE:-golang:${GO_VERSION}-alpine}"
    cat > "$DIR/Dockerfile" <<'DOCKERFILE'
# syntax=docker/dockerfile:1
ARG GO_IMAGE=golang:1.25.0-alpine
ARG RUNTIME_IMAGE=alpine:3.21
ARG NODE_IMAGE=node:22-bookworm-slim
FROM --platform=$BUILDPLATFORM ${NODE_IMAGE} AS frontend
WORKDIR /src/komari-web
COPY komari-web/ ./
RUN node --version && npm --version
RUN npm install --include=dev --no-audit --no-fund --loglevel=verbose \
    || { rc=$?; echo "[ERROR] npm 依赖安装失败，退出码 $rc"; cat /root/.npm/_logs/*debug* 2>/dev/null || true; exit "$rc"; }
RUN npm run build \
    || { rc=$?; echo "[ERROR] 前端编译失败，退出码 $rc；请查看上方 TypeScript/Vite 错误"; exit "$rc"; }
RUN test -s dist/index.html || { echo '[ERROR] 前端构建后缺少 dist/index.html'; exit 1; }
RUN test -s komari-theme.json || { echo '[ERROR] 前端仓库缺少 komari-theme.json'; exit 1; }

FROM ${GO_IMAGE} AS backend
RUN apk add --no-cache gcc musl-dev linux-headers tar zstd ca-certificates git
WORKDIR /src/komari
COPY komari/ ./
COPY --from=frontend /src/komari-web/dist/ /tmp/frontend-dist/
COPY --from=frontend /src/komari-web/komari-theme.json /tmp/komari-theme.json
# 官方指南：归档根目录为 ./index.html，不能多套一层 dist。
RUN mkdir -p web/public/defaultTheme \
    && rm -rf web/public/defaultTheme/dist \
    && tar -cf /tmp/komari-dist.tar -C /tmp/frontend-dist . \
    && zstd -19 -T1 -f /tmp/komari-dist.tar -o web/public/defaultTheme/dist.tar.zst \
    && zstd -t web/public/defaultTheme/dist.tar.zst \
    && tar -tf /tmp/komari-dist.tar | grep -qx './index.html' \
    && cp /tmp/komari-theme.json web/public/defaultTheme/komari-theme.json \
    && rm -f /tmp/komari-dist.tar
ARG KOMARI_VERSION
ARG KOMARI_HASH
ARG KOMARI_SHORT_HASH
ARG TARGETOS
ARG TARGETARCH
ENV CGO_ENABLED=1 GOOS=${TARGETOS} GOARCH=${TARGETARCH}
# 在 musl 环境静态链接，避免宿主机 glibc 与运行镜像版本不一致。
RUN mkdir -p /out \
    && go build -trimpath -ldflags="-s -w -linkmode external -extldflags '-static' -X github.com/komari-monitor/komari/utils.CurrentVersion=${KOMARI_VERSION} -X github.com/komari-monitor/komari/utils.VersionHash=${KOMARI_SHORT_HASH}" -o /out/komari .

FROM ${RUNTIME_IMAGE} AS runtime
WORKDIR /app
RUN apk add --no-cache ca-certificates curl tzdata
COPY --from=backend /out/komari /app/komari
ARG KOMARI_VERSION
ARG KOMARI_HASH
ARG FRONTEND_HASH
LABEL org.opencontainers.image.title="Komari" \
      org.opencontainers.image.version="${KOMARI_VERSION}" \
      org.opencontainers.image.revision="${KOMARI_HASH}" \
      org.opencontainers.image.source="https://github.com/komari-monitor/komari" \
      io.komari.frontend.revision="${FRONTEND_HASH}"
ENV GIN_MODE=release KOMARI_LISTEN=0.0.0.0:25774 TZ=Asia/Shanghai
# 在目标平台完成启动测试；临时数据不写入镜像层。
RUN --mount=type=tmpfs,target=/app/data --mount=type=tmpfs,target=/tmp \
    set -eu; /app/komari server >/tmp/startup.log 2>&1 & pid=$!; \
    trap 'kill "$pid" 2>/dev/null || true' EXIT; \
    healthy=0; i=0; \
    while [ "$i" -lt 60 ]; do \
      if curl -fsS --max-time 1 -o /dev/null http://127.0.0.1:25774/ 2>/dev/null; then healthy=1; break; fi; \
      kill -0 "$pid" 2>/dev/null || break; i=$((i+1)); sleep 1; \
    done; \
    if [ "$healthy" != 1 ]; then cat /tmp/startup.log; exit 1; fi
EXPOSE 25774
CMD ["/app/komari", "server"]
DOCKERFILE
    [[ $? == 0 ]] || return 1
    cat > "$DIR/.dockerignore" <<'IGNORE'
**/.git
**/node_modules
**/dist
**/data
**/*.log
**/.env
IGNORE
}
build_target() {
    local target="$1" out="" temp_tag="komari-multi-check:run-$$-$RANDOM"
    local -a output_args=()
    valid_platforms "$PLATFORMS" || { err '架构配置无效'; return 1; }
    setup_builder && prepare_sources && load_sources && write_source_dockerfile || return 1
    show_summary "$target"
    preflight || return 1
    if [[ "$target" != runtime ]]; then
        output_args=(--output type=cacheonly)
    else
        case "$OUTPUT_MODE" in
            push)
                [[ "$IMAGE" == */* ]] || { err '镜像地址格式无效，请重新开始构建并填写镜像信息'; return 1; }
                docker login || { err 'Docker Hub 登录失败'; return 1; }
                output_args=(--push -t "$IMAGE") ;;
            oci)
                mkdir -p "$ROOT/exports" || return 1
                out="$ROOT/exports/komari-$(date +%Y%m%d-%H%M%S)-$$-$RANDOM.oci.tar"
                PARTIAL_EXPORT="$out.partial"
                output_args=(--output "type=oci,dest=$out.partial" -t "$IMAGE") ;;
            load)
                [[ "$PLATFORMS" != *,* ]] || { err '本地加载模式仅允许单架构'; return 1; }
                TEMP_IMAGE="$temp_tag"
                output_args=(--load -t "$temp_tag") ;;
            *) err '输出方式无效'; return 1 ;;
        esac
    fi
    info "开始源码构建：$target / $PLATFORMS"
    # 后端在目标架构环境中使用匹配的 C 编译器处理 CGO。
    if ! docker buildx build --builder "$BUILDER" --progress plain --platform "$PLATFORMS" \
        --target "$target" --build-arg "GO_IMAGE=$EFFECTIVE_GO_IMAGE" \
        --build-arg "RUNTIME_IMAGE=$RUNTIME_IMAGE" --build-arg "NODE_IMAGE=$NODE_IMAGE" \
        --build-arg "KOMARI_VERSION=$VERSION" --build-arg "KOMARI_HASH=$BACKEND_HASH" --build-arg "KOMARI_SHORT_HASH=$SHORT_HASH" \
        --build-arg "FRONTEND_HASH=$FRONTEND_HASH" "${output_args[@]}" "$DIR"; then
        err '构建失败；不会将未完成的导出标记为成功'
        if [[ -n "$PARTIAL_EXPORT" ]]; then
            if rm -f -- "$PARTIAL_EXPORT"; then PARTIAL_EXPORT=""; fi
        fi
        if [[ -n "$TEMP_IMAGE" ]]; then
            if ! docker image inspect "$TEMP_IMAGE" >/dev/null 2>&1 || docker image rm "$TEMP_IMAGE"; then TEMP_IMAGE=""; fi
        fi
        return 1
    fi
    if [[ "$target" != runtime ]]; then ok "阶段 $target 已完成，结果保存在构建缓存中"; return 0; fi
    case "$OUTPUT_MODE" in
        load)
            docker tag "$temp_tag" "$IMAGE" || return 1
            if docker image rm "$temp_tag" >/dev/null 2>&1; then TEMP_IMAGE=""; fi
            ok "单架构镜像已加载：$IMAGE（$PLATFORMS）" ;;
        oci)
            mv -f "$out.partial" "$out" || return 1
            PARTIAL_EXPORT=""
            ok "OCI 多架构镜像归档：$out"
            info 'OCI 归档不是源码 tar；经典 Docker image store 不能直接 docker load 多架构 OCI。'
            info '可使用支持 OCI 的工具导入；若要普通 docker load，请选择单架构本地加载后 docker save。' ;;
        push)
            ok "多架构镜像已推送：$IMAGE"
            docker buildx imagetools inspect "$IMAGE" || warn '推送成功，但远端清单查询失败，请稍后检查' ;;
    esac
    ok '目标镜像均完成构建期启动检查（缓存命中时复用之前的成功检查）'
    generate_compose
}
build_frontend() { OUTPUT_MODE=cache; build_target frontend; }
build_backend() { OUTPUT_MODE=cache; build_target backend; }
build_image() { choose_output && prompt_image_info && build_target runtime; }
full_build() {
    choose_output && prompt_image_info && build_target runtime
}
main() {
    [[ "$(uname -s)" == Linux ]] || { err '请在 Linux 系统运行'; return 1; }
    [[ ! -L "$ROOT" ]] || { err '工作区不能是符号链接'; return 1; }
    mkdir -p "$ROOT" || return 1
    if ! mkdir "$ROOT/run.lock" 2>/dev/null; then
        err "已有脚本运行或存在遗留锁：$ROOT/run.lock"
        info '确认没有其他实例后，可用 rmdir 删除该空锁目录。'; return 1
    fi
    LOCK_OWNED=true
    trap cleanup_exit EXIT
    load_config
    if [[ -f "$ROOT/platforms.conf" ]]; then
        local saved_platforms
        read -r saved_platforms < "$ROOT/platforms.conf" || saved_platforms=""
        if valid_platforms "$saved_platforms"; then PLATFORMS="$saved_platforms"; fi
    fi
    local choice status
    while true; do
        printf '\n=== Komari Docker 构建助手 v4.2 · AMD64/ARM64 源码构建版 ===\n'
        printf '后端：%s | 前端：%s\n目标架构：%s\n镜像：%s\n' "$BACKEND_REF" "$FRONTEND_REF" "$PLATFORMS" "$IMAGE"
        printf '1) 完整流程：获取新源码、编译、制作镜像、验证\n2) 配置镜像及 GitHub 加速（版本自动获取）\n3) 重新拉取源码并构建前端\n4) 重新拉取源码并构建后端\n5) 重新拉取源码并构建镜像\n6) 重新拉取源码并构建、推送多架构镜像\n7) 清理旧源码并重新拉取\n8) 选择目标架构\n10) 生成 docker-compose.yml\n0) 退出\n\n'
        read -r -p '请输入选项: ' choice || break
        status=0
        case "$choice" in
            1) full_build || status=$? ;;
            2) configure || status=$? ;;
            3) build_frontend || status=$? ;;
            4) build_backend || status=$? ;;
            5) build_image || status=$? ;;
            6) push_image || status=$? ;;
            7) prepare_sources || status=$? ;;
            8) select_platforms || status=$? ;;
            10) generate_compose || status=$? ;;
            0) if [[ -t 1 && -n "${TERM:-}" ]]; then clear 2>/dev/null || true; fi; break ;;
            *) warn '无效选项'; continue ;;
        esac
        [[ "$status" == 0 ]] || err '本次操作失败，已返回菜单；请根据日志修复后重试'
        pause
    done
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
