#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#  ERPNext Docker Compose 一键部署 / 卸载脚本
#  用法:
#    构建:  ./deploy.sh build
#    部署:  ./deploy.sh install  [-p PORT] [-P PASSWORD]
#    更新:  ./deploy.sh update
#    卸载:  ./deploy.sh uninstall
#    状态:  ./deploy.sh status
#    日志:  ./deploy.sh logs [service]
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
ENV_FILE="$SCRIPT_DIR/.env"
APPS_JSON="$SCRIPT_DIR/apps.json"
CONTAINERFILE="$SCRIPT_DIR/frappe_docker/images/custom/Containerfile"
PROJECT_NAME="erpnext"

# ---------- 默认值 ----------
DEFAULT_PORT=8080
DEFAULT_ADMIN_PASSWORD="admin"
DEFAULT_DB_PASSWORD="admin"
DEFAULT_FRAPPE_VERSION="v15.73.0"
DEFAULT_PYTHON_VERSION="3.11.9"
DEFAULT_NODE_VERSION="18.20.2"
DEFAULT_IMAGE_NAME="erpnext-custom"
DEFAULT_IMAGE_TAG="latest"

# ---------- 颜色 ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ---------- 工具函数 ----------
check_docker() {
    if ! command -v docker &>/dev/null; then
        log_error "未检测到 docker，请先安装 Docker"
        exit 1
    fi
    if ! command -v docker-compose &>/dev/null && ! docker compose version &>/dev/null; then
        log_error "未检测到 docker-compose，请先安装"
        exit 1
    fi
}

compose_cmd() {
    if docker compose version &>/dev/null; then
        docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "$@"
    else
        docker-compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "$@"
    fi
}

find_available_port() {
    local port=$1
    while ss -tlnp 2>/dev/null | grep -q ":${port} " || \
          netstat -tlnp 2>/dev/null | grep -q ":${port} "; do
        log_warn "端口 $port 已被占用，尝试 $((port+1))..."
        port=$((port+1))
    done
    echo "$port"
}

# ---------- 从 .env 读取变量 ----------
load_env() {
    if [ -f "$ENV_FILE" ]; then
        set -a
        # shellcheck source=/dev/null
        source "$ENV_FILE"
        set +a
    fi
}

# ---------- 生成 .env 文件 ----------
generate_env() {
    local port="$1"
    local admin_password="$2"
    local db_password="$3"
    local frappe_version="$4"
    local image_name="$5"
    local image_tag="$6"
    local python_version="$7"
    local node_version="$8"

    cat > "$ENV_FILE" <<EOF
# ERPNext 部署配置 (自动生成)

# 访问端口
ERPNEXT_PORT=${port}

# 管理员密码 (ERPNext 后台登录)
ADMIN_PASSWORD=${admin_password}

# 数据库 root 密码
DB_PASSWORD=${db_password}

# Frappe 框架版本
FRAPPE_VERSION=${frappe_version}

# 自定义镜像名称和标签
ERPNEXT_IMAGE=${image_name}
ERPNEXT_IMAGE_TAG=${image_tag}

# 构建参数
PYTHON_VERSION=${python_version}
NODE_VERSION=${node_version}
EOF

    log_info ".env 文件已生成"
}

# ---------- 构建镜像 ----------
do_build() {
    check_docker

    # 加载环境变量
    load_env
    local frappe_version="${FRAPPE_VERSION:-$DEFAULT_FRAPPE_VERSION}"
    local image_name="${ERPNEXT_IMAGE:-$DEFAULT_IMAGE_NAME}"
    local image_tag="${ERPNEXT_IMAGE_TAG:-$DEFAULT_IMAGE_TAG}"
    local python_version="${PYTHON_VERSION:-$DEFAULT_PYTHON_VERSION}"
    local node_version="${NODE_VERSION:-$DEFAULT_NODE_VERSION}"

    # 检查必要文件
    if [ ! -f "$APPS_JSON" ]; then
        log_error "未找到 apps.json，请先创建"
        exit 1
    fi
    if [ ! -f "$CONTAINERFILE" ]; then
        log_error "未找到 Containerfile，请先克隆 frappe_docker"
        exit 1
    fi

    # 生成 .env（如果不存在）
    if [ ! -f "$ENV_FILE" ]; then
        local port
        port=$(find_available_port "$DEFAULT_PORT")
        generate_env "$port" "$DEFAULT_ADMIN_PASSWORD" "$DEFAULT_DB_PASSWORD" \
            "$frappe_version" "$image_name" "$image_tag" "$python_version" "$node_version"
    fi

    local apps_json_base64
    apps_json_base64=$(base64 -w 0 "$APPS_JSON")

    log_info "开始构建自定义镜像 ${image_name}:${image_tag}"
    log_info "  Frappe:  ${frappe_version}"
    log_info "  Python:  ${python_version}"
    log_info "  Node:    ${node_version}"
    log_info "  Apps:    $(jq -r '.[].url' "$APPS_JSON" | xargs -I{} basename {})"
    echo ""

    docker build \
        --build-arg APPS_JSON_BASE64="$apps_json_base64" \
        --build-arg FRAPPE_BRANCH="$frappe_version" \
        --build-arg PYTHON_VERSION="$python_version" \
        --build-arg NODE_VERSION="$node_version" \
        -t "${image_name}:${image_tag}" \
        -f "$CONTAINERFILE" \
        "$SCRIPT_DIR/frappe_docker"

    log_info "镜像构建完成: ${image_name}:${image_tag}"
}

# ---------- 安装 ----------
do_install() {
    local port="$DEFAULT_PORT"
    local admin_password="$DEFAULT_ADMIN_PASSWORD"
    local db_password="$DEFAULT_DB_PASSWORD"
    local frappe_version="$DEFAULT_FRAPPE_VERSION"
    local image_name="$DEFAULT_IMAGE_NAME"
    local image_tag="$DEFAULT_IMAGE_TAG"
    local python_version="$DEFAULT_PYTHON_VERSION"
    local node_version="$DEFAULT_NODE_VERSION"

    # 如果已有 .env，先加载作为默认值
    if [ -f "$ENV_FILE" ]; then
        load_env
        port="${ERPNEXT_PORT:-$port}"
        admin_password="${ADMIN_PASSWORD:-$admin_password}"
        db_password="${DB_PASSWORD:-$db_password}"
        frappe_version="${FRAPPE_VERSION:-$frappe_version}"
        image_name="${ERPNEXT_IMAGE:-$image_name}"
        image_tag="${ERPNEXT_IMAGE_TAG:-$image_tag}"
        python_version="${PYTHON_VERSION:-$python_version}"
        node_version="${NODE_VERSION:-$node_version}"
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--port)     port="$2"; shift 2;;
            -P|--password) admin_password="$2"; db_password="$2"; shift 2;;
            *) log_error "未知参数: $1"; exit 1;;
        esac
    done

    check_docker

    # 检查镜像是否已构建
    if ! docker image inspect "${image_name}:${image_tag}" &>/dev/null; then
        log_warn "未找到镜像 ${image_name}:${image_tag}，先执行构建..."
        do_build
    fi

    # 自动检测可用端口
    port=$(find_available_port "$port")
    log_info "使用端口: $port"

    # 生成 .env 文件
    generate_env "$port" "$admin_password" "$db_password" \
        "$frappe_version" "$image_name" "$image_tag" "$python_version" "$node_version"

    # 启动基础服务
    log_info "正在启动基础服务 (db, redis, backend, frontend...)..."
    compose_cmd up -d backend db redis-cache redis-queue frontend websocket queue-long queue-short scheduler

    # 等待 DB 就绪
    log_info "等待数据库就绪..."
    local retries=0
    until compose_cmd exec -T db mysqladmin ping -h localhost --password="$db_password" --silent 2>/dev/null; do
        retries=$((retries+1))
        if [ $retries -ge 60 ]; then
            log_error "数据库启动超时"
            exit 1
        fi
        sleep 2
    done
    log_info "数据库已就绪"

    # 运行 configurator
    log_info "正在初始化配置..."
    compose_cmd up -d configurator
    compose_cmd wait configurator 2>/dev/null || sleep 10

    # 创建站点
    log_info "正在创建 ERPNext 站点 (这可能需要 3-5 分钟)..."
    compose_cmd up -d create-site

    # 等待站点创建完成
    log_info "等待站点创建完成..."
    local timeout=600
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        local status
        status=$(docker inspect --format='{{.State.Status}}' "${PROJECT_NAME}-create-site-1" 2>/dev/null || echo "running")
        if [ "$status" = "exited" ]; then
            local exit_code
            exit_code=$(docker inspect --format='{{.State.ExitCode}}' "${PROJECT_NAME}-create-site-1" 2>/dev/null || echo "1")
            if [ "$exit_code" = "0" ]; then
                log_info "站点创建成功!"
                break
            else
                log_error "站点创建失败，查看日志:"
                compose_cmd logs create-site | tail -20
                exit 1
            fi
        fi
        sleep 5
        elapsed=$((elapsed+5))
        if (( elapsed % 30 == 0 )); then
            log_info "  已等待 ${elapsed}s / ${timeout}s ..."
        fi
    done

    if [ $elapsed -ge $timeout ]; then
        log_error "站点创建超时 (${timeout}s)"
        compose_cmd logs create-site | tail -20
        exit 1
    fi

    # 获取主机 IP
    local host_ip
    host_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")

    echo ""
    echo -e "${CYAN}====================================================${NC}"
    echo -e "${CYAN}  ERPNext 部署完成!${NC}"
    echo -e "${CYAN}====================================================${NC}"
    echo -e "  访问地址:  ${GREEN}http://${host_ip}:${port}${NC}"
    echo -e "  用户名:    ${GREEN}Administrator${NC}"
    echo -e "  密码:      ${GREEN}${admin_password}${NC}"
    echo -e "  Frappe:    ${GREEN}${frappe_version}${NC}"
    echo -e "  Apps:      ${GREEN}$(jq -r '.[] | "\(.url | split("/") | last):\(.branch)"' "$APPS_JSON" 2>/dev/null | tr '\n' ' ')${NC}"
    echo -e "${CYAN}====================================================${NC}"
    echo -e "  管理命令:"
    echo -e "    查看状态:  ${YELLOW}./deploy.sh status${NC}"
    echo -e "    查看日志:  ${YELLOW}./deploy.sh logs [service]${NC}"
    echo -e "    更新服务:  ${YELLOW}./deploy.sh update${NC}"
    echo -e "    卸载清理:  ${YELLOW}./deploy.sh uninstall${NC}"
    echo -e "${CYAN}====================================================${NC}"
    echo ""
}

# ---------- 更新 ----------
do_update() {
    check_docker

    if [ ! -f "$ENV_FILE" ]; then
        log_error "未找到 .env 文件，请先运行 ./deploy.sh install"
        exit 1
    fi

    load_env
    local image_name="${ERPNEXT_IMAGE:-$DEFAULT_IMAGE_NAME}"
    local image_tag="${ERPNEXT_IMAGE_TAG:-$DEFAULT_IMAGE_TAG}"

    log_info "开始更新 ERPNext..."

    # 重新构建镜像
    log_info "步骤 1/3: 重新构建镜像..."
    do_build

    # 重启服务（使用新镜像）
    log_info "步骤 2/3: 重启服务..."
    compose_cmd up -d backend frontend websocket queue-long queue-short scheduler

    # 执行数据库迁移
    log_info "步骤 3/3: 执行数据库迁移..."
    compose_cmd exec -T backend bench --site frontend migrate

    log_info "更新完成!"
    compose_cmd ps
}

# ---------- 卸载 ----------
do_uninstall() {
    check_docker

    if [ ! -f "$COMPOSE_FILE" ]; then
        log_error "未找到 $COMPOSE_FILE，没有可卸载的部署"
        exit 1
    fi

    if [ ! -f "$ENV_FILE" ]; then
        log_error "未找到 .env 文件，没有可卸载的部署"
        exit 1
    fi

    load_env
    local image_name="${ERPNEXT_IMAGE:-$DEFAULT_IMAGE_NAME}"
    local image_tag="${ERPNEXT_IMAGE_TAG:-$DEFAULT_IMAGE_TAG}"

    echo -e "${YELLOW}即将执行以下操作:${NC}"
    echo "  1. 停止并删除所有 ERPNext 容器"
    echo "  2. 删除所有数据卷 (数据库、站点数据等)"
    echo "  3. 删除 Docker 网络"
    echo "  4. 删除 .env 配置文件"
    echo ""
    read -rp "$(echo -e "${RED}确认卸载? 所有数据将被删除且不可恢复! [y/N]: ${NC}")" confirm

    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_info "已取消卸载"
        exit 0
    fi

    log_info "正在停止并删除容器..."
    compose_cmd down -v --remove-orphans

    read -rp "$(echo -e "${YELLOW}是否同时删除自定义镜像 ${image_name}:${image_tag}? [y/N]: ${NC}")" rm_images
    if [[ "$rm_images" == "y" || "$rm_images" == "Y" ]]; then
        docker rmi "${image_name}:${image_tag}" 2>/dev/null || true
        compose_cmd down --rmi all -v --remove-orphans 2>/dev/null || true
        log_info "镜像已清理"
    fi

    rm -f "$ENV_FILE"
    log_info ".env 文件已删除"

    echo ""
    echo -e "${GREEN}ERPNext 已完全卸载${NC}"
}

# ---------- 状态 ----------
do_status() {
    check_docker
    if [ ! -f "$ENV_FILE" ]; then
        log_error "未找到 .env 文件，请先运行 ./deploy.sh install"
        exit 1
    fi
    load_env
    echo -e "${CYAN}镜像:${NC} ${ERPNEXT_IMAGE:-$DEFAULT_IMAGE_NAME}:${ERPNEXT_IMAGE_TAG:-$DEFAULT_IMAGE_TAG}"
    echo -e "${CYAN}Frappe:${NC} ${FRAPPE_VERSION:-$DEFAULT_FRAPPE_VERSION}"
    echo -e "${CYAN}端口:${NC} ${ERPNEXT_PORT:-$DEFAULT_PORT}"
    echo ""
    compose_cmd ps
}

# ---------- 日志 ----------
do_logs() {
    check_docker
    if [ ! -f "$ENV_FILE" ]; then
        log_error "未找到 .env 文件，请先运行 ./deploy.sh install"
        exit 1
    fi
    compose_cmd logs -f --tail=100 "$@"
}

# ---------- 帮助 ----------
show_help() {
    echo "ERPNext Docker 一键部署脚本"
    echo ""
    echo "用法: $0 <命令> [选项]"
    echo ""
    echo "命令:"
    echo "  build        构建自定义镜像 (含 ERPNext + HRMS)"
    echo "  install      部署 ERPNext (自动生成 .env，未构建时自动构建)"
    echo "  update       更新: 重新构建镜像 → 重启服务 → 数据库迁移"
    echo "  uninstall    卸载并清理所有数据"
    echo "  status       查看服务状态"
    echo "  logs         查看服务日志"
    echo ""
    echo "install 选项:"
    echo "  -p, --port PORT        指定访问端口 (默认: $DEFAULT_PORT, 冲突时自动递增)"
    echo "  -P, --password PASS    管理员/数据库密码 (默认: $DEFAULT_ADMIN_PASSWORD)"
    echo ""
    echo "版本配置 (通过 .env 文件):"
    echo "  FRAPPE_VERSION         Frappe 版本 (默认: $DEFAULT_FRAPPE_VERSION)"
    echo "  PYTHON_VERSION         Python 版本 (默认: $DEFAULT_PYTHON_VERSION)"
    echo "  NODE_VERSION           Node.js 版本 (默认: $DEFAULT_NODE_VERSION)"
    echo "  ERPNext/HRMS 版本      通过 apps.json 中的 branch 字段配置"
    echo ""
    echo "配置文件:"
    echo "  apps.json              应用列表及版本 (ERPNext, HRMS 等)"
    echo "  .env                   运行时配置 (install 自动生成，不提交到 git)"
    echo "  .env.example           配置模板 (提交到 git)"
    echo ""
    echo "示例:"
    echo "  $0 build                            # 仅构建镜像"
    echo "  $0 install                          # 构建 + 部署"
    echo "  $0 install -p 9090 -P mypass123     # 指定端口和密码"
    echo "  $0 update                           # 修改 apps.json 后更新"
    echo "  $0 uninstall                        # 卸载并清理"
    echo "  $0 logs frontend                    # 查看前端日志"
}

# ---------- 入口 ----------
case "${1:-}" in
    build)     do_build;;
    install)   shift; do_install "$@";;
    update)    do_update;;
    uninstall) do_uninstall;;
    status)    do_status;;
    logs)      shift; do_logs "$@";;
    -h|--help|help) show_help;;
    *)
        show_help
        exit 1
        ;;
esac
