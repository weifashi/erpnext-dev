SHELL := /bin/bash
.ONESHELL:
.SHELLFLAGS := -euo pipefail -c
.PHONY: build rebuild install update uninstall backup restore status logs clean-cache help

# ============================================================
#  ERPNext Docker Compose 一键部署
#  用法: make <命令> [参数]
# ============================================================

# ---------- 默认参数 ----------
PORT             ?= 8080
PASSWORD         ?=
FRAPPE_VERSION   ?= v15.73.0
PYTHON_VERSION   ?= 3.11.9
NODE_VERSION     ?= 18.20.2
IMAGE_NAME       ?= frappe/erpnext
IMAGE_TAG        ?= v15.70.0
PROJECT          ?= erpnext
FILE             ?=
NO_CACHE         ?=

# ---------- 内部变量 ----------
COMPOSE_FILE    := docker-compose.yml
ENV_FILE        := .env
APPS_JSON       := apps.json
CONTAINERFILE   := frappe_docker/images/custom/Containerfile
SITE_NAME       := frontend
BACKUP_DIR      := backups
CONTAINER_SITE  := /home/frappe/frappe-bench/sites/$(SITE_NAME)/private/backups

# ---------- 颜色 ----------
RED    := \033[0;31m
GREEN  := \033[0;32m
YELLOW := \033[1;33m
CYAN   := \033[0;36m
NC     := \033[0m

# ---------- compose 命令 ----------
define compose
	docker compose -p $(PROJECT) -f $(COMPOSE_FILE) --env-file $(ENV_FILE)
endef

# ============================================================
help: ## 显示帮助信息
	@echo ""
	@echo "ERPNext Docker 一键部署"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36mmake %-12s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "参数示例:"
	@echo "  make install PORT=9090 PASSWORD=mypass123"
	@echo "  make restore FILE=backups/xxx-database.sql.gz"
	@echo ""

# ============================================================
build: ## 构建自定义镜像 (含 ERPNext + HRMS)
	@# 加载已有 .env
	if [ -f "$(ENV_FILE)" ]; then
		set -a; source "$(ENV_FILE)"; set +a
	fi
	frappe_ver="$${FRAPPE_VERSION:-$(FRAPPE_VERSION)}"
	img_name="$${ERPNEXT_IMAGE:-$(IMAGE_NAME)}"
	img_tag="$${ERPNEXT_IMAGE_TAG:-$(IMAGE_TAG)}"
	py_ver="$${PYTHON_VERSION:-$(PYTHON_VERSION)}"
	node_ver="$${NODE_VERSION:-$(NODE_VERSION)}"

	# 检查必要文件
	if [ ! -f "$(APPS_JSON)" ]; then
		echo -e "$(RED)[ERROR]$(NC) 未找到 $(APPS_JSON)，请先创建" >&2
		exit 1
	fi
	if [ ! -f "$(CONTAINERFILE)" ]; then
		echo -e "$(GREEN)[INFO]$(NC)  未找到 frappe_docker，正在克隆..." >&2
		git clone --depth 1 https://github.com/frappe/frappe_docker.git frappe_docker
		echo -e "$(GREEN)[INFO]$(NC)  frappe_docker 克隆完成" >&2
	fi

	# 修补 Containerfile: 确保 setuptools 可用 (pkg_resources)
	if ! grep -q 'pip3 install setuptools' "$(CONTAINERFILE)"; then
		sed -i 's|pip3 install frappe-bench|pip3 install setuptools frappe-bench|' "$(CONTAINERFILE)"
		echo -e "$(GREEN)[INFO]$(NC)  已修补 Containerfile (添加 setuptools)" >&2
	fi

	# 生成 .env（如果不存在）
	if [ ! -f "$(ENV_FILE)" ]; then
		$(MAKE) _generate-env \
			_PORT=$(PORT) _PASSWORD="$(PASSWORD)" _DB_PASSWORD="$(PASSWORD)" \
			_FRAPPE_VERSION="$$frappe_ver" _IMAGE_NAME="$$img_name" _IMAGE_TAG="$$img_tag" \
			_PYTHON_VERSION="$$py_ver" _NODE_VERSION="$$node_ver"
	fi

	apps_json_base64=$$(base64 -w 0 "$(APPS_JSON)")

	echo -e "$(GREEN)[INFO]$(NC)  开始构建自定义镜像 $${img_name}:$${img_tag}" >&2
	echo -e "$(GREEN)[INFO]$(NC)    Frappe: $${frappe_ver}" >&2
	echo -e "$(GREEN)[INFO]$(NC)    Python: $${py_ver}" >&2
	echo -e "$(GREEN)[INFO]$(NC)    Node:   $${node_ver}" >&2
	echo -e "$(GREEN)[INFO]$(NC)    Apps:   $$(jq -r '.[].url' $(APPS_JSON) | xargs -I{} basename {})" >&2
	echo ""

	docker build \
		$${NO_CACHE:+--no-cache} \
		--build-arg APPS_JSON_BASE64="$$apps_json_base64" \
		--build-arg FRAPPE_BRANCH="$$frappe_ver" \
		--build-arg PYTHON_VERSION="$$py_ver" \
		--build-arg NODE_VERSION="$$node_ver" \
		-t "$${img_name}:$${img_tag}" \
		-f "$(CONTAINERFILE)" \
		frappe_docker

	echo -e "$(GREEN)[INFO]$(NC)  镜像构建完成: $${img_name}:$${img_tag}" >&2

# ============================================================
rebuild: ## 强制重建镜像 (删除旧镜像 + 重新构建)
	@if [ -f "$(ENV_FILE)" ]; then
		set -a; source "$(ENV_FILE)"; set +a
	fi
	img_name="$${ERPNEXT_IMAGE:-$(IMAGE_NAME)}"
	img_tag="$${ERPNEXT_IMAGE_TAG:-$(IMAGE_TAG)}"
	echo -e "$(GREEN)[INFO]$(NC)  删除旧镜像 $${img_name}:$${img_tag}..." >&2
	docker rmi "$${img_name}:$${img_tag}" 2>/dev/null || true
	rm -rf frappe_docker
	$(MAKE) build NO_CACHE=1

# ============================================================
install: ## 构建镜像并部署 ERPNext (自动生成 .env)
	@# 加载已有 .env 作为默认值
	port="$(PORT)"
	admin_pw="$(PASSWORD)"
	db_pw="$(PASSWORD)"
	frappe_ver="$(FRAPPE_VERSION)"
	img_name="$(IMAGE_NAME)"
	img_tag="$(IMAGE_TAG)"
	py_ver="$(PYTHON_VERSION)"
	node_ver="$(NODE_VERSION)"

	if [ -f "$(ENV_FILE)" ]; then
		set -a; source "$(ENV_FILE)"; set +a
		port="$${ERPNEXT_PORT:-$$port}"
		admin_pw="$${ADMIN_PASSWORD:-$$admin_pw}"
		db_pw="$${DB_PASSWORD:-$$db_pw}"
		frappe_ver="$${FRAPPE_VERSION:-$$frappe_ver}"
		img_name="$${ERPNEXT_IMAGE:-$$img_name}"
		img_tag="$${ERPNEXT_IMAGE_TAG:-$$img_tag}"
		py_ver="$${PYTHON_VERSION:-$$py_ver}"
		node_ver="$${NODE_VERSION:-$$node_ver}"
	fi

	# 检查镜像，不存在则拉取或构建
	if ! docker image inspect "$${img_name}:$${img_tag}" &>/dev/null; then
		if echo "$${img_name}" | grep -q '/'; then
			echo -e "$(GREEN)[INFO]$(NC)  正在拉取官方镜像 $${img_name}:$${img_tag}..." >&2
			docker pull "$${img_name}:$${img_tag}"
		else
			echo -e "$(YELLOW)[WARN]$(NC)  未找到镜像 $${img_name}:$${img_tag}，先执行构建..." >&2
			$(MAKE) build
		fi
	fi

	# 清理所有残留资源（容器、数据卷、网络）
	existing=$$(docker ps -aq --filter "name=$(PROJECT)-" 2>/dev/null)
	if [ -n "$$existing" ]; then
		echo -e "$(YELLOW)[WARN]$(NC)  检测到残留容器，正在清除..." >&2
		docker rm -f $$existing 2>/dev/null || true
	fi
	for vol in $$(docker volume ls -q --filter "name=$(PROJECT)_" 2>/dev/null); do
		docker volume rm "$$vol" 2>/dev/null || true
	done
	docker network rm $(PROJECT)_frappe_network 2>/dev/null || true

	# 自动检测可用端口
	while ss -tlnp 2>/dev/null | grep -q ":$${port} " || \
		  netstat -tlnp 2>/dev/null | grep -q ":$${port} "; do
		echo -e "$(YELLOW)[WARN]$(NC)  端口 $$port 已被占用，尝试 $$((port+1))..." >&2
		port=$$((port+1))
	done
	echo -e "$(GREEN)[INFO]$(NC)  使用端口: $$port" >&2

	# 生成 .env
	$(MAKE) _generate-env \
		_PORT="$$port" _PASSWORD="$$admin_pw" _DB_PASSWORD="$$db_pw" \
		_FRAPPE_VERSION="$$frappe_ver" _IMAGE_NAME="$$img_name" _IMAGE_TAG="$$img_tag" \
		_PYTHON_VERSION="$$py_ver" _NODE_VERSION="$$node_ver"
	# 重新加载 .env（可能包含新生成的随机密码）
	set -a; source "$(ENV_FILE)"; set +a
	admin_pw="$$ADMIN_PASSWORD"
	db_pw="$$DB_PASSWORD"

	# 启动基础服务
	echo -e "$(GREEN)[INFO]$(NC)  正在启动基础服务 (db, redis, backend, frontend...)..." >&2
	$(compose) up -d backend db redis-cache redis-queue frontend websocket queue-long queue-short scheduler

	# 等待 DB 就绪
	echo -e "$(GREEN)[INFO]$(NC)  等待数据库就绪..." >&2
	retries=0
	until $(compose) exec -T db mysqladmin ping -h localhost --password="$$db_pw" --silent 2>/dev/null; do
		retries=$$((retries+1))
		if [ $$retries -ge 60 ]; then
			echo -e "$(RED)[ERROR]$(NC) 数据库启动超时" >&2
			exit 1
		fi
		sleep 2
	done
	echo -e "$(GREEN)[INFO]$(NC)  数据库已就绪" >&2

	# 运行 configurator
	echo -e "$(GREEN)[INFO]$(NC)  正在初始化配置..." >&2
	$(compose) up -d configurator
	$(compose) wait configurator 2>/dev/null || sleep 10

	# 创建站点
	echo -e "$(GREEN)[INFO]$(NC)  正在创建 ERPNext 站点 (这可能需要 3-5 分钟)..." >&2
	$(compose) up -d create-site

	# 等待站点创建完成
	echo -e "$(GREEN)[INFO]$(NC)  等待站点创建完成..." >&2
	timeout=600
	elapsed=0
	while [ $$elapsed -lt $$timeout ]; do
		cstatus=$$(docker inspect --format='{{.State.Status}}' "$(PROJECT)-create-site-1" 2>/dev/null || echo "running")
		if [ "$$cstatus" = "exited" ]; then
			exit_code=$$(docker inspect --format='{{.State.ExitCode}}' "$(PROJECT)-create-site-1" 2>/dev/null || echo "1")
			if [ "$$exit_code" = "0" ]; then
				echo -e "$(GREEN)[INFO]$(NC)  站点创建成功!" >&2
				break
			else
				echo -e "$(RED)[ERROR]$(NC) 站点创建失败，查看日志:" >&2
				$(compose) logs create-site | tail -20
				exit 1
			fi
		fi
		sleep 5
		elapsed=$$((elapsed+5))
		if (( elapsed % 30 == 0 )); then
			echo -e "$(GREEN)[INFO]$(NC)    已等待 $${elapsed}s / $${timeout}s ..." >&2
		fi
	done

	if [ $$elapsed -ge $$timeout ]; then
		echo -e "$(RED)[ERROR]$(NC) 站点创建超时 ($${timeout}s)" >&2
		$(compose) logs create-site | tail -20
		exit 1
	fi

	# 输出结果
	host_ip=$$(hostname -I 2>/dev/null | awk '{print $$1}' || echo "localhost")
	echo ""
	echo -e "$(CYAN)====================================================$(NC)"
	echo -e "$(CYAN)  ERPNext 部署完成!$(NC)"
	echo -e "$(CYAN)====================================================$(NC)"
	echo -e "  访问地址:  $(GREEN)http://$${host_ip}:$${port}$(NC)"
	echo -e "  用户名:    $(GREEN)Administrator$(NC)"
	echo -e "  密码:      $(GREEN)$${admin_pw}$(NC)"
	echo -e "  Frappe:    $(GREEN)$${frappe_ver}$(NC)"
	echo -e "  Apps:      $(GREEN)$$(jq -r '.[] | "\(.url | split("/") | last):\(.branch)"' $(APPS_JSON) 2>/dev/null | tr '\n' ' ')$(NC)"
	echo -e "$(CYAN)====================================================$(NC)"
	echo -e "  管理命令:"
	echo -e "    查看状态:  $(YELLOW)make status$(NC)"
	echo -e "    查看日志:  $(YELLOW)make logs$(NC)"
	echo -e "    更新服务:  $(YELLOW)make update$(NC)"
	echo -e "    备份站点:  $(YELLOW)make backup$(NC)"
	echo -e "    恢复备份:  $(YELLOW)make restore$(NC)"
	echo -e "    卸载清理:  $(YELLOW)make uninstall$(NC)"
	echo -e "$(CYAN)====================================================$(NC)"
	echo ""

# ============================================================
update: ## 更新: 重新构建镜像 + 重启服务 + 数据库迁移
	@if [ ! -f "$(ENV_FILE)" ]; then
		echo -e "$(RED)[ERROR]$(NC) 未找到 .env 文件，请先运行 make install" >&2
		exit 1
	fi
	echo -e "$(GREEN)[INFO]$(NC)  开始更新 ERPNext..." >&2

	echo -e "$(GREEN)[INFO]$(NC)  步骤 1/3: 重新构建镜像..." >&2
	$(MAKE) build

	echo -e "$(GREEN)[INFO]$(NC)  步骤 2/3: 重启服务..." >&2
	$(compose) up -d backend frontend websocket queue-long queue-short scheduler

	echo -e "$(GREEN)[INFO]$(NC)  步骤 3/3: 执行数据库迁移..." >&2
	$(compose) exec -T backend bench --site $(SITE_NAME) migrate

	echo -e "$(GREEN)[INFO]$(NC)  更新完成!" >&2
	$(compose) ps

# ============================================================
uninstall: ## 卸载并清理所有数据
	@if [ ! -f "$(ENV_FILE)" ]; then
		echo -e "$(RED)[ERROR]$(NC) 未找到 .env 文件，没有可卸载的部署" >&2
		exit 1
	fi
	set -a; source "$(ENV_FILE)"; set +a
	img_name="$${ERPNEXT_IMAGE:-$(IMAGE_NAME)}"
	img_tag="$${ERPNEXT_IMAGE_TAG:-$(IMAGE_TAG)}"

	echo -e "$(YELLOW)即将执行以下操作:$(NC)"
	echo "  1. 停止并删除所有 ERPNext 容器"
	echo "  2. 删除所有数据卷 (数据库、站点数据等)"
	echo "  3. 删除 Docker 网络"
	echo "  4. 删除 .env 配置文件"
	echo ""
	read -rp "$$( echo -e '$(RED)确认卸载? 所有数据将被删除且不可恢复! [y/N]: $(NC)' )" confirm
	if [[ "$$confirm" != "y" && "$$confirm" != "Y" ]]; then
		echo -e "$(GREEN)[INFO]$(NC)  已取消卸载" >&2
		exit 0
	fi

	echo -e "$(GREEN)[INFO]$(NC)  正在停止并删除容器..." >&2
	$(compose) down -v --remove-orphans

	read -rp "$$( echo -e '$(YELLOW)是否同时删除自定义镜像 '"$$img_name"':'"$$img_tag"'? [y/N]: $(NC)' )" rm_images
	if [[ "$$rm_images" == "y" || "$$rm_images" == "Y" ]]; then
		docker rmi "$${img_name}:$${img_tag}" 2>/dev/null || true
		echo -e "$(GREEN)[INFO]$(NC)  镜像已清理" >&2
	fi

	rm -f "$(ENV_FILE)"
	echo -e "$(GREEN)[INFO]$(NC)  .env 文件已删除" >&2
	echo ""
	echo -e "$(GREEN)ERPNext 已完全卸载$(NC)"

# ============================================================
backup: ## 备份站点 (数据库 + 文件)
	@if [ ! -f "$(ENV_FILE)" ]; then
		echo -e "$(RED)[ERROR]$(NC) 未找到 .env 文件，请先运行 make install" >&2
		exit 1
	fi
	mkdir -p "$(BACKUP_DIR)"

	echo -e "$(GREEN)[INFO]$(NC)  正在备份 ERPNext 站点..." >&2
	$(compose) exec -T backend bench --site $(SITE_NAME) backup --with-files

	# 获取最新备份文件名
	latest_db=$$($(compose) exec -T backend ls -t "$(CONTAINER_SITE)" | grep '\.sql\.gz$$' | head -1 | tr -d '\r')
	if [ -z "$$latest_db" ]; then
		echo -e "$(RED)[ERROR]$(NC) 未找到备份文件" >&2
		exit 1
	fi

	prefix="$${latest_db%-$(SITE_NAME)-database.sql.gz}"
	container="$(PROJECT)-backend-1"

	docker cp "$$container:$(CONTAINER_SITE)/$${prefix}-$(SITE_NAME)-database.sql.gz" "$(BACKUP_DIR)/"
	docker cp "$$container:$(CONTAINER_SITE)/$${prefix}-$(SITE_NAME)-files.tar" "$(BACKUP_DIR)/" 2>/dev/null || true
	docker cp "$$container:$(CONTAINER_SITE)/$${prefix}-$(SITE_NAME)-private-files.tar" "$(BACKUP_DIR)/" 2>/dev/null || true
	docker cp "$$container:$(CONTAINER_SITE)/$${prefix}-$(SITE_NAME)-site_config_backup.json" "$(BACKUP_DIR)/" 2>/dev/null || true

	echo ""
	echo -e "$(GREEN)[INFO]$(NC)  备份完成! 文件保存在: $(BACKUP_DIR)/" >&2
	ls -lh "$(BACKUP_DIR)/$${prefix}"* 2>/dev/null
	echo ""

# ============================================================
restore: ## 恢复备份 (make restore FILE=backups/xxx.sql.gz)
	@if [ ! -f "$(ENV_FILE)" ]; then
		echo -e "$(RED)[ERROR]$(NC) 未找到 .env 文件，请先运行 make install" >&2
		exit 1
	fi

	backup_file="$(FILE)"

	# 如果没有指定文件，交互式选择
	if [ -z "$$backup_file" ]; then
		if [ ! -d "$(BACKUP_DIR)" ] || [ -z "$$(ls $(BACKUP_DIR)/*.sql.gz 2>/dev/null)" ]; then
			echo -e "$(RED)[ERROR]$(NC) 未找到备份文件，请指定: make restore FILE=<database.sql.gz>" >&2
			exit 1
		fi
		echo -e "$(CYAN)可用备份:$(NC)"
		i=1
		declare -a backup_list=()
		for f in $(BACKUP_DIR)/*-database.sql.gz; do
			backup_list+=("$$f")
			echo "  $$i) $$(basename "$$f")  ($$(du -h "$$f" | cut -f1))"
			i=$$((i+1))
		done
		echo ""
		read -rp "选择备份序号 [1]: " choice
		choice="$${choice:-1}"
		if ! [[ "$$choice" =~ ^[0-9]+$$ ]] || [ "$$choice" -lt 1 ] || [ "$$choice" -gt $${#backup_list[@]} ]; then
			echo -e "$(RED)[ERROR]$(NC) 无效的选择" >&2
			exit 1
		fi
		backup_file="$${backup_list[$$((choice-1))]}"
	fi

	# 验证文件
	if [ ! -f "$$backup_file" ]; then
		echo -e "$(RED)[ERROR]$(NC) 备份文件不存在: $$backup_file" >&2
		exit 1
	fi

	bdir="$$(dirname "$$backup_file")"
	bname="$$(basename "$$backup_file")"
	prefix="$${bname%-$(SITE_NAME)-database.sql.gz}"
	files_tar="$$bdir/$${prefix}-$(SITE_NAME)-files.tar"
	private_tar="$$bdir/$${prefix}-$(SITE_NAME)-private-files.tar"

	echo -e "$(YELLOW)即将恢复备份:$(NC)"
	echo "  数据库:   $$bname"
	[ -f "$$files_tar" ] && echo "  公共文件: $$(basename "$$files_tar")"
	[ -f "$$private_tar" ] && echo "  私有文件: $$(basename "$$private_tar")"
	echo ""
	read -rp "$$( echo -e '$(RED)确认恢复? 当前数据将被覆盖! [y/N]: $(NC)' )" confirm
	if [[ "$$confirm" != "y" && "$$confirm" != "Y" ]]; then
		echo -e "$(GREEN)[INFO]$(NC)  已取消恢复" >&2
		exit 0
	fi

	container="$(PROJECT)-backend-1"

	echo -e "$(GREEN)[INFO]$(NC)  正在复制备份文件到容器..." >&2
	$(compose) exec -T backend mkdir -p "$(CONTAINER_SITE)"
	docker cp "$$backup_file" "$$container:$(CONTAINER_SITE)/"
	[ -f "$$files_tar" ] && docker cp "$$files_tar" "$$container:$(CONTAINER_SITE)/"
	[ -f "$$private_tar" ] && docker cp "$$private_tar" "$$container:$(CONTAINER_SITE)/"

	# 构建恢复命令
	restore_cmd="bench --site $(SITE_NAME) restore $(CONTAINER_SITE)/$$bname"
	[ -f "$$files_tar" ] && restore_cmd="$$restore_cmd --with-public-files $(CONTAINER_SITE)/$$(basename "$$files_tar")"
	[ -f "$$private_tar" ] && restore_cmd="$$restore_cmd --with-private-files $(CONTAINER_SITE)/$$(basename "$$private_tar")"

	echo -e "$(GREEN)[INFO]$(NC)  正在恢复数据库..." >&2
	$(compose) exec -T backend $$restore_cmd

	# 恢复后自动修复环境
	echo -e "$(GREEN)[INFO]$(NC)  正在修复运行环境..." >&2
	$(compose) exec -T backend bash -c '\
		/home/frappe/frappe-bench/env/bin/pip install "setuptools<81" -q 2>/dev/null; \
		installed=$$(bench --site $(SITE_NAME) list-apps 2>/dev/null | tail -n +2 | tr -d "\r"); \
		for app in $$(ls apps/ 2>/dev/null); do \
			if [ "$$app" != "frappe" ] && ! echo "$$installed" | grep -q "$$app"; then \
				echo "  安装缺失的应用: $$app"; \
				bench --site $(SITE_NAME) install-app "$$app" 2>/dev/null || true; \
			fi; \
		done \
	'

	echo -e "$(GREEN)[INFO]$(NC)  正在执行数据库迁移..." >&2
	$(compose) exec -T backend bench --site $(SITE_NAME) migrate

	echo -e "$(GREEN)[INFO]$(NC)  正在清除缓存..." >&2
	$(compose) exec -T backend bench --site $(SITE_NAME) clear-cache

	echo ""
	echo -e "$(GREEN)[INFO]$(NC)  备份恢复完成!" >&2

# ============================================================
status: ## 查看服务状态
	@if [ ! -f "$(ENV_FILE)" ]; then
		echo -e "$(RED)[ERROR]$(NC) 未找到 .env 文件，请先运行 make install" >&2
		exit 1
	fi
	set -a; source "$(ENV_FILE)"; set +a
	echo -e "$(CYAN)镜像:$(NC) $${ERPNEXT_IMAGE:-$(IMAGE_NAME)}:$${ERPNEXT_IMAGE_TAG:-$(IMAGE_TAG)}"
	echo -e "$(CYAN)Frappe:$(NC) $${FRAPPE_VERSION:-$(FRAPPE_VERSION)}"
	echo -e "$(CYAN)端口:$(NC) $${ERPNEXT_PORT:-$(PORT)}"
	echo ""
	$(compose) ps

# ============================================================
logs: ## 查看所有服务日志 (make logs 或 make logs SVC=frontend)
	@if [ ! -f "$(ENV_FILE)" ]; then
		echo -e "$(RED)[ERROR]$(NC) 未找到 .env 文件，请先运行 make install" >&2
		exit 1
	fi
	$(compose) logs -f --tail=100 $(SVC)

# ============================================================
clean-cache: ## 清理 Docker 构建缓存和悬空镜像
	@echo -e "$(CYAN)将要清理以下内容:$(NC)"
	@echo "  1. Docker 构建缓存"
	@echo "  2. 悬空镜像 (dangling images)"
	@echo ""
	@read -rp "$$( echo -e '$(YELLOW)确认清理? [y/N]: $(NC)' )" confirm; \
	if [[ "$$confirm" != "y" && "$$confirm" != "Y" ]]; then \
		echo -e "$(GREEN)[INFO]$(NC)  已取消" >&2; \
		exit 0; \
	fi; \
	echo -e "$(GREEN)[INFO]$(NC)  正在清理构建缓存..." >&2; \
	docker builder prune -af; \
	echo -e "$(GREEN)[INFO]$(NC)  正在清理悬空镜像..." >&2; \
	docker image prune -f; \
	echo ""; \
	echo -e "$(GREEN)[INFO]$(NC)  清理完成! 当前磁盘占用:" >&2; \
	docker system df

# ============================================================
# 内部目标: 生成 .env 文件
# ============================================================
_generate-env:
	@# 生成随机密码（如果未指定）
	admin_pw="$(_PASSWORD)"
	db_pw="$(_DB_PASSWORD)"
	if [ -z "$$admin_pw" ]; then
		admin_pw=$$(openssl rand -base64 12 | tr -dc 'A-Za-z0-9' | head -c 16)
		echo -e "$(GREEN)[INFO]$(NC)  已生成随机管理员密码" >&2
	fi
	if [ -z "$$db_pw" ]; then
		db_pw=$$(openssl rand -base64 12 | tr -dc 'A-Za-z0-9' | head -c 16)
		echo -e "$(GREEN)[INFO]$(NC)  已生成随机数据库密码" >&2
	fi
	cat > "$(ENV_FILE)" <<-ENVEOF
	# ERPNext 部署配置 (自动生成)

	# 访问端口
	ERPNEXT_PORT=$(_PORT)

	# 管理员密码 (ERPNext 后台登录)
	ADMIN_PASSWORD=$$admin_pw

	# 数据库 root 密码
	DB_PASSWORD=$$db_pw

	# Frappe 框架版本
	FRAPPE_VERSION=$(_FRAPPE_VERSION)

	# 自定义镜像名称和标签
	ERPNEXT_IMAGE=$(_IMAGE_NAME)
	ERPNEXT_IMAGE_TAG=$(_IMAGE_TAG)

	# 构建参数
	PYTHON_VERSION=$(_PYTHON_VERSION)
	NODE_VERSION=$(_NODE_VERSION)
	ENVEOF
	echo -e "$(GREEN)[INFO]$(NC)  .env 文件已生成" >&2
