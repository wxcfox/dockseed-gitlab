# 单点登录（OIDC，可选）

本工程默认使用 GitLab 本地账号密码登录。需要接入企业的 OpenID Connect（OIDC）身份提供方（IdP）时，在实例持久化的 `/etc/gitlab/gitlab.rb` 中配置 GitLab 自带的 OIDC 登录；按本工程 ECS 存储流程部署时，对应宿主机文件是 `/srv/gitlab/config/gitlab.rb`。无需修改 Compose 或 GitLab 源码。

## 在 IdP 登记

登记一个使用授权码流程的 Web 应用：

- 登录回调：`https://gitlab.example.com/users/auth/openid_connect/callback`，与 `GITLAB_EXTERNAL_URL` 完全一致
- Scope：`openid profile email`
- 退出回调（可选）：`https://gitlab.example.com/users/sign_in`

记录 Issuer、Client ID，机密客户端还有 Client Secret。用户的邮箱须由 IdP 提供，GitLab 依此创建或关联账号。

GitLab 容器须能访问 IdP 的 Discovery、JWKS、Token 和 UserInfo 端点：

```bash
docker exec dockseed-gitlab curl -fsS https://id.example.com/.well-known/openid-configuration
```

## 配置

在 `gitlab.rb` 中加入并替换占位值：

```ruby
gitlab_rails['omniauth_allow_single_sign_on'] = ['openid_connect']
gitlab_rails['omniauth_block_auto_created_users'] = false
gitlab_rails['omniauth_providers'] = [
  {
    name: 'openid_connect',
    label: '单点登录',
    args: {
      name: 'openid_connect',
      scope: ['openid', 'profile', 'email'],
      response_type: 'code',
      issuer: 'https://id.example.com',
      discovery: true,
      uid_field: 'sub',
      pkce: true,
      client_options: {
        identifier: 'CLIENT_ID',
        secret: 'CLIENT_SECRET',
        redirect_uri: 'https://gitlab.example.com/users/auth/openid_connect/callback'
      }
    }
  }
]
```

- `issuer` 须与 Discovery 返回的值完全一致，包括末尾是否有斜杠。
- `uid_field: 'sub'` 以 IdP 的稳定用户 ID 关联 GitLab 账号。
- 已有 GitLab 账号需手动关联：用户先以原密码登录，再在 **Edit profile → Access → Password and authentication** 的 **Service sign-in** 中连接单点登录；完成后再关闭密码登录。
- 可选 `gitlab_rails['omniauth_auto_link_user'] = ['openid_connect']`：首次登录按邮箱自动关联已有账号。只在邮箱由 IdP 统一维护、不会重新分配给他人且每个邮箱只对应一个账号时使用，否则邮箱的新持有人会接管原账号及其权限。
- `omniauth_allow_single_sign_on` 与 `omniauth_block_auto_created_users = false`：新用户首次登录即自动创建且无需审核，谁能登录由 IdP 的应用授权控制。IdP 不限制访问时，将后者改为 `true`，由管理员审核新账号。
- 按组同步 GitLab 管理员或限制登录（`admin_groups`、`required_groups` 等）为付费版功能，CE 不支持。

**公开客户端**（无 Client Secret、强制 PKCE）需改为表单方式提交 Client ID，并将 Secret 留空：

```ruby
      client_auth_method: 'query',
      ...
        secret: '',
```

GitLab 默认以 HTTP Basic 认证 Token 请求，公开客户端通常不接受；非 `basic` 的值会改为在表单中提交，空 Secret 不会发送。不要填写占位 Secret，否则会被当作错误密钥拒绝。

Client Secret 保存在实例的配置卷中，请限制配置卷及备份的访问权限，不要提交到仓库。

## 验证

```bash
docker exec dockseed-gitlab /opt/gitlab/embedded/bin/ruby -c /etc/gitlab/gitlab.rb
docker exec dockseed-gitlab gitlab-ctl reconfigure
```

`reconfigure` 会重启 Puma，网页短暂不可用。登录页出现单点登录按钮后，先用一个已有账号完成关联并重新登录，确认绑定到原账号而不是新建账号：

```bash
docker exec dockseed-gitlab gitlab-rails runner "p User.find_by_username('USERNAME').identities.pluck(:provider, :extern_uid)"
```

## 关闭密码登录（可选）

确认管理员及其他用户均可通过单点登录，且 `root` 的本地密码可用（应急用）后，在 **Admin → Settings → General** 中：

- **New user account restrictions**：取消 **Allow new user accounts**，新用户由首次登录自动创建。
- **Sign-in restrictions**：取消 **Allow password authentication for the web interface**，登录页只保留单点登录。
- 同一处将 **After sign-out path** 设为 IdP 的退出地址，例如 `https://id.example.com/logout?client_id=CLIENT_ID&post_logout_redirect_uri=https%3A%2F%2Fgitlab.example.com%2Fusers%2Fsign_in`；参数名以 IdP 文档为准，退出回调须已登记。
- **Allow password authentication for Git over HTTP(S)** 可在过渡期后关闭，之后改用 SSH 或 Personal Access Token。

需要打开 GitLab 即跳转 IdP 时，在 `gitlab.rb` 中加入以下内容并重新执行 `reconfigure`：

```ruby
gitlab_rails['omniauth_auto_sign_in_with_provider'] = 'openid_connect'
```

需要显示 GitLab 自身登录页时，访问 `https://gitlab.example.com/users/sign_in?auto_sign_in=false`。

## 注意事项

- 在 IdP 停用账号只阻止之后的登录；已登录的 GitLab 会话、Personal Access Token 和 SSH Key 仍然有效。人员离职时须同时在 GitLab 中 Block 该用户。
- 关闭网页密码登录后，若 IdP 不可用，可临时恢复密码登录，故障排除后再关闭：

  ```bash
  docker exec dockseed-gitlab gitlab-rails runner "ApplicationSetting.current.update!(password_authentication_enabled_for_web: true)"
  ```

- 隔离恢复的实例通常使用不同的外部地址，与已登记的回调不一致，无法通过单点登录。验收时按上一条恢复密码登录，从 `/users/sign_in?auto_sign_in=false` 进入：管理员用 `root` 的本地密码；首次经单点登录创建的账号没有已知密码，仅在隔离实例上为验收账号设置临时密码，例如 `docker exec -it dockseed-gitlab gitlab-rake "gitlab:password:reset[USERNAME]"`。
- OIDC 配置随 `gitlab.rb` 进入配置备份；登录限制等后台设置随应用数据备份。
