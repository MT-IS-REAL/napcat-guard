# napcat-guard
# 2026-11-11
#
# 一句话：NapCat 掉线了就把这个号拉回来，掉到要扫码才叫人。
# 判据不是端口、不是进程数 —— 是直接问它「你现在登的是谁」。

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$cfgPath = Join-Path $here 'config.json'
$logPath = Join-Path $here 'guard.log'
$statePath = Join-Path $here 'guard-state.json'

function Write-Log([string]$msg) {
    $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $msg
    try { Add-Content -Path $logPath -Value $line -Encoding UTF8 } catch { }
}

if (-not (Test-Path $cfgPath)) {
    Write-Log 'config.json not found, exit'
    exit 1
}
$cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json

function Read-State {
    if (Test-Path $statePath) {
        try { return Get-Content $statePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    }
    return [pscustomobject]@{ lastFailAt = 0; misses = 0; notices = 0 }
}
function Write-State([int64]$lastFailAt, [int]$misses, [int]$notices) {
    @{ lastFailAt = $lastFailAt; misses = $misses; notices = $notices } |
        ConvertTo-Json | Set-Content -Path $statePath -Encoding utf8
}

# 唯一的健康判据：问接口，它现在登的是不是这个号。
function Login-Ok {
    try {
        $headers = @{}
        if ($cfg.apiToken) { $headers['Authorization'] = 'Bearer ' + $cfg.apiToken }
        $r = Invoke-RestMethod -Uri ($cfg.apiBase + '/get_login_info') -Headers $headers -TimeoutSec 8
        if ($r.status -eq 'ok' -and $r.data -and [string]$r.data.user_id -eq [string]$cfg.account) { return $true }
        return $false
    } catch {
        return $false
    }
}

function Notify-Owner([string]$text) {
    if (-not $cfg.notify -or -not $cfg.notify.enabled) { return $false }
    $st = Read-State
    $sent = 0
    if ($null -ne $st.notices) { $sent = [int]$st.notices }
    $cap = 2
    if ($null -ne $cfg.notify.maxPerOutage) { $cap = [int]$cfg.notify.maxPerOutage }
    if ($sent -ge $cap) {
        Write-Log ("notice skipped, already sent $sent for this outage")
        return $false
    }
    try {
        $headers = @{}
        if ($cfg.notify.apiToken) { $headers['Authorization'] = 'Bearer ' + $cfg.notify.apiToken }
        $body = @{ user_id = $cfg.notify.userId; message = $text } | ConvertTo-Json -Compress
        Invoke-RestMethod -Uri ($cfg.notify.apiBase + '/send_private_msg') -Method Post `
            -Headers $headers -ContentType 'application/json; charset=utf-8' `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 10 | Out-Null
        Write-State ([int64]$st.lastFailAt) ([int]$st.misses) ($sent + 1)
        return $true
    } catch {
        Write-Log ('notify failed: ' + $_.Exception.Message)
        return $false
    }
}

# 1. 在线就静默退场，不留一行日志
if (Login-Ok) {
    if ((Read-State).misses -ne 0) { Write-State 0 0 0 }
    exit 0
}

# 2. 连续掉两次才动手（一次可能只是重启中的空窗）
$state = Read-State
$misses = 1
if ($null -ne $state.misses) { $misses = [int]$state.misses + 1 }
Write-State ([int64]$state.lastFailAt) $misses ([int]$state.notices)

$need = 2
if ($null -ne $cfg.missesBeforeAction) { $need = [int]$cfg.missesBeforeAction }
if ($misses -lt $need) {
    Write-Log "down: miss $misses/$need, wait one more round"
    exit 0
}

# 3. 回退窗口：失败过就消停一阵
$now = [DateTimeOffset]::Now.ToUnixTimeSeconds()
$backoff = 900
if ($null -ne $cfg.backoffSeconds) { $backoff = [int]$cfg.backoffSeconds }
if ($state.lastFailAt -gt 0 -and ($now - $state.lastFailAt) -lt $backoff) {
    Write-Log ("backoff: last failure " + [int](($now - $state.lastFailAt) / 60) + ' min ago, skip')
    exit 0
}

# 4. 动手：只杀这个号自己的 QQ 进程
$killed = 0
if ($cfg.qqExePath) {
    Get-CimInstance Win32_Process -Filter "Name='QQ.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -eq $cfg.qqExePath } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; $killed++ }
}
Write-Log "relogin: killed $killed process(es)"

$bat = Join-Path $cfg.napcatHome 'launcher-user.bat'
if (-not (Test-Path $bat)) {
    Write-Log "launcher not found: $bat"
    Notify-Owner ('NapCat 找不到启动脚本，需要手动处理：' + $bat) | Out-Null
    Write-State $now 0 ([int]$state.notices)
    exit 1
}

# 用不带窗口的方式起，末尾 < nul 吃掉 bat 里的 pause（否则会挂出僵尸 cmd 窗口）
$cmdLine = 'cmd.exe /c "cd /d ""' + $cfg.napcatHome + '"" && launcher-user.bat ' + $cfg.account + ' < nul"'
try {
    Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmdLine } | Out-Null
    Write-Log 'launcher started'
} catch {
    Write-Log ('launcher failed: ' + $_.Exception.Message)
}

# 5. 最多等 60 秒
for ($i = 1; $i -le 12; $i++) {
    Start-Sleep -Seconds 5
    if (Login-Ok) {
        Write-Log ("recovered after " + ($i * 5) + ' s')
        Write-State 0 0 0
        exit 0
    }
}

# 6. 还不行 —— 这一步要人扫，把位置告诉他
$qr = Join-Path $cfg.napcatHome 'cache\qrcode.png'
$where = 'not found'
if (Test-Path $qr) { $where = (Get-Item $qr).LastWriteTime.ToString('HH:mm') }
Write-Log "not logged in after 60 s; QR needed (qrcode $where)"
Notify-Owner ("NapCat 掉了，自动重登没成功，需要扫码。二维码：" + $qr + "（" + $where + " 生成）") | Out-Null
Write-State $now 0 ([int]$state.notices)
exit 1
