#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#  ERPNext Docker Compose 一键部署 / 卸载脚本
#  用法:
#    部署:  ./deploy.sh install  [-p PORT] [-P PASSWORD] [-v VERSION]
#    卸载:  ./deploy.sh uninstall
#    状态:  ./deploy.sh status
#    日志:  ./deploy.sh logs [service]
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
PROJECT_NAME="erpnext"

# ---------- 默认值 ----------
DEFAULT_PORT=8080
DEFAULT_PASSWORD="admin"
DEFAULT_VERSION="v16.8.3"

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
        docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" "$@"
    else
        docker-compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" "$@"
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

# ---------- 生成 docker-compose.yml ----------
generate_compose() {
    local port="$1"
    local password="$2"
    local version="$3"

    cat > "$COMPOSE_FILE" <<YAML
services:
  backend:
    image: frappe/erpnext:${version}
    networks:
      - frappe_network
    deploy:
      restart_policy:
        condition: on-failure
    volumes:
      - sites:/home/frappe/frappe-bench/sites
      - logs:/home/frappe/frappe-bench/logs
    environment:
      DB_HOST: db
      DB_PORT: "3306"
      MYSQL_ROOT_PASSWORD: ${password}
      MARIADB_ROOT_PASSWORD: ${password}

  configurator:
    image: frappe/erpnext:${version}
    networks:
      - frappe_network
    deploy:
      restart_policy:
        condition: none
    entrypoint:
      - bash
      - -c
    command:
      - >
        ls -1 apps > sites/apps.txt;
        bench set-config -g db_host \$\$DB_HOST;
        bench set-config -gp db_port \$\$DB_PORT;
        bench set-config -g redis_cache "redis://\$\$REDIS_CACHE";
        bench set-config -g redis_queue "redis://\$\$REDIS_QUEUE";
        bench set-config -g redis_socketio "redis://\$\$REDIS_QUEUE";
        bench set-config -gp socketio_port \$\$SOCKETIO_PORT;
    environment:
      DB_HOST: db
      DB_PORT: "3306"
      REDIS_CACHE: redis-cache:6379
      REDIS_QUEUE: redis-queue:6379
      SOCKETIO_PORT: "9000"
    volumes:
      - sites:/home/frappe/frappe-bench/sites
      - logs:/home/frappe/frappe-bench/logs

  create-site:
    image: frappe/erpnext:${version}
    networks:
      - frappe_network
    deploy:
      restart_policy:
        condition: none
    volumes:
      - sites:/home/frappe/frappe-bench/sites
      - logs:/home/frappe/frappe-bench/logs
    entrypoint:
      - bash
      - -c
    command:
      - >
        wait-for-it -t 120 db:3306;
        wait-for-it -t 120 redis-cache:6379;
        wait-for-it -t 120 redis-queue:6379;
        export start=\`date +%s\`;
        until [[ -n \`grep -hs ^ sites/common_site_config.json | jq -r ".db_host // empty"\` ]] &&
          [[ -n \`grep -hs ^ sites/common_site_config.json | jq -r ".redis_cache // empty"\` ]] &&
          [[ -n \`grep -hs ^ sites/common_site_config.json | jq -r ".redis_queue // empty"\` ]];
        do
          echo "Waiting for sites/common_site_config.json to be created";
          sleep 5;
          if (( \`date +%s\`-start > 120 )); then
            echo "could not find sites/common_site_config.json with required keys";
            exit 1
          fi
        done;
        echo "sites/common_site_config.json found";
        bench new-site --mariadb-user-host-login-scope='%' --admin-password=${password} --db-root-username=root --db-root-password=${password} --install-app erpnext --set-default frontend;

  db:
    image: mariadb:10.6
    networks:
      - frappe_network
    healthcheck:
      test: mysqladmin ping -h localhost --password=${password}
      interval: 1s
      retries: 20
    deploy:
      restart_policy:
        condition: on-failure
    command:
      - --character-set-server=utf8mb4
      - --collation-server=utf8mb4_unicode_ci
      - --skip-character-set-client-handshake
      - --skip-innodb-read-only-compressed
    environment:
      MYSQL_ROOT_PASSWORD: ${password}
      MARIADB_ROOT_PASSWORD: ${password}
    volumes:
      - db-data:/var/lib/mysql

  frontend:
    image: frappe/erpnext:${version}
    networks:
      - frappe_network
    depends_on:
      - websocket
    deploy:
      restart_policy:
        condition: on-failure
    command:
      - nginx-entrypoint.sh
    environment:
      BACKEND: backend:8000
      FRAPPE_SITE_NAME_HEADER: frontend
      SOCKETIO: websocket:9000
      UPSTREAM_REAL_IP_ADDRESS: 127.0.0.1
      UPSTREAM_REAL_IP_HEADER: X-Forwarded-For
      UPSTREAM_REAL_IP_RECURSIVE: "off"
      PROXY_READ_TIMEOUT: 120
      CLIENT_MAX_BODY_SIZE: 50m
    volumes:
      - sites:/home/frappe/frappe-bench/sites
      - logs:/home/frappe/frappe-bench/logs
    ports:
      - "${port}:8080"

  queue-long:
    image: frappe/erpnext:${version}
    networks:
      - frappe_network
    deploy:
      restart_policy:
        condition: on-failure
    command:
      - bench
      - worker
      - --queue
      - long,default,short
    volumes:
      - sites:/home/frappe/frappe-bench/sites
      - logs:/home/frappe/frappe-bench/logs
    environment:
      FRAPPE_REDIS_CACHE: redis://redis-cache:6379
      FRAPPE_REDIS_QUEUE: redis://redis-queue:6379

  queue-short:
    image: frappe/erpnext:${version}
    networks:
      - frappe_network
    deploy:
      restart_policy:
        condition: on-failure
    command:
      - bench
      - worker
      - --queue
      - short,default
    volumes:
      - sites:/home/frappe/frappe-bench/sites
      - logs:/home/frappe/frappe-bench/logs
    environment:
      FRAPPE_REDIS_CACHE: redis://redis-cache:6379
      FRAPPE_REDIS_QUEUE: redis://redis-queue:6379

  redis-queue:
    image: redis:6.2-alpine
    networks:
      - frappe_network
    deploy:
      restart_policy:
        condition: on-failure
    volumes:
      - redis-queue-data:/data

  redis-cache:
    image: redis:6.2-alpine
    networks:
      - frappe_network
    deploy:
      restart_policy:
        condition: on-failure

  scheduler:
    image: frappe/erpnext:${version}
    networks:
      - frappe_network
    deploy:
      restart_policy:
        condition: on-failure
    command:
      - bench
      - schedule
    volumes:
      - sites:/home/frappe/frappe-bench/sites
      - logs:/home/frappe/frappe-bench/logs

  websocket:
    image: frappe/erpnext:${version}
    networks:
      - frappe_network
    deploy:
      restart_policy:
        condition: on-failure
    command:
      - node
      - /home/frappe/frappe-bench/apps/frappe/socketio.js
    environment:
      FRAPPE_REDIS_CACHE: redis://redis-cache:6379
      FRAPPE_REDIS_QUEUE: redis://redis-queue:6379
    volumes:
      - sites:/home/frappe/frappe-bench/sites
      - logs:/home/frappe/frappe-bench/logs

volumes:
  db-data:
  redis-queue-data:
  sites:
  logs:

networks:
  frappe_network:
    driver: bridge
YAML

    log_info "docker-compose.yml 已生成"
}

# ---------- 安装 ----------
do_install() {
    local port="$DEFAULT_PORT"
    local password="$DEFAULT_PASSWORD"
    local version="$DEFAULT_VERSION"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--port)     port="$2"; shift 2;;
            -P|--password) password="$2"; shift 2;;
            -v|--version)  version="$2"; shift 2;;
            *) log_error "未知参数: $1"; exit 1;;
        esac
    done

    check_docker

    # 自动检测可用端口
    port=$(find_available_port "$port")
    log_info "使用端口: $port"

    # 生成 compose 文件
    generate_compose "$port" "$password" "$version"

    # 拉取镜像
    log_info "正在拉取镜像 (ERPNext $version)..."
    compose_cmd pull

    # 启动基础服务
    log_info "正在启动基础服务 (db, redis, backend, frontend...)..."
    compose_cmd up -d backend db redis-cache redis-queue frontend websocket queue-long queue-short scheduler

    # 等待 DB 就绪
    log_info "等待数据库就绪..."
    local retries=0
    until compose_cmd exec -T db mysqladmin ping -h localhost --password="$password" --silent 2>/dev/null; do
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
    echo -e "  密码:      ${GREEN}${password}${NC}"
    echo -e "  版本:      ${GREEN}${version}${NC}"
    echo -e "${CYAN}====================================================${NC}"
    echo -e "  管理命令:"
    echo -e "    查看状态:  ${YELLOW}./deploy.sh status${NC}"
    echo -e "    查看日志:  ${YELLOW}./deploy.sh logs [service]${NC}"
    echo -e "    卸载清理:  ${YELLOW}./deploy.sh uninstall${NC}"
    echo -e "${CYAN}====================================================${NC}"
    echo ""
}

# ---------- 卸载 ----------
do_uninstall() {
    check_docker

    if [ ! -f "$COMPOSE_FILE" ]; then
        log_error "未找到 $COMPOSE_FILE，没有可卸载的部署"
        exit 1
    fi

    echo -e "${YELLOW}即将执行以下操作:${NC}"
    echo "  1. 停止并删除所有 ERPNext 容器"
    echo "  2. 删除所有数据卷 (数据库、站点数据等)"
    echo "  3. 删除 Docker 网络"
    echo ""
    read -rp "$(echo -e "${RED}确认卸载? 所有数据将被删除且不可恢复! [y/N]: ${NC}")" confirm

    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_info "已取消卸载"
        exit 0
    fi

    log_info "正在停止并删除容器..."
    compose_cmd down -v --remove-orphans

    log_info "正在清理未使用的镜像..."
    read -rp "$(echo -e "${YELLOW}是否同时删除 ERPNext 相关镜像以释放磁盘空间? [y/N]: ${NC}")" rm_images
    if [[ "$rm_images" == "y" || "$rm_images" == "Y" ]]; then
        compose_cmd down --rmi all -v --remove-orphans 2>/dev/null || true
        log_info "镜像已清理"
    fi

    echo ""
    echo -e "${GREEN}ERPNext 已完全卸载${NC}"
}

# ---------- 状态 ----------
do_status() {
    check_docker
    if [ ! -f "$COMPOSE_FILE" ]; then
        log_error "未找到部署，请先运行 ./deploy.sh install"
        exit 1
    fi
    compose_cmd ps
}

# ---------- 日志 ----------
do_logs() {
    check_docker
    if [ ! -f "$COMPOSE_FILE" ]; then
        log_error "未找到部署，请先运行 ./deploy.sh install"
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
    echo "  install      部署 ERPNext"
    echo "  uninstall    卸载并清理所有数据"
    echo "  status       查看服务状态"
    echo "  logs         查看服务日志"
    echo ""
    echo "install 选项:"
    echo "  -p, --port PORT        指定访问端口 (默认: $DEFAULT_PORT, 冲突时自动递增)"
    echo "  -P, --password PASS    管理员密码 (默认: $DEFAULT_PASSWORD)"
    echo "  -v, --version VER      ERPNext 版本 (默认: $DEFAULT_VERSION)"
    echo ""
    echo "示例:"
    echo "  $0 install                          # 使用默认配置部署"
    echo "  $0 install -p 9090 -P mypass123     # 指定端口和密码"
    echo "  $0 uninstall                        # 卸载并清理"
    echo "  $0 logs frontend                    # 查看前端日志"
}

# ---------- 入口 ----------
case "${1:-}" in
    install)   shift; do_install "$@";;
    uninstall) do_uninstall;;
    status)    do_status;;
    logs)      shift; do_logs "$@";;
    -h|--help|help) show_help;;
    *)
        show_help
        exit 1
        ;;
esac
