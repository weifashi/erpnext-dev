.PHONY: install uninstall status logs help

# 默认参数 (也可通过 .env 文件配置)
PORT     ?= 8080
PASSWORD ?= admin
VERSION  ?= v16.8.3

help: ## 显示帮助信息
	@echo ""
	@echo "ERPNext Docker 一键部署"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36mmake %-12s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "自定义参数示例:"
	@echo "  make install PORT=9090 PASSWORD=mypass123 VERSION=v15.47.4"
	@echo ""

install: ## 部署 ERPNext (自动生成 .env)
	@./deploy.sh install -p $(PORT) -P $(PASSWORD) -v $(VERSION)

uninstall: ## 卸载并清理所有数据
	@./deploy.sh uninstall

status: ## 查看服务状态
	@./deploy.sh status

logs: ## 查看所有服务日志
	@./deploy.sh logs

logs-%: ## 查看指定服务日志 (如: make logs-frontend)
	@./deploy.sh logs $*
