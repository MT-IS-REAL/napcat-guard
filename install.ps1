# install.ps1 —— 一键装成计划任务
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -IntervalMinutes 5
#
# 它会做四件事：
#   1. 检查 config.json 和 guard.ps1 在不在
#   2. 先用当前配置空跑一次，确认判据是对的（在线就该 exit 0 且不写日志）
#   3. 注册计划任务，用 wscript 起 vbs（不闪窗）
#   4. 立刻触发一次，确认任务能跑

param(
    [int]$IntervalMinutes = 2,
    [string]$TaskName = 'NapCatGuard'
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$ps1 = Join-Path $here 'guard.ps1'
$vbs = Join-Path $here 'guard.vbs'
$cfg = Join-Path $here 'config.json'

function Fail($msg) { Write-Host "  ✗ $msg" -ForegroundColor Red; exit 1 }
function Ok($msg)   { Write-Host "  ✓ $msg" -ForegroundColor Green }

Write-Host "`n[1/4] 检查文件" -ForegroundColor Cyan
foreach ($f in @($ps1, $vbs)) {
    if (-not (Test-Path $f)) { Fail ("缺文件: " + $f) }
}
Ok 'guard.ps1 / guard.vbs 都在'

if (-not (Test-Path $cfg)) {
    $example = Join-Path $here 'config.example.json'
    if (Test-Path $example) {
        Copy-Item $example $cfg
        Write-Host "  · 已从样板复制 config.json，请先改里面的 account / napcatHome / qqExePath" -ForegroundColor Yellow
        Fail '配置还是样板里的占位值，改完再跑这个脚本'
    }
    Fail '缺 config.json'
}
Ok 'config.json 在'

$c = Get-Content $cfg -Raw -Encoding UTF8 | ConvertFrom-Json
if ($c.account -eq '123456789') { Fail 'config.json 里的 account 还是样板值' }
if (-not (Test-Path $c.napcatHome)) { Fail ('napcatHome 不存在: ' + $c.napcatHome) }
if ($c.qqExePath -and -not (Test-Path $c.qqExePath)) { Fail ('qqExePath 不存在: ' + $c.qqExePath) }
Ok ("配置读得通，盯的号是 " + $c.account)

Write-Host "`n[2/4] 空跑一次，确认判据" -ForegroundColor Cyan
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ps1
if ($LASTEXITCODE -ne 0) {
    Write-Host "  ! 空跑返回 $LASTEXITCODE —— 如果这个号现在不在线，这是正常的" -ForegroundColor Yellow
} else {
    Ok '空跑通过'
}

Write-Host "`n[3/4] 注册计划任务" -ForegroundColor Cyan
try {
    $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"' + $vbs + '"')
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
        -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) `
        -RepetitionDuration (New-TimeSpan -Days 3650)
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
    Ok ("任务 " + $TaskName + " 已注册，每 " + $IntervalMinutes + " 分钟一次")
} catch {
    Write-Host "  ! 注册失败（多半要管理员权限）：" -ForegroundColor Yellow
    Write-Host ("    " + $_.Exception.Message) -ForegroundColor Yellow
    Write-Host "    两个办法：用管理员 PowerShell 重跑这个脚本；或者把 guard.vbs 丢进启动文件夹，开机跑一次。" -ForegroundColor Yellow
}

Write-Host "`n[4/4] 立刻触发一次" -ForegroundColor Cyan
try {
    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep -Seconds 8
    $info = Get-ScheduledTaskInfo -TaskName $TaskName
    Ok ("上次运行 " + $info.LastRunTime + "，结果 " + $info.LastTaskResult)
} catch {
    Write-Host "  ! 触发失败：" + $_.Exception.Message -ForegroundColor Yellow
}

Write-Host "`n装完了。日志在: " + (Join-Path $here 'guard.log') -ForegroundColor Cyan
Write-Host "在线的时候它不写日志 —— 那是正常的，不是没跑。`n" -ForegroundColor DarkGray
