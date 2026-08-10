# DockSeed GitLab

本项目只负责在本机 Docker Desktop 中运行 GitLab CE。Cloudflare Tunnel、DNS 和公网入口由独立的 `dockseed-cloudflared` 工程管理，本项目不再启动或配置 `cloudflared`。

固定版本：GitLab CE `gitlab/gitlab-ce:19.2.0-ce.0`。

## 前置条件

- Docker Desktop 与 Docker Compose v2
- Docker Desktop 建议至少分配 6 GB 内存

Apple Silicon 原生使用 `linux/arm64`。如果固定 GitLab 镜像不提供 arm64，才在 `.env` 中明确改为 `linux/amd64`；模拟运行会更慢并占用更多资源。

## 启动与访问

复制示例配置并填写 root 初始密码；使用反向代理时再配置 `GITLAB_EXTERNAL_URL`：

```bash
cp .env.example .env
chmod 600 .env
```

在本目录执行：

```bash
docker compose config --quiet
docker compose up -d
docker compose ps
```

等待 `dockseed-gitlab` 显示 `healthy`。

访问入口：

- 默认本机 Web 与 HTTP clone：`http://127.0.0.1:8929`
- 自定义 Web 与 HTTPS clone：`.env` 中可选的 `GITLAB_EXTERNAL_URL`
- 本机 SSH：`ssh://git@127.0.0.1:2224/group/project.git`

未配置 `GITLAB_EXTERNAL_URL` 时，GitLab 使用本机默认地址生成链接；配置后则使用该地址。公网 DNS、TLS 和转发仍由独立 gateway 管理。

独立 gateway 通过本机 8929 端口接入 GitLab。在 `dockseed-cloudflared` 工程中执行：

```bash
./start.sh add gitlab 8929
```

本项目不会修改 Cloudflare DNS 或 Tunnel。

## 首次登录

用户名为 `root`。`.env` 中的初始密码仅在全新的 GitLab 数据目录第一次初始化时生效；已有数据不会因修改该变量而重置密码。

`.env` 已被忽略，并应保持 `600` 权限。不要把密码输出到聊天、截图或日志中。

## 日常操作

```bash
# 启动
docker compose up -d

# 停止（保留数据）
docker compose stop

# 重启
docker compose restart gitlab

# 状态
docker compose ps

# 日志
docker compose logs -f --tail=200 gitlab
```

Mac 重启后，先启动 Docker Desktop，再在本目录运行 `docker compose up -d`。

## 数据与备份

GitLab 使用现有的宿主机 bind mount，不使用本项目命名的 Docker volume：

- `gitlab/config` → `/etc/gitlab`：GitLab 配置和密钥
- `gitlab/logs` → `/var/log/gitlab`：日志
- `gitlab/data` → `/var/opt/gitlab`：仓库、PostgreSQL、Redis、上传文件及应用数据

备份前可运行 `docker compose stop gitlab`，再完整备份 `gitlab/` 和 `.env`。恢复时放回原路径并检查权限，然后运行 `docker compose up -d`。

不要使用 `docker compose down -v`、`docker volume rm`、`docker system prune` 或其他会删除数据的命令。

## 常见问题

- **本机 8929 无法访问**：先运行 `docker compose ps`，确认 GitLab 为 `healthy`，再查看 `docker compose logs --tail=200 gitlab`。
- **启动时间过长**：GitLab 启动通常需要数分钟；Docker Desktop 内存不足时会更久。
- **端口冲突**：定位占用本机 8929 或 2224 的进程，不要删除无关容器或数据。
- **公网入口失败**：在独立的 `dockseed-cloudflared` 工程中排查；本项目只验证本机 8929 入口。
