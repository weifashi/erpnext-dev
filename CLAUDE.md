# ERPNext Docker 一键部署

## 项目概述
基于 Docker Compose 的 ERPNext 生产环境一键部署方案。

## 版本信息
- ERPNext: v15.95.2（与生产线一致；tag 指向 commit `621558a30c450fcdc7630c34225ff67890c1981d`）
- Frappe: v15.98.1（与官方 `frappe/erpnext:v15.95.2` 镜像内版本一致，供 `make build` 使用）
- HRMS: v15.58.4 (仅自定义构建模式)
- 默认镜像: `frappe/erpnext:v15.95.2` (官方预构建)

## 项目结构
```
├── Makefile              # 所有部署操作入口
├── docker-compose.yml    # 服务编排 (backend, frontend, db, redis, workers...)
├── apps.json             # 自定义构建时的 app 列表
├── .env                  # 运行时配置 (自动生成，不提交)
├── backups/              # 站点备份 (不提交)
└── frappe_docker/        # 上游构建文件 (克隆，不提交)
```

## 常用命令
```bash
make install              # 一键部署 (自动拉取镜像、生成密码、创建站点)
make install PORT=9090    # 指定端口部署
make up / make down       # 启动/停止服务
make status               # 查看状态
make logs                 # 查看日志
make backup               # 备份站点
make restore              # 恢复备份
make update               # 更新镜像+迁移
make uninstall            # 完全卸载
make clean-cache          # 清理 Docker 构建缓存
make add-site SITE=x.com  # 添加多站点
make create-site          # 重建站点
make build                # 自定义构建镜像 (含 HRMS)
```

## 开发约定
- `.env` 文件不提交到 git，由 `make install` 自动生成随机密码
- 所有 Makefile log 函数输出到 stderr (`>&2`)，避免被 `$()` 捕获污染变量
- Docker Compose 项目名: `erpnext`
- 默认站点名: `frontend`
- `setuptools<81` 用于兼容 `pkg_resources` (ERPNext v15 依赖)

## 两种部署模式
1. **官方镜像** (默认): `frappe/erpnext:v15.95.2`，快速拉取部署
2. **自定义构建**: `make build`，支持 HRMS 等额外 app，需要从源码构建

## 注意事项
- 修改 Makefile 时保持 `.ONESHELL` 和 `set -euo pipefail`
- shell 变量在 Makefile 中需用 `$$` 转义
- 交互式确认 (`read -rp`) 放在危险操作前
