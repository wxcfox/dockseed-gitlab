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

## Container Registry

GitLab 自带的 Container Registry 默认关闭。`.env` 中留空 `GITLAB_REGISTRY_EXTERNAL_URL` 时，现有部署行为不变。

Registry 沿用主站的接入模式：容器内只监听明文 HTTP，不引入证书、不开启 Let's Encrypt，TLS 由前置反向代理终止。镜像层数据落在已有的 `dockseed-gitlab-data` 卷（`/var/opt/gitlab/gitlab-rails/shared/registry`），不新增卷。

### 启用

1. 在 `.env` 中填写 Registry 的公网地址，端口按需调整：

   ```bash
   GITLAB_REGISTRY_EXTERNAL_URL=https://registry.example.com
   GITLAB_REGISTRY_PORT=5050
   ```

2. 重建容器，等待 `healthy`：

   ```bash
   docker compose config --quiet
   docker compose up -d
   docker compose ps
   ```

   容器内 Registry nginx 监听 5050，发布到宿主机 `${GITLAB_REGISTRY_BIND_ADDR}:${GITLAB_REGISTRY_PORT}`（默认 `127.0.0.1:5050`），由前置代理转发。

3. 在前置代理中把 Registry 子域名转发到本机 `GITLAB_REGISTRY_PORT`。前置代理可以是 Cloudflare Tunnel、Caddy、Nginx 等任意能终止 TLS 的反向代理；以本工程配套的 `dockseed-cloudflared` 为例：

   ```bash
   ./start.sh add registry 5050
   ```

### 前置代理要求

- **独立子域名**：Registry 子域名必须与 GitLab 主站子域名不同（例如 `gitlab.example.com` 与 `registry.example.com`），两者分别转发到 8929 与 `GITLAB_REGISTRY_PORT`。
- **放行大请求体并延长超时**：`docker push` 单层可达数百 MB，代理必须放行大请求体并延长读写超时。若代理存在请求体上限且无法放宽，Runner 应绕过代理直连 Registry 的 HTTP 端口推送，公网地址只用于拉取。直连时注意：
  - Runner 的 Job 跑在容器内，直连地址必须是 Runner 容器可达的宿主机地址。Docker Desktop 下默认绑定 `127.0.0.1` 即可通过 `host.docker.internal:<GITLAB_REGISTRY_PORT>` 访问；Linux 宿主机的 `127.0.0.1` 对容器不可达，需把 `GITLAB_REGISTRY_BIND_ADDR` 改为 docker 网桥 IP 或 Runner 可达的内网 IP，并使用该地址。
  - 该地址是明文 HTTP，只应在可信内网暴露；dind 服务需以 `--insecure-registry <地址>` 启动。

### 验证

1. 登录 Registry，使用 GitLab 账号密码或带 `read_registry`、`write_registry` 权限的 Personal Access Token：

   ```bash
   docker login registry.example.com
   ```

2. 推送一个小镜像到某个项目的路径下（镜像路径必须以项目的完整路径开头）：

   ```bash
   docker pull alpine:3.20
   docker tag alpine:3.20 registry.example.com/group/project/alpine:3.20
   docker push registry.example.com/group/project/alpine:3.20
   ```

3. 打开该项目的 **Deploy > Container Registry**（旧版本为 **Packages > Container Registry**），应能看到刚推送的镜像。

启用后，GitLab CI 会自动提供 `CI_REGISTRY`、`CI_REGISTRY_IMAGE`、`CI_REGISTRY_USER`、`CI_REGISTRY_PASSWORD` 等预定义变量，`.gitlab-ci.yml` 中可直接使用：

```yaml
build:
  image: docker:27
  services:
    - docker:27-dind
  script:
    - echo "$CI_REGISTRY_PASSWORD" | docker login -u "$CI_REGISTRY_USER" --password-stdin "$CI_REGISTRY"
    - docker build -t "$CI_REGISTRY_IMAGE:$CI_COMMIT_SHORT_SHA" .
    - docker push "$CI_REGISTRY_IMAGE:$CI_COMMIT_SHORT_SHA"
```

### 关闭

在 `.env` 中清空或注释掉 `GITLAB_REGISTRY_EXTERNAL_URL`，然后重建容器：

```bash
docker compose up -d
```

Registry 进程、CI 预定义变量和固定的宿主机端口发布随之消失。已推送的镜像数据仍留在 `dockseed-gitlab-data` 卷中，重新启用后可继续使用；需要释放空间时手动清理容器内的 `/var/opt/gitlab/gitlab-rails/shared/registry`。前置代理侧记得同步删除 Registry 子域名的转发。

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

启动时会在 GitLab 服务拉起前清理 PostgreSQL 遗留的 Unix socket 和锁文件，避免容器或宿主机非正常停止后旧 PID 与容器内新进程 PID 碰撞，导致 PostgreSQL 无法启动。该清理只删除运行态文件，不涉及数据库数据。

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
- **端口冲突**：检查本机 8929、2224 或 `GITLAB_REGISTRY_PORT`（默认 5050）端口占用。
- **公网入口失败**：在 `dockseed-cloudflared` 工程中排查。
- **docker push 报 413 或中途断开**：检查前置代理的请求体上限与超时；无法放宽时按「前置代理要求」改为直连 Registry 的 HTTP 端口推送。
