# 邮件（可选）

本工程不要求邮件配置。若不接入邮件，请不要启用注册邮箱强制确认；密码重置和邮件通知等功能也需要邮件服务。

需要邮件时，在实例持久化的 `/etc/gitlab/gitlab.rb` 中配置 SMTP；按本工程 ECS 存储流程部署时，对应宿主机文件是 `/srv/gitlab/config/gitlab.rb`。Mac 可用 `docker cp` 将文件拷到仓库外的临时目录编辑，再拷回容器。无需修改 Compose 或 GitLab 源码。

## 配置

向邮件服务商确认服务器地址、端口、加密方式、账号和客户端密码。以下是 **465 端口／隐式 TLS** 的通用示例，在 `gitlab.rb` 中加入并替换占位值：

```ruby
gitlab_rails['smtp_enable'] = true
gitlab_rails['smtp_address'] = 'smtp.example.com'
gitlab_rails['smtp_port'] = 465
gitlab_rails['smtp_domain'] = 'example.com'
gitlab_rails['smtp_authentication'] = 'login'
gitlab_rails['smtp_tls'] = true
gitlab_rails['smtp_enable_starttls_auto'] = false
gitlab_rails['smtp_openssl_verify_mode'] = 'peer'
gitlab_rails['smtp_user_name'] = 'gitlab@example.com'
gitlab_rails['smtp_password'] = 'CLIENT_APP_PASSWORD'
gitlab_rails['gitlab_email_from'] = 'gitlab@example.com'
```

使用 **587 端口／STARTTLS** 时，将 `smtp_port` 设为 `587`、`smtp_tls` 设为 `false`、`smtp_enable_starttls_auto` 设为 `true`。其他服务商设置见 [GitLab 官方 SMTP 示例](https://docs.gitlab.com/omnibus/settings/smtp/#example-configurations)。

此示例把密码保存在实例的配置卷中，请限制配置卷及备份的访问权限，不要提交到仓库。需要加密存储时，可按 [GitLab 官方说明](https://docs.gitlab.com/omnibus/settings/smtp/#using-encrypted-credentials)改用加密 SMTP 凭据，并从上面的配置中删除 `smtp_user_name`、`smtp_password` 两行。本工程不单独备份该加密凭据文件；采用此方式时请另行保留，或在恢复后重新写入并测试发信。

## 验证

```bash
docker exec dockseed-gitlab /opt/gitlab/embedded/bin/ruby -c /etc/gitlab/gitlab.rb
docker exec dockseed-gitlab gitlab-ctl reconfigure
docker exec dockseed-gitlab gitlab-rails runner 'puts ActionMailer::Base.delivery_method'
docker exec dockseed-gitlab gitlab-rails runner "Notify.test_email('you@example.com', 'GitLab SMTP test', 'test').deliver_now"
```

确认配置语法通过、发送方式为 `smtp`，并且测试邮件实际到达收件箱；之后再启用注册邮箱强制确认。
