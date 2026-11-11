# D:\blog\scripts\watchdog.ps1
# 每日 09:40 由 Windows 计划任务 BlogDailyWatchdog 触发：
#   1) 检查 D:\blog\content\posts 是否已有 date: <今天(Asia/Shanghai)> 的文章
#   2) 检查 DSH 定时提醒（schedule.json）是否仍然存活
#   3) 若缺失：尝试拉起 DSH Desktop，并弹出气球告警
# 退出码：0 = 正常；1 = 缺失并已告警
# 可选参数：-TestDate yyyy-MM-dd 强制指定日期（仅用于测试告警路径）
[CmdletBinding()]
param(
    [string]$TestDate = ''
)

$ErrorActionPreference = 'Continue'

$BlogRoot      = 'D:\blog'
$PostsDir      = Join-Path $BlogRoot 'content\posts'
$LogDir        = Join-Path $BlogRoot 'logs'
$LogFile       = Join-Path $LogDir 'watchdog.log'
$ScheduleDb    = 'C:\Users\htten\AppData\Roaming\dsh-desktop\harness\storages\schedule.json'
$DshExe        = 'D:\Program Files\DSH Desktop\DSH Desktop.exe'
$ReminderTitle = '每日技术文章自动发布'

if (-not (Test-Path -LiteralPath $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

function Write-Log([string]$Message) {
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    ('{0}  {1}' -f $stamp, $Message) | Add-Content -LiteralPath $LogFile -Encoding UTF8
}

function Show-Toast([string]$Title, [string]$Text) {
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $icon = New-Object System.Windows.Forms.NotifyIcon
        $icon.Icon = [System.Drawing.SystemIcons]::Warning
        $icon.BalloonTipTitle = $Title
        $icon.BalloonTipText = $Text
        $icon.BalloonTipIcon = 'Warning'
        $icon.Visible = $true
        $icon.ShowBalloonTip(30000)
        Start-Sleep -Seconds 32
        $icon.Dispose()
    } catch {
        Write-Log ('Toast failed: ' + $_.Exception.Message)
    }
}

# --- 1) 今天的日期（Asia/Shanghai） ---
if ($TestDate) {
    $today = $TestDate
} else {
    $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById('China Standard Time')
    $today = [System.TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, $tz).ToString('yyyy-MM-dd')
}

# --- 2) 是否已有今天的文章 ---
$found = $false
if (Test-Path -LiteralPath $PostsDir) {
    foreach ($f in Get-ChildItem -LiteralPath $PostsDir -Filter '*.md' -File) {
        $head = Get-Content -LiteralPath $f.FullName -TotalCount 25 -Encoding UTF8
        if ($head -match ('^date:\s*' + [regex]::Escape($today) + '\s*$')) {
            $found = $true
            Write-Log ('OK: 找到当天文章 ' + $f.Name)
            break
        }
    }
} else {
    Write-Log ('ERROR: 目录不存在 ' + $PostsDir)
}

if ($found) { exit 0 }

Write-Log ('MISSING: 没有找到 ' + $today + ' 的文章')

# --- 3) DSH 定时提醒是否存活 ---
$reminderAlive = $false
if (Test-Path -LiteralPath $ScheduleDb) {
    try {
        $db = Get-Content -LiteralPath $ScheduleDb -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $db.tables.tasks.PSObject.Properties) {
            $t = $p.Value
            if ($t.status -eq 'active' -and ("$($t.record.title)" -like ('*' + $ReminderTitle + '*'))) {
                $reminderAlive = $true
                break
            }
        }
    } catch {
        Write-Log ('WARN: 解析 schedule.json 失败: ' + $_.Exception.Message)
    }
} else {
    Write-Log ('WARN: schedule.json 不存在: ' + $ScheduleDb)
}
if (-not $reminderAlive) {
    Write-Log 'WARN: DSH 定时提醒不存在或未激活（很可能随会话归档被删除）'
}

# --- 4) 尝试拉起 DSH Desktop ---
$proc = Get-Process -Name 'DSH Desktop' -ErrorAction SilentlyContinue
if (-not $proc) {
    if (Test-Path -LiteralPath $DshExe) {
        Write-Log 'DSH Desktop 未运行，尝试启动'
        Start-Process -FilePath $DshExe | Out-Null
    } else {
        Write-Log ('ERROR: 找不到 DSH Desktop.exe: ' + $DshExe)
    }
} else {
    Write-Log ('DSH Desktop 运行中 (PID ' + (($proc | ForEach-Object { $_.Id }) -join ',') + ')')
}

# --- 5) 告警 ---
$text = '今天 (' + $today + ') 还没有发布文章。' + "`n" +
        '提醒存活: ' + $reminderAlive + "`n" +
        '日志: ' + $LogFile
Show-Toast '每日博客未发布' $text
Write-Log '已发出告警'
exit 1
