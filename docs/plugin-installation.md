# 插件安装与恢复

`make install-plugin` 先构建、安装应用，再通过应用的 `install-plugin --source PATH` 安装本仓库的 `codex-usage-monitor@personal` 插件。下面的事务只覆盖插件阶段；插件失败不会回退此前安装的应用。

## 安装顺序

1. 读取源插件的 `.codex-plugin/plugin.json` 和 `.mcp.json`，校验名称、版本和本仓库的 MCP 配置。已有 marketplace 必须是合法 JSON 对象，名称为 `personal`，`plugins` 为无重复名称的对象数组。损坏、不可读、结构错误或不同名称的文件会报错，保留原文件。
2. 获取 `~/plugins/.codex-usage-monitor-install.lock` 的非阻塞文件锁，避免两次本应用安装互相覆盖。将插件复制到同目录的私有暂存目录，复验后添加唯一 `+codex.<UUID>` 版本后缀；源文件不变。生成新 marketplace，保留其他条目、未知字段和已有目标插件的 policy。
3. 备份旧插件、marketplace、当前 Codex 配置及目标插件缓存。全部备份完成后读取已安装列表，再替换文件，按需执行 `codex plugin remove`，最后执行 `codex plugin add`。查询失败或响应格式不正确会停止；卸载失败不会继续安装。
4. 命令成功后清理暂存目录。任意安装步骤失败时，恢复受影响的备份；首次安装失败则删除本次新建的目标文件。原本不存在的空父目录和互斥锁文件可能保留。

子进程继承当前环境，并明确使用选定的 `CODEX_HOME`（默认 `~/.codex`），工作目录为用户目录，避免继承仓库的项目配置。每条命令最多运行 30 秒；超时先终止，再强制结束并等待退出，之后才回滚。输出写入临时文件并轮询检查；任一输出超过 8 MiB 会失败，错误详情最多保留 stdout/stderr 各 64 KiB。

## 恢复范围

| 路径 | 处理方式 |
| --- | --- |
| `~/plugins/codex-usage-monitor` | 暂存替换，失败恢复旧目录 |
| `~/.agents/plugins/marketplace.json` | 失败恢复原始字节与权限 |
| `$CODEX_HOME/config.toml` | 失败恢复整个原文件，包括注释和插件配置 |
| `$CODEX_HOME/plugins/cache/personal/codex-usage-monitor` | 失败恢复所有原版本，移除部分安装结果 |

目录和缓存布局依据本机 CLI 核对；marketplace 的相对路径以包含 `.agents` 的根目录为基准，见[官方插件管理说明](https://learn.chatgpt.com/docs/enterprise/plugin-management)。插件配置字段见[官方配置参考](https://learn.chatgpt.com/docs/config-file/config-reference)。这些内部缓存路径可能随 Codex 版本变化，升级 CLI 后应复核。

安装器拒绝替换目标路径或插件内容中的符号链接，也拒绝源目录与目标、配置互相包含的布局。安装期间避免用其他 Codex 进程安装插件或编辑 `config.toml`：本应用的锁不约束其他配置写入者，回滚会恢复完整配置快照。查询期间检测到 marketplace 被编辑，会停止并保留新编辑的内容。

## 回滚不完整时

若权限或目录变化导致某个路径恢复失败，其余路径仍会尝试恢复。错误会同时说明安装失败、回滚失败及 `Recovery files:` 位置；备份保留在 `~/plugins/.codex-usage-monitor-install-<UUID>/`，权限为 `0700`。其中 `recovery.json` 列出每个原路径与 `backup-N` 的对应关系，`absent` 表示安装前不存在。

先修复报错中的权限或目录问题，再按 `recovery.json` 恢复对应路径；确认恢复后再删除备份。目录包含 Codex 配置副本，不应提交到仓库。进程被强制杀死或机器断电不执行自动回滚，已完成的备份会留在上述目录，需按同样方式检查恢复；不承诺多文件的崩溃原子性。
