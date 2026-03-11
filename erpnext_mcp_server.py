#!/usr/bin/env python3
"""ERPNext MCP Server - API操作、监控、站点管理工具集"""

import json
import logging
import os
import subprocess
import sys
from typing import Optional

import httpx
from mcp.server.fastmcp import FastMCP

# ---------------------------------------------------------------------------
# Logging (stderr only, never stdout - required for stdio transport)
# ---------------------------------------------------------------------------
logging.basicConfig(stream=sys.stderr, level=logging.INFO,
                    format="[erpnext-mcp] %(levelname)s %(message)s")
log = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
PROJECT_DIR = os.path.dirname(os.path.abspath(__file__))
COMPOSE_PROJECT = "erpnext"
COMPOSE_FILE = os.path.join(PROJECT_DIR, "docker-compose.yml")
ENV_FILE = os.path.join(PROJECT_DIR, ".env")
DEFAULT_SITE = "frontend"

ALLOWED_BENCH_COMMANDS = {
    "migrate", "clear-cache", "clear-website-cache", "build",
    "set-config", "version", "doctor", "show-config",
    "list-apps", "disable-scheduler", "enable-scheduler",
    "set-maintenance-mode", "export-fixtures", "import-fixtures",
}

VALID_SERVICES = {
    "backend", "frontend", "db", "redis-cache", "redis-queue",
    "scheduler", "queue-long", "queue-short", "websocket",
}


def load_env() -> dict:
    """Parse the .env file into a dict."""
    env = {}
    if not os.path.exists(ENV_FILE):
        return env
    with open(ENV_FILE) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" in line:
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip()
    return env


_env = load_env()
ERPNEXT_PORT = _env.get("ERPNEXT_PORT", "8080")
ADMIN_PASSWORD = _env.get("ADMIN_PASSWORD", "admin")
DB_PASSWORD = _env.get("DB_PASSWORD", "admin")
BASE_URL = f"http://localhost:{ERPNEXT_PORT}"

# ---------------------------------------------------------------------------
# Frappe HTTP Client
# ---------------------------------------------------------------------------

class FrappeClient:
    """Simple sync HTTP client for Frappe REST API with session auth."""

    def __init__(self, base_url: str, site: str = DEFAULT_SITE):
        self.base_url = base_url
        self.site = site
        self._client = httpx.Client(base_url=base_url, timeout=30,
                                     headers={"Host": site})
        self._authenticated = False

    def _login(self):
        r = self._client.post("/api/method/login",
                              data={"usr": "Administrator", "pwd": ADMIN_PASSWORD})
        r.raise_for_status()
        self._authenticated = True

    def _ensure_auth(self):
        if not self._authenticated:
            self._login()

    def _request(self, method: str, path: str, **kwargs):
        self._ensure_auth()
        r = self._client.request(method, path, **kwargs)
        if r.status_code in (401, 403):
            self._authenticated = False
            self._login()
            r = self._client.request(method, path, **kwargs)
        r.raise_for_status()
        return r.json()

    def get(self, path: str, params: Optional[dict] = None):
        return self._request("GET", path, params=params)

    def post(self, path: str, data: Optional[dict] = None, json_data: Optional[dict] = None):
        return self._request("POST", path, data=data, json=json_data)

    def put(self, path: str, json_data: Optional[dict] = None):
        return self._request("PUT", path, json=json_data)

    def delete(self, path: str):
        return self._request("DELETE", path)


_client: Optional[FrappeClient] = None


def get_client() -> FrappeClient:
    global _client
    if _client is None:
        _client = FrappeClient(BASE_URL)
    return _client


# ---------------------------------------------------------------------------
# Docker helpers
# ---------------------------------------------------------------------------

def run_compose(*args: str, timeout: int = 120) -> str:
    """Run a docker compose command and return combined output."""
    cmd = [
        "docker", "compose", "-p", COMPOSE_PROJECT,
        "-f", COMPOSE_FILE, "--env-file", ENV_FILE,
        *args,
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    output = result.stdout
    if result.stderr:
        output += "\n" + result.stderr if output else result.stderr
    return output.strip()


def bench_exec(site: str, *bench_args: str, timeout: int = 120) -> str:
    """Run `bench --site {site} {args}` inside the backend container."""
    return run_compose(
        "exec", "-T", "backend",
        "bench", "--site", site, *bench_args,
        timeout=timeout,
    )


# ---------------------------------------------------------------------------
# MCP Server
# ---------------------------------------------------------------------------
mcp = FastMCP("erpnext")

# ========================== API Operations ==========================

@mcp.tool()
def get_document(doctype: str, name: str, fields: Optional[str] = None) -> str:
    """获取单个文档。fields 为逗号分隔的字段列表，如 'name,status,owner'"""
    try:
        params = {}
        if fields:
            params["fields"] = json.dumps([f.strip() for f in fields.split(",")])
        data = get_client().get(f"/api/resource/{doctype}/{name}", params=params)
        return json.dumps(data, ensure_ascii=False, indent=2)
    except Exception as e:
        return f"Error: {e}"


@mcp.tool()
def list_documents(
    doctype: str,
    filters: Optional[str] = None,
    fields: Optional[str] = None,
    order_by: Optional[str] = None,
    limit: int = 20,
    start: int = 0,
) -> str:
    """列出文档。filters 为 JSON 数组如 '[["status","=","Active"]]'，fields 为逗号分隔"""
    try:
        params = {
            "limit_page_length": min(limit, 100),
            "limit_start": start,
        }
        if filters:
            params["filters"] = filters
        if fields:
            params["fields"] = json.dumps([f.strip() for f in fields.split(",")])
        if order_by:
            params["order_by"] = order_by
        data = get_client().get(f"/api/resource/{doctype}", params=params)
        return json.dumps(data, ensure_ascii=False, indent=2)
    except Exception as e:
        return f"Error: {e}"


@mcp.tool()
def create_document(doctype: str, data: str) -> str:
    """创建文档。data 为 JSON 对象，如 '{"customer_name": "Test"}'"""
    try:
        payload = json.loads(data)
        result = get_client().post(f"/api/resource/{doctype}", json_data=payload)
        return json.dumps(result, ensure_ascii=False, indent=2)
    except json.JSONDecodeError:
        return "Error: data 参数不是有效的 JSON"
    except Exception as e:
        return f"Error: {e}"


@mcp.tool()
def update_document(doctype: str, name: str, data: str) -> str:
    """更新文档。data 为要更新的字段 JSON，如 '{"status": "Closed"}'"""
    try:
        payload = json.loads(data)
        result = get_client().put(f"/api/resource/{doctype}/{name}", json_data=payload)
        return json.dumps(result, ensure_ascii=False, indent=2)
    except json.JSONDecodeError:
        return "Error: data 参数不是有效的 JSON"
    except Exception as e:
        return f"Error: {e}"


@mcp.tool()
def delete_document(doctype: str, name: str) -> str:
    """删除文档"""
    try:
        result = get_client().delete(f"/api/resource/{doctype}/{name}")
        return json.dumps(result, ensure_ascii=False, indent=2)
    except Exception as e:
        return f"Error: {e}"


@mcp.tool()
def call_method(method: str, args: Optional[str] = None) -> str:
    """调用 Frappe 白名单方法。args 为 JSON 对象参数"""
    try:
        payload = json.loads(args) if args else {}
        result = get_client().post(f"/api/method/{method}", json_data=payload)
        return json.dumps(result, ensure_ascii=False, indent=2)
    except json.JSONDecodeError:
        return "Error: args 参数不是有效的 JSON"
    except Exception as e:
        return f"Error: {e}"


@mcp.tool()
def run_report(report_name: str, filters: Optional[str] = None) -> str:
    """运行报表。filters 为 JSON 对象"""
    try:
        payload = {"report_name": report_name}
        if filters:
            payload["filters"] = json.loads(filters)
        result = get_client().post(
            "/api/method/frappe.desk.query_report.run", json_data=payload
        )
        return json.dumps(result, ensure_ascii=False, indent=2)
    except json.JSONDecodeError:
        return "Error: filters 参数不是有效的 JSON"
    except Exception as e:
        return f"Error: {e}"


# ========================== Monitoring ==========================

@mcp.tool()
def get_container_logs(service: str = "backend", lines: int = 100) -> str:
    """查看容器日志。service: backend/frontend/db/scheduler/queue-long/queue-short 等"""
    if service not in VALID_SERVICES:
        return f"Error: 无效的服务名。可选: {', '.join(sorted(VALID_SERVICES))}"
    try:
        return run_compose("logs", "--tail", str(min(lines, 500)), "--no-color", service)
    except subprocess.TimeoutExpired:
        return "Error: 获取日志超时"
    except Exception as e:
        return f"Error: {e}"


@mcp.tool()
def health_check() -> str:
    """检查 ERPNext 各服务健康状态 (API/数据库/Redis)"""
    results = {}

    # Backend API
    try:
        r = httpx.get(f"{BASE_URL}/api/method/ping",
                      headers={"Host": DEFAULT_SITE}, timeout=10)
        results["backend_api"] = "ok" if r.status_code == 200 else f"status={r.status_code}"
    except Exception as e:
        results["backend_api"] = f"error: {e}"

    # Database
    try:
        out = run_compose("exec", "-T", "db",
                          "mysqladmin", "ping", "-h", "localhost",
                          f"--password={DB_PASSWORD}", "--silent", timeout=15)
        results["database"] = "ok" if "alive" in out.lower() else out
    except Exception as e:
        results["database"] = f"error: {e}"

    # Redis
    try:
        out = run_compose("exec", "-T", "redis-cache",
                          "redis-cli", "ping", timeout=10)
        results["redis"] = "ok" if "PONG" in out.upper() else out
    except Exception as e:
        results["redis"] = f"error: {e}"

    return json.dumps(results, ensure_ascii=False, indent=2)


@mcp.tool()
def get_error_logs(limit: int = 20, title_filter: Optional[str] = None) -> str:
    """获取 Frappe 错误日志"""
    try:
        params = {
            "fields": json.dumps(["name", "creation", "method", "error"]),
            "order_by": "creation desc",
            "limit_page_length": min(limit, 50),
        }
        if title_filter:
            params["filters"] = json.dumps([["method", "like", f"%{title_filter}%"]])
        data = get_client().get("/api/resource/Error Log", params=params)
        # Truncate long error messages
        if "data" in data:
            for entry in data["data"]:
                if entry.get("error") and len(entry["error"]) > 2000:
                    entry["error"] = entry["error"][:2000] + "... (truncated)"
        return json.dumps(data, ensure_ascii=False, indent=2)
    except Exception as e:
        return f"Error: {e}"


@mcp.tool()
def get_scheduler_status() -> str:
    """检查 Frappe 调度器状态"""
    try:
        result = get_client().get("/api/method/frappe.utils.scheduler.get_scheduler_status")
        return json.dumps(result, ensure_ascii=False, indent=2)
    except Exception as e:
        return f"Error: {e}"


@mcp.tool()
def get_container_status() -> str:
    """查看所有 ERPNext Docker 容器状态"""
    try:
        return run_compose("ps", "--format",
                           "table {{.Name}}\t{{.Status}}\t{{.Ports}}")
    except Exception as e:
        return f"Error: {e}"


# ========================== Site Management ==========================

@mcp.tool()
def list_sites() -> str:
    """列出所有 Frappe 站点"""
    try:
        out = run_compose(
            "exec", "-T", "backend", "bash", "-c",
            "ls -d sites/*/site_config.json 2>/dev/null | sed 's|sites/||;s|/site_config.json||'"
        )
        sites = [s.strip() for s in out.split("\n") if s.strip()]
        return json.dumps({"sites": sites}, ensure_ascii=False, indent=2)
    except Exception as e:
        return f"Error: {e}"


@mcp.tool()
def get_installed_apps(site: str = DEFAULT_SITE) -> str:
    """查看站点已安装的应用"""
    try:
        return bench_exec(site, "list-apps")
    except Exception as e:
        return f"Error: {e}"


@mcp.tool()
def backup_site(site: str = DEFAULT_SITE) -> str:
    """备份站点 (数据库 + 文件)"""
    try:
        return bench_exec(site, "backup", "--with-files", timeout=300)
    except subprocess.TimeoutExpired:
        return "Error: 备份超时 (>300s)"
    except Exception as e:
        return f"Error: {e}"


@mcp.tool()
def run_bench_command(command: str, site: str = DEFAULT_SITE) -> str:
    """运行 bench 命令 (白名单限制)。如: migrate, clear-cache, build, version, doctor"""
    parts = command.strip().split()
    if not parts:
        return "Error: 命令不能为空"
    cmd_name = parts[0]
    if cmd_name not in ALLOWED_BENCH_COMMANDS:
        return f"Error: 不允许的命令 '{cmd_name}'。允许的命令: {', '.join(sorted(ALLOWED_BENCH_COMMANDS))}"
    try:
        timeout = 300 if cmd_name in ("migrate", "build", "export-fixtures", "import-fixtures") else 120
        return bench_exec(site, *parts, timeout=timeout)
    except subprocess.TimeoutExpired:
        return f"Error: 命令超时"
    except Exception as e:
        return f"Error: {e}"


@mcp.tool()
def create_site(site_name: str, admin_password: Optional[str] = None,
                install_erpnext: bool = True) -> str:
    """创建新站点"""
    try:
        pw = admin_password or ADMIN_PASSWORD
        # Install setuptools first
        run_compose("exec", "-T", "backend", "bash", "-c",
                    '/home/frappe/frappe-bench/env/bin/pip install "setuptools<81" -q',
                    timeout=60)
        # Build bench new-site command
        cmd = [
            "exec", "-T", "backend",
            "bench", "new-site",
            "--mariadb-user-host-login-scope=%",
            f"--admin-password={pw}",
            "--db-root-username=root",
            f"--db-root-password={DB_PASSWORD}",
        ]
        if install_erpnext:
            cmd.extend(["--install-app", "erpnext"])
        cmd.append(site_name)
        out = run_compose(*cmd, timeout=600)

        # Install hrms if available
        try:
            run_compose("exec", "-T", "backend", "bash", "-c",
                        f"[ -d /home/frappe/frappe-bench/apps/hrms ] && "
                        f"bench --site {site_name} install-app hrms",
                        timeout=300)
        except Exception:
            pass

        return out if out else f"站点 {site_name} 创建成功"
    except subprocess.TimeoutExpired:
        return "Error: 站点创建超时 (>600s)"
    except Exception as e:
        return f"Error: {e}"


@mcp.tool()
def manage_services(action: str) -> str:
    """启动或停止所有服务。action: up 或 down"""
    if action not in ("up", "down"):
        return "Error: action 必须是 'up' 或 'down'"
    try:
        if action == "up":
            services = "backend db redis-cache redis-queue frontend websocket queue-long queue-short scheduler"
            return run_compose("up", "-d", *services.split(), timeout=120)
        else:
            return run_compose("down", timeout=120)
    except subprocess.TimeoutExpired:
        return "Error: 操作超时"
    except Exception as e:
        return f"Error: {e}"


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    log.info(f"Starting ERPNext MCP server (port={ERPNEXT_PORT}, site={DEFAULT_SITE})")
    mcp.run(transport="stdio")
