# rapp 数据目录

rapp 的所有数据都在这个目录里。

## 子目录

- `shared/`：所有设备共用，放 app 配置 `apps.json` 和项目、常用 `workspace.json`。进 git。
- `devices/<设备id>/`：每台设备一份，只由这台设备写，放 `device.json`（这台是什么）和 `gui.json`（界面偏好）。进 git。
- `agent/`：agent 的上下文。rapp 只建目录和 `agent/README.md`，里面的内容归你和 agent。进 git。
- `clipboard/`：钉住的文字条目，一条一个 `<时间>-<短标题>.md`。进 git。
- `files/`：二进制，不进 git。`files/transfers/` 是收发的文件，`files/clipboard/` 是钉住的图片和文件。
- `local/`：本机私有，不进 git。口令、密钥、`service.json`、`hosts.json` 等机密只在这里。

## git

- 进 git 的：`shared/`、`devices/`、`agent/`、`clipboard/`、本文件和 `.gitignore`。
- 不进 git 的：`files/` 和 `local/`。机密只在 `local/`，不会进 git。
- 要同步文字，自己执行 `git remote add origin <地址>`。rapp 每分钟提交一次，有 remote 就推和拉。
- 第二台设备：先 `git clone <地址> ~/rapp`，再启动 rapp。
- 取消固定只删文件，git 历史里还在。

## 同步二进制

`files/` 里的二进制可以用 Syncthing、iCloud 云盘、坚果云等文件夹同步工具，把它们指向 `files` 这个文件夹。

## 其他

- 日志：macOS 在 `~/Library/Logs/rapp`；Linux 在 `$XDG_STATE_HOME/rapp`（默认 `~/.local/state/rapp`）。设置 `RAPP_HOME` 时在 `$RAPP_HOME/local/logs`，`RAPP_LOG_DIR` 可单独指定。
- 这个目录的位置可以在 rapp 设置页的「数据目录」里改。
