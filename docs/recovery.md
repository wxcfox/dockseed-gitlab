# 备份与人工恢复

本版提供自动备份和 Compose 内的启动检查，不管理磁盘或云资源。恢复由管理员在停机窗口逐步完成，恢复的是选定备份点；允许数小时停机，不承诺零数据损失、高可用或自动切换。以下命令须先替换示例值，**任一步失败即停止后续操作**。

## 从 Mac 迁往 ECS 的顺序

1. **准备新机**：确认 ECS 与数据盘对应关系，在目标 ECS 挂载 ESSD，安装 Docker/Compose，克隆本工程；先不启动空 GitLab 对外服务。
2. **准备 OSS**：私有 Bucket、加密、版本控制及限前缀权限；ECS 使用 RAM 角色，Mac 使用独立凭证配置，避免覆盖个人 OSS 配置。
3. **备份旧机**：核对版本、平台及 Registry 备份配置，生成、上传并下载校验一份完整备份。
4. **隔离恢复**：按场景三恢复配置、Secrets 和应用数据；核对登录、仓库、Issue/MR、权限、Registry 标签及实际镜像拉取。
5. **正式切换**：若演练期间旧机仍有写入，停写后重新备份恢复；停用旧机和入口，再开放新机 IP/域名。
6. **建立日常备份**：在新机生成并验证完整备份，再启用 cron。独立保留一份已恢复成功的样本后，才启用 OSS 到期清理。

首次上线与灾难恢复使用同一套恢复步骤；差别是前者从仍可用的 Mac 取最终备份，后者选择 OSS 中已存在的完整备份。

## 获取与更新工程

安装好 Git、Docker Engine 和 Compose v2 后，在新机克隆公开仓库：

```bash
git clone https://github.com/wxcfox/dockseed-gitlab.git /opt/dockseed-gitlab
cd /opt/dockseed-gitlab
cp .env.example .env
chmod 600 .env
```

更新工程前检查 `git status` 和 `git diff`；工作区干净时使用 `git pull --ff-only`。有本地改动时先核对并保留，不强制覆盖。更新工程不会自动升级或重启 GitLab。

Web/SSH 的 IP 访问配置见 [README](../README.md#ecs-通过-ip-访问)。目标镜像必须与备份同精确版本和 CE/EE 类型，平台按目标机器选择。

## 存储与首次部署

**Mac 不需要 ESSD**，继续按 README 使用 Docker Desktop 的普通命名卷，无需运行下面的 Linux 挂载命令。首次空卷须显式初始化，已有数据不重新初始化。一份 Compose 保留三个固定 external volume：`dockseed-gitlab-config` → `/etc/gitlab`、`dockseed-gitlab-logs` → `/var/log/gitlab`、`dockseed-gitlab-data` → `/var/opt/gitlab`。

ECS 首次部署前，在控制台核对实例名称/ID、数据盘 ID 及其挂载实例，再与 `lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINTS` 对照；不要仅按容量判断数据盘。由管理员为确认的新空 ESSD 准备文件系统并配置按 UUID 持久挂载到 `/srv/gitlab`；已有数据盘不得格式化。记录实际 UUID，新盘重新登记。使用本机 Docker daemon，禁止将这些命令指向远程 Docker context。

```bash
lsblk --fs
findmnt --mountpoint /srv/gitlab -o TARGET,SOURCE,FSTYPE,UUID
```

人工确认它是预期 ESSD，UUID 正确，再在 Linux root 终端执行。正常容器启动前要求 Secrets 与 PostgreSQL 的 `PG_VERSION` 文件非空，缺任一项即拒绝启动；自动重启同样经过检查。**这不验证物理磁盘 UUID 或数据完整性**，管理员仍须核对挂载，备份脚本也不验证磁盘身份。不要在 GitLab 运行时卸载数据盘，不修改 Docker data-root 或其他容器配置。

```bash
mountpoint -q /srv/gitlab &&
  install -d -m 0700 /srv/gitlab/config /srv/gitlab/logs /srv/gitlab/data /srv/gitlab/backup-work
docker volume ls --format '{{.Name}}'
```

已有同名卷先用 `docker volume inspect 卷名` 核对；参数正确则复用，不符则停止并由管理员处理，**不得删除、重建或覆盖已有卷**。仅对确认不存在的卷执行相应命令：[Docker local volume](https://docs.docker.com/engine/storage/volumes/#how-mounting-block-devices-works)

```bash
docker volume create --driver local --opt type=none --opt o=bind --opt device=/srv/gitlab/config dockseed-gitlab-config
docker volume create --driver local --opt type=none --opt o=bind --opt device=/srv/gitlab/logs dockseed-gitlab-logs
docker volume create --driver local --opt type=none --opt o=bind --opt device=/srv/gitlab/data dockseed-gitlab-data
```

确认三个卷均为 local driver，选项分别为 `type=none`、`o=bind` 和对应目录的 `device`，再按 README 配置 `.env`（权限 `0600`，只供 Compose 解析，不能 `source`）。用 `uname -m` 确认 ECS 架构：`x86_64` 设置 `GITLAB_PLATFORM=linux/amd64`，`aarch64` 设置 `GITLAB_PLATFORM=linux/arm64`。

首次 ECS 初始化先按 README 的[一次性初始化](../README.md#一次性初始化)确认正常容器不存在或已停止，包括曾因空卷反复重启的容器；再执行下条命令，等待 `healthy` **及本次启动的 `gitlab Reconfigured!` 日志**并停止初始化容器，成功后才正常启动。恢复场景先还原配置；已有 `PG_VERSION` 时初始化会被拒绝，不得删除它绕过检查，初始化期间不得启动正常容器。

```bash
mountpoint -q /srv/gitlab && docker compose config --quiet &&
  docker compose run --rm --no-deps --name dockseed-gitlab-init -d -e GITLAB_ALLOW_INITIALIZATION=true gitlab
```

## OSS 与凭证

仅 `ops/transfer.sh` 需要官方 ossutil 2.x 及其凭证；本地备份无需 OSS。管理员在云端完成以下设置，脚本不会修改 Bucket 策略或保留规则：

- 私有 Bucket、阻止公共访问、默认 **SSE-OSS 托管服务端加密**、版本控制；使用 HTTPS，无客户端加密。备份含实际 `.env` 和 Secrets，下载目录和访问身份都须保护。
- ECS 优先使用官方 ossutil **2.2+** 的 `Ali-EcsRamRole` 凭证方式（支持 IMDSv2）；Mac 使用当前用户自行配置的凭证。凭证不进仓库，region 与 endpoint 一致。[ossutil 配置](https://www.alibabacloud.com/help/en/oss/developer-reference/ossutil-overview/)
- 日常身份仅操作指定前缀，按需授予 `oss:PutObject`、`oss:ListParts`、`oss:AbortMultipartUpload`、`oss:GetObject`；人工列目录另需限定前缀的 List 权限。不授予删除对象、删除历史版本或修改 Bucket 配置的权限。[上传权限](https://www.alibabacloud.com/help/en/oss/developer-reference/cp-upload-file)
- 每次使用时间戳＋随机后缀的独立目录，不覆盖旧对象、不删除远端文件。[版本控制说明](https://www.alibabacloud.com/help/en/oss/user-guide/overview-78/)
- 日常保留可从当前对象 30 天、非当前版本再保留 30 天开始，规则仅匹配日常前缀。**首次真实恢复验收并保留独立样本后，再启用生命周期清理**。至少一套已恢复成功的完整备份须保留在无自动到期规则的独立前缀或 Bucket，日常身份不得写入该位置；长期没有新备份时，daily 下的备份可能全部过期。

ECS 绑定角色后，执行用户的 `~/.ossutilconfig` 示例（权限 `0600`，region 按实际填写）：

```ini
[default]
mode = Ali-EcsRamRole
region = cn-shanghai
```

Mac 首次使用先运行 `ossutil version` 确认是 2.x，再运行 `umask 077` 和 `ossutil config`。已有个人配置时，为这次部署填写独立的绝对路径（如 `/Users/你的用户名/.ossutil-gitlab`），不覆盖原文件。填写 RAM 用户的完整 AccessKey ID、Secret、Bucket 地域和 HTTPS Endpoint；不能填写控制台中带 `***` 的脱敏值。不要将密钥写在命令行或项目 `.env` 中。

上传、下载前显式选择配置文件；以下变量仅影响当前终端，定时任务须另行设置。ECS 以 root 执行时通常使用 `/root/.ossutilconfig`，其他用户改为自己的路径。脚本直接沿用 ossutil 的配置方式，无需新增凭证参数：

```bash
export OSSUTIL_CONFIG_FILE="$HOME/.ossutil-gitlab" # 改为实际配置文件的绝对路径
export OSSUTIL_PROFILE=default
```

若提示 `Credentials is null or empty` 或 `region must be set in sign version 4`，先核对**实际执行用户**能否读取上述文件、所选 profile 及 region/凭证是否完整；交互终端成功不代表 cron 使用了相同配置。`AccessDenied` 检查授权及前缀；`PublicEndpointForbidden` 按 OSS 官方说明配置自定义 HTTPS 域名，不能靠扩大权限解决。[ossutil 配置](https://help.aliyun.com/zh/oss/developer-reference/ossutil-overview/)、[公网域名限制](https://help.aliyun.com/zh/oss/publicendpointforbidden-error-when-upload-object)

## 本地备份

`ops/backup.sh` 依赖 Docker/Compose v2、Git、Bash、tar、gzip 和 SHA-256 等常见工具，不依赖 ossutil。脚本非交互调用 `gitlab-backup create` 与 `gitlab-ctl backup-etc`，经容器路径复制本次文件。要求 GitLab 使用默认 `backup_path=/var/opt/gitlab/backups` 和 `backup_keep_time=0`；备份期间不升级、改配置、重建容器或另行执行备份绕过锁。[GitLab 备份](https://docs.gitlab.com/administration/backup_restore/backup_gitlab/)

### Registry 元数据库

**镜像层文件和元数据库必须一起备份。** 仅有 `registry.tar.gz` 可能恢复不出仓库标签。以下适用于本工程当前的单机 GitLab 19.3；未使用元数据库的旧版本仍按其官方说明处理。

在容器 `/etc/gitlab/gitlab.rb` 中配置以下内容（ECS 对应 `/srv/gitlab/config/gitlab.rb`，Mac 可用 `docker exec -it dockseed-gitlab editor /etc/gitlab/gitlab.rb` 编辑）：

```ruby
gitlab_rails['backup_role'] = true
gitlab_rails['backup_registry_password'] = '<独立随机密码>'
gitlab_rails['restore_registry_password'] = '<另一个独立随机密码>'
```

两个密码各生成一次并持久保存；已有设置不重复追加、不在定时任务里轮换。使用默认官方角色 `registry_backup` 和 `registry_restore`，不要拿 Registry 业务账号代替。暂停备份、等待当前任务结束，在维护窗口执行 `docker exec dockseed-gitlab gitlab-ctl reconfigure`，成功后再备份。这些设置与 Secrets 一起进入 `config.tar`，无需再新增环境变量或独立凭证文件。[官方配置](https://docs.gitlab.com/omnibus/settings/backups/#container-registry-metadata-database-backup-credentials)

脚本读取本机 Registry 配置及数据标记，识别 `prefer`、字符串 `true` 和布尔 `true`；使用元数据库时，缺备份/恢复角色配置就提前失败。所有备份都校验主数据库转储，使用元数据库时另校验 `db/registry_database.sql.gz`。检测到 Registry 配置或数据标记时，无论是否使用元数据库，都要求包含 `registry.tar.gz`；否则不生成 `LOCAL_COMPLETE`。数据库转储会完整读取并解压校验，增加相应磁盘读取和 CPU 开销。清单记录 `registry_database=true/false`；旧清单无此字段时不能推断为未启用，应检查归档及原实例。

如果旧备份缺元数据库，且原机仍可用，应先补好配置再生成完整备份；原机和盘均已丢失时，不能靠镜像层文件承诺找回标签。恢复前还原含角色设置的 `gitlab.rb`，初始化会重新创建凭证，官方 `gitlab-backup restore` 负责恢复元数据库；不要另写 PostgreSQL 数据目录复制流程。

### 执行备份

工作目录须已存在、归执行用户所有且权限为 `0700`；Mac 可用 `$HOME/gitlab-backup-work`，ECS 优先放 `/srv/gitlab/backup-work`。`BACKUP_ESTIMATE_KB` 是保守的完整导出及暂存预算，不能只按压缩包大小填写。开始前只检查宿主工作目录和容器 `/var/opt/gitlab/backups`，各需空闲 **4 倍预算＋1 GiB**，容纳导出、归档和复制；容器 `/tmp` 不套用这份预算。20 GiB 预算（`20971520`）对应 81 GiB 空闲；按上面的 ECS 布局，两处都位于 ESSD，这不是系统盘容量要求。Mac 须兼顾宿主工作目录和 Docker 虚拟磁盘的空间。

脚本只检查工作目录可写，不校验或修改其属主和 `0700` 权限，须由管理员设置。使用拥有该仓库且能访问 Docker 的用户执行，避免 Git 的仓库属主检查拒绝访问。

空间不足会输出目录、所需及剩余容量并退出；复制前按实际文件大小复查。归档超过预算只记录警告，实际空间充足则继续，之后须调高预算。检查不预留空间，也不能保证备份期间其他写入不会用满磁盘。早期检查失败可能尚未创建本次目录，手工执行看终端，定时任务看下文当日日志。

在工程目录执行以下 Mac 示例，ECS 使用同一脚本，只替换工作目录。首次创建目录前设置 `umask`，不修改已有目录的权限。参数与脚本放在**同一行**，避免分开赋值未 `export` 导致脚本读不到：

```bash
umask 077
mkdir -p "$HOME/gitlab-backup-work"
BACKUP_WORK_DIR="$HOME/gitlab-backup-work" BACKUP_ESTIMATE_KB=20971520 bash ops/backup.sh
```

只有成功时 stdout 才输出完整目录的绝对路径，阶段日志走 stderr。看到 `success; local backup ready` 后保存最后一行路径，供上传使用；不必重新执行备份。完整目录含四个备份文件：应用原始 ID 的 `_gitlab_backup.tar`、`config.tar`、`deployment.tar`、`manifest.txt`，以及 `SHA256SUMS`、`LOCAL_COMPLETE` 和私有 `operations.log`。成功后仅清理本次容器临时备份并释放锁，本地备份保留。

配置包必须含 gitlab.rb 与 Secrets；部署包仅包含 `docker-compose.yml`、真实 `.env`、实际注入的 `runtime-omnibus.rb`、README、两个脚本和恢复说明。清单记录精确 GitLab 版本、CE/EE、镜像标识/平台、备份 ID/文件名/时间及工程提交。`.env` 不能作为 Shell 脚本 `source`。

**这不是整台服务器的备份。** `compose.override.yml`、其他 Compose 覆盖文件、systemd/cron、磁盘挂载、反向代理、DNS、TLS 和网络配置均不在部署包中；`runtime-omnibus.rb` 也不包含端口、网络或卷的覆盖设置。使用这些配置时，另存环境说明及必要文件，并确保 GitLab 不可用时仍可取得；凭据另行保护，不提交到本工程。

环境覆盖文件用于调整端口、网络等部署设置，不得覆盖启动 `command`、`GITLAB_ALLOW_INITIALIZATION` 或三个数据卷的绑定；修改后用 `docker compose config` 私下核对合并结果（可能含密码，不贴到公开日志）。

配置、版本、Git 提交和部署资料检查在加锁前完成，这些检查失败不会留下容器锁。已有锁时直接拒绝执行，通常不再创建本地目录；两个任务同时争锁时，未取得锁的一方可能留下诊断目录。

取得锁后失败会保留锁和当次资料，后续备份暂停，直至人工排查。先停用计划，检查当次 `operations.log`、主机进程和 `docker top dockseed-gitlab`；不能仅因进程名匹配不到就自动删锁，断开的 `docker exec` 可能仍在备份。确认相关进程全部结束并修复错误后，若锁仍存在，才释放固定锁：

```bash
docker exec dockseed-gitlab rmdir /var/opt/gitlab/backups/.dockseed-backup.lock
```

仅处理本次明确列出的残留文件；`rmdir` 失败则继续检查，不递归强删、不清空 backups、不用 Docker prune。保留信息不代表可以无限重试堆积文件。

## 上传、下载与定时任务

`ops/transfer.sh` 不依赖 Docker，只负责传输和校验。本地备份成功后，把以下目录替换为刚才输出的完整绝对路径，并填写自己的 Bucket 和 Endpoint：

```bash
OSS_DESTINATION=oss://your-private-bucket/gitlab/daily OSS_ENDPOINT=https://oss-cn-shanghai.aliyuncs.com bash ops/transfer.sh upload /绝对路径/本次备份目录
```

上传先校验本地完整性，再检查 ossutil 退出码并以官方 [ossutil hash crc64](https://www.alibabacloud.com/help/en/oss/developer-reference/hash-calculate-crc64-or-md5) 核对远端内容，不以大小或 ETag 代替。四个备份文件及 `SHA256SUMS` 全部通过后才最后上传远端 `COMPLETE`。**本地、远端完成标记均不表示恢复演练通过。** 日志不上传；默认保留本地全部文件。显式追加 `--remove-local` 才在远端全部成功后删除本次已上传文件、`SHA256SUMS` 和 `LOCAL_COMPLETE`，日志保留。

上传失败时，本地完整备份仍在；cron 不会自动重传旧目录，持续失败会积占 ESSD 空间。先暂停计划、修复上传问题，再用原参数重传同一目录；无需重新备份 GitLab 或操作容器锁。需要上传成功后回收本次文件时执行：

```bash
OSS_DESTINATION=oss://your-private-bucket/gitlab/daily OSS_ENDPOINT=https://oss-cn-shanghai.aliyuncs.com bash ops/transfer.sh upload /绝对路径/待重传的备份目录 --remove-local
```

看到 `upload complete` 表示上传及校验通过，日志会显示本次 OSS 完整目录。逐份处理积压并确认最近完整备份后再恢复计划。`--remove-local` 会保留日志、`checkpoints/`、`ossutil-output/`；定期人工检查，仅清理已确认上传完整且无任务使用的明确目录及旧日志，不能仅凭缺少 `LOCAL_COMPLETE` 判断可删。

首次上传后，将这份备份下载到**尚不存在的新目录**验证；不需要 `OSS_DESTINATION`，也不要提前创建目标目录：

```bash
OSS_ENDPOINT=https://oss-cn-shanghai.aliyuncs.com bash ops/transfer.sh download oss://your-private-bucket/gitlab/daily/明确备份ID "$HOME/gitlab-recovery-check"
```

下载前通过官方 [head-object](https://help.aliyun.com/zh/oss/developer-reference/head-object) 获取六个必要文件的大小，要求空闲空间至少为文件总量＋1 GiB；仅需已有的 `oss:GetObject` 权限。大小只用于容量检查，不能替代内容校验，也不保证下载期间空间不会被其他任务占用。看到 `download complete; SHA-256 verified` 表示下载及内容校验通过，脚本才生成 `LOCAL_COMPLETE`；它不会解包或执行恢复。失败保留部分文件但无本地完成标记，下次使用新目录。**真实恢复演练必须使用独立环境，不能覆盖当前业务实例。**

传输日志保存在本次目录的 `transfer.log`。强制终止进程可能留下 `.transfer.lock`；确认对应传输进程已结束后，才用 `rmdir /本次目录/.transfer.lock` 释放，不删除备份文件。

首次手工备份、上传及隔离恢复验收后，可在 ECS Linux 的 crontab 串联每 6 小时备份与上传；确认已有 `flock`（`command -v flock`）。锁覆盖整段备份和上传，取锁失败就退出而不排队；结束后自动释放，`.cron.lock` 文件保留，无需删除。Mac 手工备份不依赖 `flock`。

以下放入**执行备份用户的 `crontab -e`**，不是 `/etc/cron.d` 文件；后者还需要执行用户列。示例按 root 的配置路径填写，其他用户须修改。先用同一用户和以下配置完成手工上传；变量行与任务行一起保存，cron 不继承交互终端的 `export`。

请放在 crontab 末尾，并先核对已有任务：这些变量影响其后的所有任务，示例 `PATH` 不含 `/usr/sbin`、`/sbin`，`MAILTO=""` 关闭后续任务的邮件，`OSS_ENDPOINT` 也会影响其他 ossutil 命令：

```cron
# 放在 crontab 末尾；以下环境变量对后续所有任务生效。
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
MAILTO=""
OSSUTIL_CONFIG_FILE=/root/.ossutilconfig
OSSUTIL_PROFILE=default
OSS_DESTINATION=oss://your-private-bucket/gitlab/daily
OSS_ENDPOINT=https://oss-cn-shanghai.aliyuncs.com
BACKUP_WORK_DIR=/srv/gitlab/backup-work
BACKUP_ESTIMATE_KB=20971520
0 */6 * * * umask 077; ( date -u; flock -n 9 || { echo 'scheduled backup already running or lock unavailable; no backup started'; exit 1; }; cd /opt/dockseed-gitlab && backup_dir=$(./ops/backup.sh) && ./ops/transfer.sh upload "$backup_dir" --remove-local ) 9>> "$BACKUP_WORK_DIR/.cron.lock" >> "$BACKUP_WORK_DIR/scheduled-backup-$(date +\%Y\%m\%d).log" 2>&1
```

本工程不提供主动通知，无需配置邮件或通知接口。日志按任务启动时的服务器本地日期保存为 `scheduled-backup-YYYYMMDD.log`，如 `scheduled-backup-20260916.log`，同日追加、跨日新建；任务跨过午夜仍写入启动日的文件。内容包含 UTC 开始时间、阶段结果和早期错误。目录须已存在且可写，新文件权限为 `0600`，历史日志不自动删除。**crontab 中的 `%` 必须写成 `\%`**。查看今天的日志（当天尚未执行时文件不存在）：

```bash
tail -n 80 "/srv/gitlab/backup-work/scheduled-backup-$(date +%Y%m%d).log"
```

到点后仍没有当天日志时，先检查 `BACKUP_WORK_DIR` 是否存在、执行用户是否可写，再检查 cron 是否运行；重定向失败可能尚未留下日志，而 `MAILTO=""` 不会发送错误邮件。

`upload complete` 表示该次已上传并校验；只有本地备份成功还不算 OSS 备份成功。详细日志按输出路径查看本次 `operations.log` 或 `transfer.log`。**失败不会主动提醒负责人**，须定期查看日志，并在 OSS 确认最近完整备份，才能发现任务漏执行或整台 ECS 宕机。六小时只是频率，耗时、失败和漏执行均影响恢复点；演练机不发布到生产备份前缀。

## 恢复前共同要求

恢复或升级前暂停备份计划，确认当前任务已结束；有失败锁则先排查。恢复使用独立 Docker daemon，避免固定容器/卷名与原实例冲突。在恢复工程的 `.env` 持久设置 `GITLAB_RESTART_POLICY=no`，并关闭其他自动启动入口，避免 `compose up` 重建后恢复默认自启。新数据卷先经一次性初始化并停止该容器，再创建正常容器。恢复期间只用 `compose start` 启动已创建容器；中途重启后重新核对磁盘和恢复进度，保持隔离再继续。初始化授权不得写入 `.env` 或日常 Compose。

演练须在独立机器或隔离环境进行，先下载镜像和备份，再隔离入站及出站：不接生产域名/Tunnel，不连接生产 Runner，不触发生产 CI、邮件、Webhook 或外部存储写入。仅更改域名不足以阻止后台请求。生产切换前必须停用旧实例及其备份计划，避免两份实例同时接收业务。

### 场景一：正常重启

ECS 先核对 ESSD 挂载及 UUID，再按 README 的[日常操作](../README.md#日常操作)执行重启：暂停计划、等待备份及上传结束、检查锁、先停 Sidekiq 再停容器。锁不存在不能代替确认任务已结束；检查失败就停止排查，不删锁后强行重启。

等待 `healthy` 并验证登录。Mac 启动 Docker Desktop 后沿用原卷；异常断电无法保证上述停止顺序。

### 场景二：更换 ECS，原 ESSD 可用

停旧入口、备份计划和旧实例；旧机不可控时先在云端隔离。安全卸载原 ESSD 并挂到新 ECS，保留文件系统和数据，核对原 UUID。恢复相同精确版本/CE 或 EE 的 Compose、`.env` 和镜像，保留本版启动检查，确认盘上 Secrets；按首次配置创建新机卷绑定元数据，已有卷不覆盖。保持隔离，人工确认挂载后按场景三的 create/start 命令启动；**不初始化、不执行应用 restore**，验收后才切入口。

### 场景三：ECS 与 ESSD 均不可用，从 OSS 恢复

准备新 ECS＋ESSD，登记新 UUID，按首次配置创建空目录和卷。使用新的工程副本 `/opt/dockseed-gitlab`；不要覆盖现有业务工程或数据。以下为新机 Linux root 终端步骤。

```bash
umask 077
export OSSUTIL_CONFIG_FILE=/root/.ossutilconfig OSSUTIL_PROFILE=default # 改为实际配置文件和 profile
RESTORE_PREFIX=oss://your-private-bucket/gitlab/daily/填写明确的完整备份目录
cd /opt/dockseed-gitlab && mountpoint -q /srv/gitlab &&
  OSS_ENDPOINT=https://oss-cn-shanghai.aliyuncs.com \
  ./ops/transfer.sh download "$RESTORE_PREFIX" /srv/gitlab/recovery &&
  cd /srv/gitlab/recovery
```

`/srv/gitlab/recovery` 须尚不存在，不要提前创建；明确选择备份点，不盲选 latest。脚本先取远端 `COMPLETE`，下载固定文件并重新校验 SHA-256，成功才生成本地 `LOCAL_COMPLETE`。任何失败即停止恢复，下次换新目录并调整后续路径；校验不能代替对备份来源及访问身份的信任。

核对 `manifest.txt` 的 `backup_id`、`application_file`、版本、CE/EE、镜像/平台及提交号。目标须为**相同精确版本及 CE/EE 类型**；EE 备份需相应修改镜像仓库，不能只改 tag。跨 arm64/amd64 时选择同版本/类型的目标平台镜像并另行验收，不复用另一平台镜像 ID。[恢复前提](https://docs.gitlab.com/administration/backup_restore/restore_gitlab/#restore-prerequisites)

```bash
tar -tf deployment.tar
tar -tf config.tar
# 确认部署包为相对工程路径，配置包仅在 etc/gitlab 或 /etc/gitlab 下，均无 .. 越界路径。
install -d -m 0700 deployment config-extract &&
  tar -xpf deployment.tar -C deployment && tar -xpf config.tar -C config-extract &&
  test -s config-extract/etc/gitlab/gitlab.rb && test -s config-extract/etc/gitlab/gitlab-secrets.json
```

只解包可信且已校验的归档；tar 去掉官方配置包的前导 `/`，**不用 `-P`**。按清单提交准备新工程副本后，复制实际部署文件：

```bash
install -m 0644 deployment/docker-compose.yml /opt/dockseed-gitlab/docker-compose.yml &&
  install -m 0600 deployment/.env /opt/dockseed-gitlab/.env
```

私下对照 `deployment/runtime-omnibus.rb` 还原实际注入配置：它不一定已写入 gitlab.rb，原 shell 覆盖须落实到新配置。调整精确镜像、本机平台和隔离设置，不输出 Secrets。复制 `.env` 后重新确认 `GITLAB_RESTART_POLICY=no`。若备份 Compose 较旧，只迁入业务配置，保留本版启动检查、可配置的重启策略及固定 `GITLAB_ALLOW_INITIALIZATION: "false"`。下段先核对挂载输出与登记的新 UUID，确认后才向空 config 目录复制。

```bash
findmnt --mountpoint /srv/gitlab -o TARGET,SOURCE,FSTYPE,UUID
mountpoint -q /srv/gitlab &&
  cp -a /srv/gitlab/recovery/config-extract/etc/gitlab/. /srv/gitlab/config/ &&
  chmod 0600 /srv/gitlab/config/gitlab-secrets.json &&
  cd /opt/dockseed-gitlab && docker compose config --quiet && docker compose pull gitlab
```

使用 Registry 元数据库时，先核对应用归档包含 `db/registry_database.sql.gz`、`registry.tar.gz`，并按上文恢复备份/恢复角色配置；缺失时停止排查，不能靠跳过 Registry 宣布完整恢复。

配置、校验及镜像准备全部成功，且隔离已落实后，先按「存储与首次部署」中带 `mountpoint` 检查的命令初始化新数据库；保留已恢复的配置和 Secrets。按 README 等待 `healthy` **及本次启动的 `gitlab Reconfigured!` 日志**并停止初始化容器，确认它已自动删除后，再创建正常容器（`.env` 中已禁用自动重启）：[Compose create](https://docs.docker.com/reference/cli/docker/compose/create/)

```bash
mountpoint -q /srv/gitlab && docker compose create gitlab &&
  test "$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' dockseed-gitlab)" = no &&
  docker compose start gitlab
```

上面的重启策略检查不通过就不会启动；先修正 `.env` 与 Compose，重新执行该步骤。启动后等待健康与本次配置完成：

```bash
docker inspect --format '{{.HostConfig.RestartPolicy.Name}} {{.State.Health.Status}}' dockseed-gitlab
docker logs --since "$(docker inspect --format '{{.State.StartedAt}}' dockseed-gitlab)" dockseed-gitlab 2>&1 | grep -F 'gitlab Reconfigured!'
```

预期为 `no healthy` 及完成日志；缺一项就停止后续操作，不能在 Chef 配置过程仍运行时停止 Puma/Registry 或执行恢复。用 `docker exec dockseed-gitlab dpkg-query --show gitlab-ce` 核对清单的精确包版本（EE 改 `gitlab-ee`）。

以下 restore 会覆盖目标数据库，仅在上述隔离新实例执行；从清单填写原始 ID，不含 `_gitlab_backup.tar`：

```bash
BACKUP_ID=填写manifest中的backup_id
docker cp "/srv/gitlab/recovery/${BACKUP_ID}_gitlab_backup.tar" "dockseed-gitlab:/var/opt/gitlab/backups/${BACKUP_ID}_gitlab_backup.tar" &&
  docker exec dockseed-gitlab chown git:git "/var/opt/gitlab/backups/${BACKUP_ID}_gitlab_backup.tar" &&
  docker exec dockseed-gitlab gitlab-ctl stop puma &&
  docker exec -e SVWAIT=600 dockseed-gitlab gitlab-ctl stop sidekiq
```

若启用了 Registry，还须停止它，避免恢复期间读写镜像文件或元数据库：

```bash
docker exec dockseed-gitlab gitlab-ctl stop registry
```

确认上述全部成功，检查 `docker exec dockseed-gitlab gitlab-ctl status`：Puma、Sidekiq 以及启用的 Registry 应已停止，PostgreSQL、Redis 等必要服务仍运行。`status` 可因有意停止的服务返回非零；其他异常须先处理。再按官方流程恢复，保留人工确认提示；恢复后的容器重启会重新启动这些服务：

```bash
docker exec -it dockseed-gitlab gitlab-backup restore "BACKUP=$BACKUP_ID" &&
  docker exec dockseed-gitlab gitlab-ctl reconfigure &&
  docker compose exec -T -e SVWAIT=600 gitlab gitlab-ctl stop sidekiq &&
  docker compose stop --timeout 600 gitlab &&
  mountpoint -q /srv/gitlab && docker compose start gitlab
```

恢复失败时保持隔离，不跳过数据库或 Secrets，不将半恢复实例接回入口。[官方 Docker 恢复](https://docs.gitlab.com/administration/backup_restore/restore_gitlab/#restore-for-docker-image-installations)

### 场景四：Mac GitLab 迁入 ECS＋ESSD

先在隔离 ECS 演练，包括可能的架构转换。正式迁移时暂停备份计划、Runner 和业务写入，等待现有任务结束；保持 GitLab 运行，先生成本地备份，再上传到明确迁移前缀。上传完整后先停 Sidekiq，再执行 `docker update --restart=no dockseed-gitlab` 并停止旧容器，停用旧入口及备份计划；旧机 `.env` 同样设为 `GITLAB_RESTART_POLICY=no`，不再执行 `compose up/start`。保留旧数据卷供核对，禁止新旧实例同时接收写入。按场景三下载并恢复到 ECS，验收后切入口；新机开始接收写入后，不能直接切回旧备份点。

## 验收与恢复范围

### 隔离恢复验收

首次上线前必须完成一次独立真实恢复。等待健康后执行以下检查，并验证管理员/普通用户登录、关键仓库已知提交、Issue/MR、权限及 Secrets/CI 变量解密。团队使用 HTTPS 和 SSH 时，两种方式分别完成 Clone、Fetch、测试分支 Push 与回读，最后删除测试分支和临时凭证，不修改业务分支。Registry 须核对关键仓库的标签与摘要并实际拉取镜像，不能只数镜像层文件。实际使用的 CI、Registry、LFS、上传和 Packages 须逐项验收；使用隔离 Runner 和测试目标。

```bash
docker compose ps
docker exec dockseed-gitlab gitlab-rake gitlab:check SANITIZE=true
docker exec dockseed-gitlab gitlab-rake gitlab:doctor:secrets
```

备份范围包括仓库、用户、权限、Issue/MR、数据库及实际启用的相关本机文件数据。在线逻辑备份不是全部组件同一瞬间的快照，不保证运行中的 CI Job、Redis 队列原样恢复。Runner 本机配置与 Tunnel 另行恢复；Registry 文件/元数据库及外部对象存储须按实际版本和部署核对，不能默认全部包含在应用 tar 中。[GitLab 备份范围](https://docs.gitlab.com/administration/backup_restore/backup_gitlab/#data-not-included-in-backup)

记录备份目录、版本/平台、恢复耗时和验收结果，单独保留通过的完整样本。**演练通过不等于正式入口已可用**；演练机不执行以下切换。

### 正式切换验收

确认旧实例及其备份计划已停用、最终备份已恢复，再逐项完成：

1. 核对并移除仅用于演练的配置，恢复正常网络与 Sidekiq；邮件、Webhook、Runner 等按实际使用情况恢复，未配置的功能不要算作验收通过。
2. 恢复日常启动方式。由 Docker 管理时，将 `.env` 中 `GITLAB_RESTART_POLICY` 改回 `unless-stopped`，执行 `docker compose up -d gitlab`。若宿主机服务负责挂载检查和自动拉起，则保留 `no` 并按该服务的流程启动，避免 Docker 绕过挂载检查。本工程不提供该服务，须由部署方实现，并在独立验收环境实测 Docker 重启和整机重启后能否自动拉起 GitLab。
3. 确认健康后切换入口、按需解除隔离；从员工实际使用的网络复测正式地址的登录及 HTTPS/SSH Git 操作，不能用服务器本机检查代替。
4. 在新机生成、上传并下载校验一份备份，再启用新机的备份计划。记录最近一次成功备份、访问方式和启停方法。

## 本地测试

本地可对 `ops/backup.sh`、`ops/transfer.sh` 及 `tests/` 下三个测试脚本分别运行 `bash -n` 和已安装的 ShellCheck，再执行 `bash tests/backup.sh`、`bash tests/transfer.sh`、`bash tests/startup.sh`；测试仅用临时目录和 Mock；已安装 Compose CLI 时，启动测试另用示例参数验证配置渲染，不连接 Docker daemon、不操作容器或卷。真实 ESSD 挂载、OSS 传输/权限/保留规则和完整 GitLab 恢复仍须在独立环境验证，Mock 或正常停启不能代替恢复演练。
