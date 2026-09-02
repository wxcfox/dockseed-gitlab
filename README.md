# DockSeed GitLab

使用 Docker Compose 在本机运行 GitLab CE。Cloudflare Tunnel、DNS 和公网入口由独立的 `dockseed-cloudflared` 工程管理。

## 前置条件

- Docker Desktop 与 Docker Compose v2
- Docker Desktop 建议至少分配 6 GB 内存

Apple Silicon 使用 `linux/arm64`，Intel Mac 使用 `linux/amd64`。

## 配置与启动

复制配置模板并按注释填写 `.env`：

```bash
cp .env.example .env
chmod 600 .env
docker volume create dockseed-gitlab-config
docker volume create dockseed-gitlab-logs
docker volume create dockseed-gitlab-data
```

`GITLAB_VERSION` 使用完整的 GitLab CE 镜像 tag。首次登录用户名为 `root`；`GITLAB_ROOT_PASSWORD` 只在全新数据目录首次初始化时生效。

```bash
docker compose config --quiet
docker compose up -d
docker compose ps
```

等待 `dockseed-gitlab` 显示 `healthy`。

访问地址：

- Web：`http://127.0.0.1:8929`，或 `.env` 中配置的 `GITLAB_EXTERNAL_URL`
- SSH：`ssh://git@127.0.0.1:2224/group/project.git`

公网接入由 `dockseed-cloudflared` 转发本机 8929 端口。在该工程中执行：

```bash
./start.sh add gitlab 8929
```

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

## 升级 GitLab

修改 `.env` 中的 `GITLAB_VERSION`，然后执行：

```bash
docker compose pull gitlab
docker compose up -d gitlab
docker compose ps
```

等待容器显示 `healthy` 后即可使用。跨版本升级前查看 GitLab 官方的 [升级路径](https://docs.gitlab.com/update/upgrade_paths/)，并等待后台迁移完成。

持久化数据仍会保留，但新版本可能已经修改数据库结构。仅改回旧 tag 不是可靠回滚方式；需要降级时遵循 GitLab 官方的 [Docker 回滚流程](https://docs.gitlab.com/update/package/downgrade/)。

## 数据持久化

GitLab 使用 Docker 原生命名卷：

- `dockseed-gitlab-config` → `/etc/gitlab`：GitLab 配置和密钥
- `dockseed-gitlab-logs` → `/var/log/gitlab`：日志
- `dockseed-gitlab-data` → `/var/opt/gitlab`：仓库、PostgreSQL、Redis、上传文件及应用数据

命名卷由 Docker 的 Linux VM 管理，可保留 GitLab 所需的 Unix 所有权、权限和 socket 语义。不要把运行中的 `/var/opt/gitlab` 直接压缩后解包到 macOS bind mount；机器迁移应使用 GitLab 官方 backup/restore 流程，并单独迁移 `/etc/gitlab`。

容器可以安全重建；不要删除上述三个命名卷。

## 常见问题

- **本机无法访问**：运行 `docker compose ps`，确认 GitLab 为 `healthy`，再查看 `docker compose logs --tail=200 gitlab`。
- **启动时间过长**：GitLab 启动通常需要数分钟；Docker Desktop 内存不足时会更久。
- **端口冲突**：检查本机 8929 或 2224 端口占用。
- **公网入口失败**：在 `dockseed-cloudflared` 工程中排查。
