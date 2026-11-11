# napcat-guard

NapCat（QQ 协议端）掉线自动重登的小工具。

它管一件事：**QQ 掉线了，别让人守着屏幕扫码**。

能自动处理的：进程还在、只是掉线／被踢／网络断过一阵。
处理不了的：真掉登录态（要扫码）。这时它只负责把二维码位置告诉你，不假装能替你扫。

---

## 它怎么判断「掉线」

不看进程数，也不看端口通不通 —— 那两样都可能是假象。

它直接问 NapCat 的 HTTP 接口：

```
GET http://127.0.0.1:3000/get_login_info
```

返回里的 `data.user_id` 等于配置里写的那个号，才算「在线」。返回别的号（登成小号了）、或者根本连不上，都算掉线。

这条判据是踩出来的：以前有人拿「端口在听」当健康，结果端口在听、号早就掉了，白等半天。

---

## 它怎么修

连续两次判定掉线才动手（一次可能只是重启中的空窗）。

动手顺序：

1. 只杀这个号自己的 QQ 进程（按可执行文件路径匹配），**不碰同机其他 QQ**
2. 用带账号参数的 launcher 拉起来：`launcher-user.bat <QQ号>`
3. 每 5 秒查一次，最多等 60 秒
4. 起来了就记一行日志、清空计数、静默退场

还是不行：等 15 分钟再来（避免反复杀进程把号彻底踢掉）。

---

## 配置

`config.json`：

```json
{
  "account": "123456789",
  "napcatHome": "C:\\path\\to\\napcat",
  "qqExePath": "C:\\path\\to\\QQ.exe",
  "apiBase": "http://127.0.0.1:3000",
  "apiToken": "your-api-token",
  "missesBeforeAction": 2,
  "backoffSeconds": 900,
  "notify": {
    "enabled": false,
    "apiBase": "http://127.0.0.1:3000",
    "apiToken": "same-or-other",
    "userId": "your-own-qq",
    "maxPerOutage": 2
  }
}
```

`notify` 是可选的：真掉到要扫码那一步，给你自己发一条私聊，附二维码文件的路径。

`maxPerOutage` 是「同一次故障最多提醒几回」。设 2 是有理由的：一天掉五回，你要是收五条一样的消息，很快就会把它关掉。

---

## 装

一、把 `guard.ps1` 放进任意目录，同目录放 `config.json`。
二、先手动跑一次：`powershell -NoProfile -ExecutionPolicy Bypass -File guard.ps1`
三、确认日志里出现「login ok, nothing to do」。
四、挂成计划任务，每两分钟一次。**用 wscript 起 vbs，不要直接挂 powershell**，否则会闪黑窗：

```
Register-ScheduledTask -TaskName 'NapCatGuard' `
  -Action (New-ScheduledTaskAction -Execute 'wscript.exe' -Argument '"<路径>\guard.vbs"') `
  -Trigger (New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes 2) `
    -RepetitionDuration (New-TimeSpan -Days 3650))
```

---

## 日志

`guard.log`，一行一次判定。只记「掉线」「动作」「恢复」，在线的时候不写 —— 两分钟一条「还好」，日志一天就几十兆，没人看。

---

## 边界

- 只能救「会话还在、只是掉线」的情况。真掉登录态必须人扫。
- 杀的进程按可执行文件路径匹配，所以同一个 QQ 装了两份（比如主号、小号各一份）时不会互相误伤。这一点比 `taskkill /im QQ.exe` 安全得多。
- 不处理「NapCat 自己起不来」这类问题（插件没装、配置坏了），那种要看 NapCat 自己的日志。
