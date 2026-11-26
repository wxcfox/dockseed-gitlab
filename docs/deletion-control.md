# 删除需管理员共同确认（可选）

本特性默认关闭；不启用时，现有部署的 Compose 配置和行为完全不变。以下命令须先替换示例值（`example-group`、`gitlab.example.com`、账号名等），**任一步失败即停止后续操作**。

## 机制说明

启用后，GitLab 里任何工程或组（包括个人空间下的工程）被点删除时，都不会立即删除，而是由程序在固定的申请工程里开一个合并请求（MR），并 @ 全部管理员。管理员点 **Approve** 表示同意，关闭这个 MR 表示拒绝。同意的管理员够数，程序立即调用 GitLab 删除，对象进入回收站，在保留期内管理员可以恢复。

需要的人数由 `DELETION_REQUIRED_ADMINS`（下称 N）决定，默认 0，即不管控、删除照常，和没有这个功能一样；按团队需要设为 1 或 2。计票方法：发起人是管理员时自动算一票，再加上点了 Approve 的管理员，同一人只算一次。

| N | 管理员点删除 | 普通用户点删除 |
|---|---|---|
| 0 | 不启用，照常删除 | 照常删除 |
| 1 | 立即执行 | 1 位管理员 Approve 后执行 |
| 2 | 再要 1 位其他管理员 Approve | 2 位管理员 Approve 后执行 |

请求的走向：

```text
用户 ──> 前置代理（可选）──> GitLab 自带的 Nginx ─┬─ 可能删除工程或组的请求 ─> deletion-control:8931
                                                 │     ├─ 不是删除 ─> 原样转发 ─> gitlab:8932（须带密钥）─> GitLab
                                                 │     └─ 是删除 ─> 开 MR（或够数时直接执行）
                                                 └─ 其余请求 ─> GitLab
管理员点 Approve ──> GitLab 系统钩子 ──> deletion-control:8933 ──> 重新计票，够数则经 gitlab:8932 删除
```

| 组件 | 文件 | 作用 |
|---|---|---|
| Nginx 转发规则 | `ops/deletion-control/gitlab.rb.example` | 写进持久化的 `gitlab.rb`，由 GitLab 自带的 Nginx 执行：把可能删除工程或组的请求交给 deletion-control；另开一个 8932 入口供程序使用，只接受带密钥的请求 |
| deletion-control 服务 | `ops/deletion-control/deletion_control.py` | 识别删除请求、开 MR、收系统钩子后计票并执行；其余请求原样转发 |
| GitLab 里的设置 | — | 一个专用管理员账号及其令牌、一个内部可见的申请工程、一个系统钩子 |
| 密钥目录 | `DELETION_SECRETS_DIR` | 宿主机上的 `token`（专用账号的令牌）和 `upstream-key`（8932 入口的密钥），不进入仓库和备份 |

规则：

- **谁能发起**：GitLab 本来允许谁删就谁删，即该工程或组的 Owner 和管理员。没有删除权限的人发出删除请求，返回 404，不开 MR。
- **身份按 GitLab 的标准核对**：网页操作须带 GitLab 认可的防跨站令牌（程序把它交给 GitLab 校验）；访问令牌须有 `api` 权限，只读令牌和 CI 作业令牌不能发起删除。核对不通过返回 401。
- **删除对象**：程序把目标的类型、ID 和发起人 ID 写进 MR 的源分支名（如 `delete/project-343/u-57-…`）。分支名建好后不能修改，程序也只认自己的账号开的 MR，所以改 MR 的标题、描述都改不了删除对象和发起人。工程改名或移动不影响，按 ID 执行。
- **计票**：每次有人点 Approve，GitLab 通过系统钩子通知程序。程序不采信通知内容，而是用 API 重新读这条 MR 的批准人，并按此刻的身份核对谁是管理员；被取消管理员身份的人不再计票，已封禁的账号和程序自己的账号不计。
- **执行**：够数时程序先确认 MR 仍开着，然后依次：关闭 MR、删掉申请分支、调用删除 API（目标进入回收站）、在 MR 里留言列出同意的管理员。前两步任何一步失败都不删除。源分支不存在的 MR，GitLab 不允许重新打开，所以执行过的申请不会被重新启用，每个申请最多执行一次。删除失败时留言说明原因，申请保持关闭，需要时重新发起；删除请求发出后没收到 GitLab 答复时，页面和留言都提示「结果待确认」，不自动重试；留言失败只记日志，不影响结果。
- **拒绝**：任何管理员关闭 MR 即拒绝，程序只删掉分支，之后这条申请不能重新打开。发起人也可以关闭自己的申请来撤回。
- **重复点删除**：同一对象已有未关闭的申请时，跳到这条申请，不会重复开。
- **立即删除**：已在回收站的对象不能提前永久删除，页面和 API 都会拒绝，到保留期满由 GitLab 自动清除。
- **管理中心的删除**：GitLab 管理中心里删除工程或组是直接永久删除；启用后同样转成申请，执行时进入回收站。
- **API 和脚本**：`DELETE /api/v4/projects/:id`、`/api/v4/groups/:id` 同样转成申请，返回 403 和申请链接（够数立即执行时返回 202）。依赖 API 删除的脚本会失败，除非 N=1 且用管理员令牌。
- **导入覆盖**：GitLab 的工程导入 API（`/api/v4/projects/import`、`remote-import`、`remote-import-s3`）带 `overwrite` 时会删除同路径的原工程，启用后一律拒绝；不覆盖的导入不受影响。
- **三条保证**：同意的管理员不够 N 位，不删除；一个申请最多执行一次；出错时只会「删不了」，不会「多删」——看不清是谁发出的请求、GitLab 暂时访问不了、令牌失效或失去管理员权限时，一律拒绝，不转发删除请求。

程序只用 Python 标准库，使用上游 `python:3.12-alpine` 镜像挂载脚本运行，不构建镜像；容器以 UID 65534 运行，根文件系统只读、去掉全部 capability，不发布端口。重启策略固定为 `unless-stopped`，不跟随 `GITLAB_RESTART_POLICY`：Nginx 把网页表单提交，以及 `/api/v4/projects/`、`/api/v4/groups/` 下的写请求都转给它判断，它没运行时这些请求会返回 502；浏览页面、登录、GraphQL、Git 推拉和其他 API 不经过它。

## 前提

- **GitLab 19.6 及以上**：本功能按 19.6 的行为实现和验证，不兼容更早的版本。例如「源分支已删除的合并请求不能重新打开」在 19.6 才是无条件生效的规则，「一个申请最多执行一次」依赖它。
- **管理员人数**：普通用户的申请需要 N 位管理员，至少要有 N 位可用的管理员。
- **两项实例设置保持关闭**：「允许用户删除自己的账号」（`allow_account_deletion`）和「删除不活跃工程」（`delete_inactive_projects`）。删除账号会连带删掉该用户的个人工程，自动清理会删掉长期不活跃的工程，都不经过删除操作。GitLab 新装时允许用户删除自己的账号，需在 **管理中心 → 设置 → 通用 → 帐户和限制** 中关闭。
- **申请工程内部可见**：普通用户要能打开自己的申请。GitLab 不允许工程比所在的组更公开，所以建议把申请工程建在专用账号的个人空间里；放在组下时，该组也须为内部可见。
- **镜像**：服务器须能取得 `python:3.12-alpine`。无法访问 Docker Hub 时，在可访问的机器上拉取对应平台的镜像，用 `docker save` / `docker load` 导入同名镜像。

## 安装

### 1. 专用管理员账号和令牌

在 **管理中心 → 用户** 新建一个只给程序用的账号（如 `deletion-bot`），访问级别设为 **管理员**。邮箱填管理员都能收到的地址：令牌到期前 GitLab 会发提醒邮件到这里。

用该账号签发 Personal Access Token：范围只选 **api**（实例开启了 Admin Mode 时再勾选 **admin_mode**），到期日按实例上限填写，并记下续期日期。程序处理每个删除请求时都会确认令牌仍有管理员权限（账号被降权或中途开启 Admin Mode 都会立刻发现），没有就拒绝删除，并在日志中说明原因。管理员可在 **管理中心 → 用户 → 该账号 → 模拟** 后在其 **用户设置 → 访问令牌** 中签发，或用 API 为其签发。

持有该令牌即可删除实例里的任何对象。令牌只放在第 3 步的密钥目录中，不写进 `.env`、仓库、镜像或日志；泄露时立即在 GitLab 中撤销。

### 2. 申请工程

以第 1 步的专用账号在它的个人空间里建一个内部可见的工程存放申请，例如 `deletion-bot/deletion-requests`，勾选「使用自述文件初始化仓库」，让它有默认分支。个人空间不受组的可见性限制；如果放在组下，该组也须为内部可见。

在该工程 **设置 → 仓库 → 受保护分支** 中，把默认分支的「允许合并」和「允许推送和合并」都设为 **无人**。每个申请 MR 带一个提交（在 `requests/` 下新增一个说明文件）：没有改动的 MR，GitLab 不显示 Approve 按钮；默认分支无人可合并，申请就只能 Approve 或关闭，不会被误合并。可选：关闭该工程的议题、Wiki、CI/CD 等用不到的功能。

### 3. 密钥目录

目录里放两个文件：`token` 是第 1 步的令牌；`upstream-key` 是程序访问 8932 入口的密钥，随机生成，第 6 步会把它写进 `gitlab.rb`。目录 `0700`、文件 `0600`；容器以 UID 65534 运行，Linux 上交给该 UID。ECS 建议放在 ESSD 上，并在 `.env` 中设置 `DELETION_SECRETS_DIR=/srv/gitlab/deletion-control`。在 Linux root 的 bash 中执行：

```bash
umask 077
D=/srv/gitlab/deletion-control
mountpoint -q /srv/gitlab && install -d -m 0700 "$D"
read -rsp '粘贴令牌后回车：' token && printf '%s\n' "$token" > "$D/token"; unset token; echo
od -An -N32 -tx1 /dev/urandom | tr -d ' \n' > "$D/upstream-key"
chown -R 65534:65534 "$D"
```

Mac（Docker Desktop）在工程目录使用默认路径 `./deletion-control`，无需 `chown`；`deletion-control/` 已在 `.gitignore` 中：

```bash
umask 077
mkdir -p deletion-control
read -rsp '粘贴令牌后回车：' token && printf '%s\n' "$token" > deletion-control/token; unset token; echo
od -An -N32 -tx1 /dev/urandom | tr -d ' \n' > deletion-control/upstream-key
```

程序每次使用时重新读取这两个文件，覆盖文件后立即生效。

### 4. 填写 .env

在 `.env` 中加入（变量说明见 `.env.example`）：

```dotenv
COMPOSE_PROFILES=deletion-control
DELETION_REQUIRED_ADMINS=1
DELETION_REQUESTS_PROJECT=deletion-bot/deletion-requests
```

`DELETION_REQUIRED_ADMINS` 按团队需要填 1 或 2（见「机制说明」中的表）；不填或填 0 等于不启用。

| 变量 | 说明 |
|---|---|
| `COMPOSE_PROFILES` | 设为 `deletion-control` 后，日常 `docker compose` 命令即包含 deletion-control 服务 |
| `DELETION_REQUIRED_ADMINS` | 删除需要几位管理员同意，默认 `0`（不管控，删除照常）；发起人是管理员时自动算一票 |
| `DELETION_REQUESTS_PROJECT` | 申请工程的完整路径 |
| `DELETION_SECRETS_DIR` | 可选；宿主机上的密钥目录，默认 `./deletion-control` |

这些变量缺失或格式不对时，`docker compose config` 仍会通过，由程序启动时报配置错误并退出；这样未启用本特性的部署不受新变量影响。

### 5. 启动服务

```bash
docker compose config --quiet
docker compose up -d deletion-control
docker compose ps
docker compose logs --tail=20 deletion-control
```

服务应显示 `healthy`，日志有 `listening on :8931 (hooks on :8933); required admins: 1`（按你填的值）。它没有 `depends_on`，这条命令不会启动或重建 gitlab 容器。

### 6. Nginx 转发规则

**先完成第 5 步**，否则转给它的请求会得到 502。把 `ops/deletion-control/gitlab.rb.example` 中的 `REPLACE_WITH_UPSTREAM_KEY` 换成第 3 步的密钥，追加到持久化的 `gitlab.rb` 末尾（`gitlab.rb` 已设置 `custom_nginx_config` 或 `custom_gitlab_server_config` 时，按文件开头的说明合并），然后 reconfigure。只改了这一段时，reconfigure 重新生成配置并重载 Nginx，不会重启 GitLab：

```bash
docker exec dockseed-gitlab cp -p /etc/gitlab/gitlab.rb "/etc/gitlab/gitlab.rb.before-deletion-control-$(date +%Y%m%d)"
sed "s/REPLACE_WITH_UPSTREAM_KEY/$(cat /srv/gitlab/deletion-control/upstream-key)/" ops/deletion-control/gitlab.rb.example |
  docker exec -i dockseed-gitlab sh -c 'cat >> /etc/gitlab/gitlab.rb'
docker exec dockseed-gitlab gitlab-ctl reconfigure
docker exec dockseed-gitlab /opt/gitlab/embedded/sbin/nginx -t -p /var/opt/gitlab/nginx
```

`gitlab.rb` 里因此有了这把密钥；它随配置备份保存，与其他 GitLab 机密同等对待。

`nginx -t` 失败时恢复备份并再次 reconfigure 后排查。回退方法相同：复制备份回原位，reconfigure。

### 7. 系统钩子

在 **管理中心 → 系统钩子** 新建：

- **URL**：`http://deletion-control:8933/hook`
- **触发器**：只勾选 **合并请求事件**，取消推送、标签推送和仓库更新事件
- 不填密钥令牌；8933 端口不经过 GitLab 的 Nginx，外部访问不到；程序收到通知后还会用 API 重新核对，伪造的通知不会造成删除。

系统钩子默认允许发往本地网络（`allow_local_requests_from_system_hooks`），无需修改出站请求设置。

### 8. 部署后检查

在任意能访问正式地址的机器上执行，不带令牌、使用不存在的 ID，不会改动任何数据：

```bash
B=https://gitlab.example.com
curl -s -X POST "$B/.deletion-control"; echo
curl -s -X DELETE "$B/api/v4/projects/999999999"; echo
curl -s -X POST -H 'X-HTTP-Method-Override: DELETE' "$B/example-group/no-such-project"; echo
curl -s "$B/api/v4/version"; echo
```

第一条应输出 `deletion-control: requests reach this service`，第二、三条为 `无法确认你的身份或权限` 的提示，最后一条为 GitLab 自己的 `401 Unauthorized`。前三条若是 GitLab 的 404 或 401，说明规则没有生效，立即排查。

再在服务器上确认 8932 入口拒绝不带密钥的请求，应输出 `deletion-control upstream key mismatch`：

```bash
docker exec dockseed-gitlab curl -s http://127.0.0.1:8932/api/v4/version
```

## 演练

用两个管理员账号和一个普通账号，在不含业务数据的测试工程上完成：

1. **普通用户发起**：普通账号作为 Owner，在工程 **设置 → 通用 → 高级** 中删除，浏览器应跳到新开的申请 MR；工程不变。普通账号和全部管理员的待办里都有这条申请。
2. **计票**：管理员点 Approve。同意的管理员不足 N 位时工程不变；达到 N 位后几秒内工程进入回收站，MR 下出现「已删除工程」留言并关闭。
3. **回收站**：对待删除的工程执行「立即删除」，应看到「已在回收站」的提示页。
4. **恢复**：在工程 **设置 → 通用 → 高级** 中恢复，或调用 `POST /api/v4/projects/<ID>/restore`；恢复不受限制。
5. **管理员发起**：管理员删除同一工程，申请里写明「发起人是管理员，已计 1 票」。N=1 时立即执行，浏览器跳到已关闭的申请；N=2 时再由另一位管理员 Approve 才执行。
6. **拒绝**：再发起一次，由管理员关闭 MR，工程保持原样，分支被删除。
7. **无权删除**：没有 Owner 权限的账号用 API 删除，返回 404，不开申请。

演练结束后，测试工程可再走一次申请删除，或留在回收站到期。

## 调整人数

修改 `.env` 中的 `DELETION_REQUIRED_ADMINS`，然后重建服务：

```bash
docker compose config --quiet && docker compose up -d deletion-control
```

新值从下一次计票起生效，对已开出的申请同样适用。改为 0 即停用：删除照常放行，已开出的申请原样保留，不再处理；要彻底停用，按「停用与回退」操作。

## 日常运维

- **令牌续期**：到期前用专用账号签发新令牌，按第 3 步覆盖 `token` 文件（立即生效，无需重启），确认部署后检查正常，再在 GitLab 中撤销旧令牌。令牌过期时，删除请求会显示「删除申请暂时无法创建」，不会被放行。令牌不备份，需要时重新签发。
- **GitLab 升级后**：GitLab 升级会重新生成自带 Nginx 的配置。升级后按第 8 步复查；有条件时做一次演练第 1、2 步。
- **程序停机期间**：转给它的请求（网页表单提交，`/api/v4/projects/`、`/api/v4/groups/` 下的写请求）返回 502，其他请求不受影响。停机期间点的 Approve 不会补执行；恢复后让一位管理员撤回 Approve 再点一次，或编辑一下这个 MR（如修改描述），程序都会重新计票。
- **健康检查**：程序提供 `/healthz`。GitLab 停机、升级期间转发失败返回 502，恢复后自动继续，无需停止服务。
- **更换入口密钥**：重新生成 `upstream-key`，再把 `gitlab.rb` 中的旧密钥换成新值并 reconfigure；两处不一致期间，转给程序的请求会返回 502 或 503。
- **日志**：`docker compose logs deletion-control` 记录开出的申请（`REQUEST`）、执行（`EXECUTED`）、拒绝（`REFUSE`）和错误（`ERROR`），不含令牌和会话信息。正常转发的请求不记录。
- **记录**：申请 MR 关闭后仍留在申请工程里，可以作为删除记录查阅；程序不另存状态。

## 服务器重建后恢复

`ops/backup.sh` 的部署包包含本文、程序、`gitlab.rb.example` 和带有上述变量的 `.env`；`gitlab.rb`（含转发规则）在配置备份中，系统钩子和申请工程在 GitLab 数据中，令牌不在任何备份里。按 [备份与人工恢复](recovery.md) 恢复 GitLab 后：

1. **隔离恢复验收期间不启动本特性**：不建密钥目录，`docker compose up` 该服务会因绑定源不存在而失败；也可以临时注释 `COMPOSE_PROFILES`。恢复的 `gitlab.rb` 带着转发规则，服务没运行时网页表单提交和工程、组的 API 写请求都会返回 502，删除不会被放行。
2. **正式切换时**：重新签发令牌并撤销旧令牌，按第 3 步写入 `token`；`upstream-key` 写入恢复出的 `gitlab.rb` 中的那把密钥（或生成新密钥并同步改 `gitlab.rb`），按第 5 步启动服务，再完成第 8 步检查。

## 停用与回退

1. 从 `gitlab.rb` 中删去转发规则（或复制回第 6 步的备份），执行 `gitlab-ctl reconfigure`。
2. 再停止服务：`docker compose stop deletion-control`，并注释 `.env` 中的 `COMPOSE_PROFILES`。
3. 可选：在 **管理中心 → 系统钩子** 删除钩子，撤销令牌。

顺序不能反过来：规则还在而服务已停时，网页表单提交和工程、组的 API 写请求都会返回 502。

## 故障排查

- **删除没有转成申请**：按第 8 步检查；`gitlab.rb` 里的规则是否被后面的同名赋值覆盖；`docker compose ps` 是否健康。
- **网页提交表单返回 502**：服务没有运行，或 GitLab 容器解析不到 `deletion-control`（两者须在同一个 Compose 工程网络中）。
- **服务反复重启，日志为 `can't open file ... Permission denied`**：容器用户 65534 读不到 `ops/` 下的脚本，常见于在 `umask 077` 下检出或更新工程。在工程目录执行 `chmod 0755 ops/deletion-control && chmod 0644 ops/deletion-control/*` 后重启服务；以后更新工程前先 `umask 022`。
- **删除请求显示「删除申请暂时无法创建」或转发返回 502**：看日志中的 `ERROR`。`refused the upstream key` 或 `upstream key must be` 是 `upstream-key` 与 `gitlab.rb` 不一致或格式不对；`service token was rejected` 是令牌失效；`must belong to an administrator` 是令牌账号不是管理员；`no administrator access` 是令牌没有管理员效力（实例开启了 Admin Mode 时，令牌要勾选 `admin_mode`）；`requests project ... is missing` 是申请工程路径错误或没有默认分支。
- **Approve 后没有执行**：确认同意的人数（发起人是管理员时含发起人）够 N，且都是未封禁的管理员；确认系统钩子的 URL 和「合并请求事件」触发器；看日志有无 `ERROR handling a system hook`。
- **普通用户打不开自己的申请**：申请工程或其所在的组不是内部可见。
- **返回 413**：超过 8 MiB 的表单无法安全检查，被直接拒绝。超过 8 MiB 的 multipart 请求（如大附件）照常流式转发，只检查各段的段头；只有段头里出现 `_method` 字段时才拒绝。
- **返回 400，日志为 Transfer-Encoding**：规则中的 `proxy_request_buffering on` 被改掉了，程序需要完整的请求体。

## 边界与已知缝隙

- **能登录服务器本机的人可以绕过**：改 `gitlab.rb`、读取密钥后直连 8932、停止服务或使用 `gitlab-rails` 都能删除。服务器登录权必须由另一方掌握，这不是本工程能解决的。
- **管理员可以凑票**：管理员能把别的账号设为管理员、重置其他管理员的密码或模拟其他管理员登录，再替他们点 Approve。本特性防的是误删和一个人的正常操作，不防蓄意绕过的管理员；这些操作在 GitLab 的管理日志和用户事件中有记录。
- **管理中心删除用户**：会连带删除该用户的个人工程，不在拦截范围内，属于管理员有意为之的操作。
- **程序自己的账号**：它是管理员，持有其令牌的人可以绕过申请直接删除；令牌只放在密钥目录中。
- **停机期间的 Approve**：不会补执行，见「日常运维」。
- **执行前一瞬间的变化**：程序算完票后会确认申请仍开着并先关闭它，再删除。如果在算票之后、关闭之前的一瞬间，有管理员恰好撤回 Approve 或关闭申请，删除仍会执行，对象进入回收站，可以恢复。
- **被拒绝的申请没清掉分支时**：程序停机期间被关闭的申请，分支还在，发起人可以重新打开它；重新打开后只是回到待审批，仍需管理员 Approve 够数才执行。
- **调整服务账号的瞬间**：程序查目标和查权限是两次调用。更换失效的令牌、调整专用账号的管理员权限或 Admin Mode 的那一瞬间，正在处理中的单个删除请求可能判断不准。需要做这类调整时，先 `docker compose stop deletion-control`，改完再启动；服务停着时删除请求返回 502，不会被放行。按期续期（新旧令牌都有效）不受影响。
- **GraphQL**：GitLab 19.6 没有删除工程或组的 mutation；升级 GitLab 后若新增，需要重新评估。
- **升级 GitLab 大版本后**：除「日常运维」中的复查外，再确认已关闭、源分支已删除的申请仍然不能重新打开。

## 设计取舍

- **为什么用 GitLab 自带的 Nginx**：规则随 `gitlab.rb` 进入配置备份，不依赖主机 Nginx；无论前面是主机 Nginx、Cloudflare Tunnel 还是 IP 直连，所有 HTTP 入口都会经过这道检查。代价是 GitLab 升级后需要复查（见「日常运维」），规则写错时 reconfigure 会失败，须按第 6 步用 `nginx -t` 验证。规则只使用 GitLab 提供的 `custom_nginx_config`、`custom_gitlab_server_config` 两个配置项，不改动 GitLab 自己的 location。
- **为什么判断放在程序里**：Nginx 只按方法和路径粗筛，凡是可能删除工程或组的请求都交给程序；程序按 Rails 的方式解析 `_method` 和路径编码，再用 GitLab API 确认目标是否存在。Nginx 的排除项只针对 GitLab 不会当作删除工程或组的路径（如 `/-/` 下的子页面、Git 传输、登录）。
- **为什么用 MR 而不是 Issue**：社区版只有 MR 有 Approve。社区版一个 MR 只能指定一位 reviewer，所以用 @ 提醒全部管理员；发起人是管理员时可以在右侧栏自己指定一位 reviewer，不影响计票。
- **为什么需要管理员令牌**：规则对所有工程和组生效，执行删除的账号须能删任何地方的对象；GitLab 也只向管理员显示谁是管理员，程序据此实时核对，无需维护名单。
