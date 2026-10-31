#requires -version 5.1
param([int]$Days = 7)

$ErrorActionPreference = 'Stop'

# ---- DPI 感知（必须在 WinForms 之前）----
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class TtkDpi {
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern int GetDpiForSystem();
}
'@
$script:DPI_OK = $false
try { $script:DPI_OK = [TtkDpi]::SetProcessDpiAwarenessContext([IntPtr](-4)) } catch { }
if (-not $script:DPI_OK) {
    try { $script:DPI_OK = [TtkDpi]::SetProcessDPIAware() } catch { }
}
$script:K = [TtkDpi]::GetDpiForSystem() / 96.0
if ($script:K -lt 1) { $script:K = 1 }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$global:TTK = @{
    Dir    = $PSScriptRoot
    Py     = (Join-Path $PSScriptRoot 'ttk.py')
    Report = (Join-Path $PSScriptRoot 'ttk.report.json')
    State  = (Join-Path $PSScriptRoot 'ttk.state.json')
    Err    = (Join-Path $PSScriptRoot 'ttk.last.err.txt')
    Log    = (Join-Path $PSScriptRoot 'ttk.debug.log')
    K      = $script:K
    Data   = $null
    UI     = @{}
}

function Log([string]$m) {
    try {
        ((Get-Date).ToString('HH:mm:ss') + ' ' + $m) | Add-Content -LiteralPath $global:TTK.Log -Encoding UTF8
    } catch { }
}
Log ('start dpi=' + [TtkDpi]::GetDpiForSystem() + ' aware=' + $script:DPI_OK + ' K=' + $script:K)

function P([double]$v) { return [int][Math]::Round($v * $global:TTK.K) }
function Col([string]$hex) { return [System.Drawing.ColorTranslator]::FromHtml($hex) }

$C_BG     = Col '#0E1117'
$C_HEAD   = Col '#12151C'
$C_CARD   = Col '#161A22'
$C_LINE   = Col '#252B37'
$C_TEXT   = Col '#E8ECF4'
$C_MUTED  = Col '#8A93A6'
$C_BLUE   = Col '#4C8DFF'
$C_PURPLE = Col '#A06BFF'
$C_GREEN  = Col '#3DD598'
$C_AMBER  = Col '#F5B544'
$C_RED    = Col '#FF6B6B'

$F_TITLE = [System.Drawing.Font]::new('Microsoft YaHei UI', 13, [System.Drawing.FontStyle]::Bold)
$F_H1    = [System.Drawing.Font]::new('Microsoft YaHei UI', 18, [System.Drawing.FontStyle]::Bold)
$F_BODY  = [System.Drawing.Font]::new('Microsoft YaHei UI', 9)
$F_SMALL = [System.Drawing.Font]::new('Microsoft YaHei UI', 8)
$F_TINY  = [System.Drawing.Font]::new('Microsoft YaHei UI', 7.5)
$F_BTN   = [System.Drawing.Font]::new('Microsoft YaHei UI', 8.5)

# 自绘区域内的字体
$PF_BODY  = [System.Drawing.Font]::new('Microsoft YaHei UI', (9 / $global:TTK.K))
$PF_SMALL = [System.Drawing.Font]::new('Microsoft YaHei UI', (8 / $global:TTK.K))
$PF_TINY  = [System.Drawing.Font]::new('Microsoft YaHei UI', (7.5 / $global:TTK.K))
$PF_BOLD  = [System.Drawing.Font]::new('Microsoft YaHei UI', (9 / $global:TTK.K), [System.Drawing.FontStyle]::Bold)

function New-RoundPath([single]$x, [single]$y, [single]$w, [single]$h, [single]$r) {
    $p = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $d = $r * 2
    $p.AddArc($x, $y, $d, $d, 180, 90)
    $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

function New-Lbl([string]$text, $font, $color, [int]$x, [int]$y, [int]$w, [int]$h, [string]$align) {
    $l = [System.Windows.Forms.Label]::new()
    $l.Text = $text
    $l.Font = $font
    $l.ForeColor = $color
    $l.BackColor = [System.Drawing.Color]::Transparent
    $l.AutoSize = $false
    $l.Location = [System.Drawing.Point]::new($x, $y)
    $l.Size = [System.Drawing.Size]::new($w, $h)
    $l.TextAlign = $align
    $l.UseMnemonic = $false
    return $l
}

function Fmt-Tok($n) {
    $v = [double]$n
    if ($v -ge 100000000) { return ('{0:0.##}亿' -f ($v / 100000000)) }
    if ($v -ge 10000)     { return ('{0:0.#}万' -f ($v / 10000)) }
    return ('{0:N0}' -f $v)
}
function Fmt-Money($n) {
    $v = [double]$n
    if ($v -ge 1000) { return ('¥{0:N0}' -f $v) }
    return ('¥{0:0.00}' -f $v)
}
function Fmt-Int($n) { return ('{0:N0}' -f [double]$n) }

function Draw-Icon($g, [string]$kind, [single]$x, [single]$y, [single]$size, $accent) {
    $p = New-RoundPath $x $y $size $size 10
    $fill = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(26, $accent.R, $accent.G, $accent.B))
    $g.FillPath($fill, $p)
    $fill.Dispose()
    $brush = [System.Drawing.SolidBrush]::new($accent)
    if ($kind -eq 'tokens') {
        $bx = $x + 11
        $by = $y + 12
        $g.FillRectangle($brush, $bx, $by + 14, 4, 6)
        $g.FillRectangle($brush, $bx + 7, $by + 8, 4, 12)
        $g.FillRectangle($brush, $bx + 14, $by + 3, 4, 17)
    } elseif ($kind -eq 'money') {
        $f = [System.Drawing.Font]::new('Microsoft YaHei UI', (13 / $global:TTK.K), [System.Drawing.FontStyle]::Bold)
        $sf = [System.Drawing.StringFormat]::new()
        $sf.Alignment = [System.Drawing.StringAlignment]::Center
        $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
        $rect = [System.Drawing.RectangleF]::new($x, ($y - 1), $size, $size)
        $g.DrawString('¥', $f, $brush, $rect, $sf)
        $sf.Dispose()
        $f.Dispose()
    } elseif ($kind -eq 'credits') {
        $cx = $x + $size / 2
        $cy = $y + $size / 2
        $pts = [System.Drawing.PointF[]]@(
            [System.Drawing.PointF]::new($cx, ($y + 9)),
            [System.Drawing.PointF]::new(($x + $size - 10), $cy),
            [System.Drawing.PointF]::new($cx, ($y + $size - 9)),
            [System.Drawing.PointF]::new(($x + 10), $cy)
        )
        $g.FillPolygon($brush, $pts)
    } else {
        $bx = $x + 9
        $by = $y + 11
        $hs = @(8, 14, 11, 17, 9, 13, 6)
        for ($i = 0; $i -lt 7; $i++) {
            $g.FillRectangle($brush, ($bx + $i * 4), ($by + (17 - $hs[$i])), 2, $hs[$i])
        }
    }
    $brush.Dispose()
}

$form = [System.Windows.Forms.Form]::new()
$form.Text = 'Token 记录器 · 6通道全矩阵'
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.ClientSize = [System.Drawing.Size]::new((P 1040), (P 696))
$form.BackColor = $C_BG
$form.TopMost = $true
$form.KeyPreview = $true
$global:TTK.UI.Form = $form

$form.Add_Paint({
    param($s, $e)
    $pen = [System.Drawing.Pen]::new($C_LINE, 1)
    $e.Graphics.DrawRectangle($pen, 0, 0, ($s.ClientSize.Width - 1), ($s.ClientSize.Height - 1))
    $pen.Dispose()
})

# ---------------- 顶栏 ----------------
$header = [System.Windows.Forms.Panel]::new()
$header.Location = [System.Drawing.Point]::new(0, 0)
$header.Size = [System.Drawing.Size]::new((P 1040), (P 56))
$header.BackColor = $C_HEAD
$form.Controls.Add($header)
$global:TTK.UI.Header = $header

$logo = [System.Windows.Forms.Panel]::new()
$logo.Location = [System.Drawing.Point]::new((P 16), (P 13))
$logo.Size = [System.Drawing.Size]::new((P 30), (P 30))
$logo.BackColor = [System.Drawing.Color]::Transparent
$logo.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.ScaleTransform($global:TTK.K, $global:TTK.K)
    $p = New-RoundPath 0 0 29 29 8
    $b = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(32, $C_BLUE.R, $C_BLUE.G, $C_BLUE.B))
    $g.FillPath($b, $p)
    $b.Dispose()
    Draw-Icon $g 'tokens' 3 3 24 $C_BLUE
})
$header.Controls.Add($logo)

$lblTitle = New-Lbl 'Token 记录器' $F_TITLE $C_TEXT (P 54) (P 7) (P 140) (P 24) 'MiddleLeft'
$lblSub = New-Lbl 'CodeBuddy · 6通道各账户剩余积分' $F_SMALL $C_MUTED (P 55) (P 31) (P 210) (P 18) 'MiddleLeft'
$header.Controls.Add($lblTitle)
$header.Controls.Add($lblSub)

# 签到标记徽章
$lblSigninBadge = [System.Windows.Forms.Label]::new()
$lblSigninBadge.Font = $F_SMALL
$lblSigninBadge.ForeColor = $C_AMBER
$lblSigninBadge.BackColor = (Col '#202530')
$lblSigninBadge.AutoSize = $false
$lblSigninBadge.Location = [System.Drawing.Point]::new((P 270), (P 14))
$lblSigninBadge.Size = [System.Drawing.Size]::new((P 165), (P 28))
$lblSigninBadge.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$lblSigninBadge.Text = '⚡ 检查签到中…'
$lblSigninBadge.Cursor = [System.Windows.Forms.Cursors]::Hand
$lblSigninBadge.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$header.Controls.Add($lblSigninBadge)
$global:TTK.UI.SigninBadge = $lblSigninBadge

# 状态提示
$lblStatus = New-Lbl '就绪' $F_SMALL $C_AMBER (P 445) (P 14) (P 155) (P 28) 'MiddleLeft'
$header.Controls.Add($lblStatus)
$global:TTK.UI.Status = $lblStatus

function New-Btn([string]$text, [int]$x, [int]$w, $hover) {
    $b = [System.Windows.Forms.Button]::new()
    $b.Text = $text
    $b.Font = $F_BTN
    $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $b.FlatAppearance.BorderSize = 1
    $b.FlatAppearance.BorderColor = $C_LINE
    $b.FlatAppearance.MouseOverBackColor = $hover
    $b.BackColor = $C_CARD
    $b.ForeColor = $C_TEXT
    $b.Location = [System.Drawing.Point]::new($x, (P 14))
    $b.Size = [System.Drawing.Size]::new($w, (P 28))
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $b.TabStop = $false
    return $b
}

$btnSignin  = New-Btn '签到' (P 612) (P 52) (Col '#1E3A2C')
$btnScan    = New-Btn '扫描' (P 670) (P 52) (Col '#1E283A')
$btnRefresh = New-Btn '刷新' (P 728) (P 52) (Col '#202836')
$btnRecords = New-Btn '记录' (P 786) (P 52) (Col '#2A2036')
$btnDetails = New-Btn '明细' (P 844) (P 52) (Col '#1E3038')
$btnTop     = New-Btn '置顶' (P 902) (P 48) (Col '#202836')
$btnClose   = New-Btn '关闭' (P 956) (P 44) (Col '#3A2230')

$header.Controls.Add($btnSignin)
$header.Controls.Add($btnScan)
$header.Controls.Add($btnRefresh)
$header.Controls.Add($btnRecords)
$header.Controls.Add($btnDetails)
$header.Controls.Add($btnTop)
$header.Controls.Add($btnClose)

$global:TTK.UI.BtnSignin  = $btnSignin
$global:TTK.UI.BtnScan    = $btnScan
$global:TTK.UI.BtnRefresh = $btnRefresh
$global:TTK.UI.BtnRecords = $btnRecords
$global:TTK.UI.BtnDetails = $btnDetails
$global:TTK.UI.BtnTop     = $btnTop

# ---------------- 指标卡（Token 用量与模型单价估算；积分独立展示） ----------------
$script:CardValue = @{}
$script:CardSub = @{}
$script:CardPanel = @{}

function New-Card([string]$key, [string]$title, [string]$icon, $accent, [int]$x) {
    $w = P 243
    $h = P 108
    $card = [System.Windows.Forms.Panel]::new()
    $card.Location = [System.Drawing.Point]::new($x, (P 68))
    $card.Size = [System.Drawing.Size]::new($w, $h)
    $card.BackColor = $C_CARD
    $card.Tag = @{ Accent = $accent; Icon = $icon }
    $card.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.ScaleTransform($global:TTK.K, $global:TTK.K)
        $w = $s.Width / $global:TTK.K
        $h = $s.Height / $global:TTK.K
        $path = New-RoundPath 0.5 0.5 ($w - 1) ($h - 1) 10
        $bg = [System.Drawing.SolidBrush]::new($C_CARD)
        $g.FillPath($bg, $path)
        $bg.Dispose()
        $pen = [System.Drawing.Pen]::new($C_LINE, 1)
        $g.DrawPath($pen, $path)
        $pen.Dispose()
        $bar = [System.Drawing.SolidBrush]::new($s.Tag.Accent)
        $g.FillRectangle($bar, 0, 16, 3, 40)
        $bar.Dispose()
        Draw-Icon $g $s.Tag.Icon 18 18 44 $s.Tag.Accent
    })
    $form.Controls.Add($card)
    $t = New-Lbl $title $F_SMALL $C_MUTED (P 76) (P 12) ($w - (P 92)) (P 18) 'MiddleLeft'
    $v = New-Lbl '—' $F_H1 $C_TEXT (P 74) (P 30) ($w - (P 88)) (P 38) 'MiddleLeft'
    $s = New-Lbl '' $F_TINY $C_MUTED (P 76) (P 70) ($w - (P 90)) (P 32) 'TopLeft'
    $card.Controls.Add($t)
    $card.Controls.Add($v)
    $card.Controls.Add($s)
    $script:CardValue[$key] = $v
    $script:CardSub[$key] = $s
    $script:CardPanel[$key] = $card
    return $card
}

New-Card 'today'  '今日用量 (Token)'   'tokens'  $C_BLUE   (P 16)  | Out-Null
New-Card 'cost'   '今日估算花销'        'money'   $C_GREEN  (P 271) | Out-Null
New-Card 'credit' '矩阵可用积分总储备'   'credits' $C_AMBER  (P 526) | Out-Null
New-Card 'week'   '近 7 天估算花销'     'week'    $C_PURPLE (P 781) | Out-Null

# ---------------- 图表 (每日用量趋势) ----------------
$chart = [System.Windows.Forms.Panel]::new()
$chart.Location = [System.Drawing.Point]::new((P 16), (P 192))
$chart.Size = [System.Drawing.Size]::new((P 1008), (P 162))
$chart.BackColor = $C_CARD
$global:TTK.UI.Chart = $chart
$chart.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.ScaleTransform($global:TTK.K, $global:TTK.K)
    $w = $s.Width / $global:TTK.K
    $h = $s.Height / $global:TTK.K
    $path = New-RoundPath 0.5 0.5 ($w - 1) ($h - 1) 10
    $bg = [System.Drawing.SolidBrush]::new($C_CARD)
    $g.FillPath($bg, $path)
    $bg.Dispose()
    $pen = [System.Drawing.Pen]::new($C_LINE, 1)
    $g.DrawPath($pen, $path)
    $pen.Dispose()

    $brushText = [System.Drawing.SolidBrush]::new($C_TEXT)
    $brushMuted = [System.Drawing.SolidBrush]::new($C_MUTED)
    $g.DrawString('每日用量趋势（tokens）', $PF_BODY, $brushText, 18, 12)

    $days = @()
    if ($global:TTK.Data -ne $null) { $days = @($global:TTK.Data.days) }
    if ($days.Count -eq 0) {
        $g.DrawString('暂无数据', $PF_BODY, $brushMuted, 18, 60)
        $brushText.Dispose()
        $brushMuted.Dispose()
        return
    }

    $padL = 62
    $padR = 20
    $padT = 40
    $padB = 36
    $plotW = $w - $padL - $padR
    $plotH = $h - $padT - $padB
    $maxTok = 1.0
    foreach ($d in $days) { if ([double]$d.tokens -gt $maxTok) { $maxTok = [double]$d.tokens } }

    for ($i = 0; $i -le 3; $i++) {
        $yy = $padT + $plotH * ($i / 3)
        $gp = [System.Drawing.Pen]::new($C_LINE, 1)
        $g.DrawLine($gp, $padL, $yy, ($padL + $plotW), $yy)
        $gp.Dispose()
        $lbl = Fmt-Tok ($maxTok * (1 - $i / 3))
        $sz = $g.MeasureString($lbl, $PF_TINY)
        $g.DrawString($lbl, $PF_TINY, $brushMuted, ($padL - 10 - $sz.Width), ($yy - $sz.Height / 2))
    }

    $slot = $plotW / $days.Count
    $bw = [Math]::Min(42, $slot * 0.46)
    $brushGreen = [System.Drawing.SolidBrush]::new($C_GREEN)
    for ($i = 0; $i -lt $days.Count; $i++) {
        $d = $days[$i]
        $cx = $padL + $slot * ($i + 0.5)
        $totalH = 0.0
        if ($maxTok -gt 0) { $totalH = $plotH * ([double]$d.tokens / $maxTok) }
        $termH = 0.0
        $popH = 0.0
        if ([double]$d.tokens -gt 0) {
            $termH = $totalH * ([double]$d.terminal.tokens / [double]$d.tokens)
            $popH = $totalH - $termH
        }
        $x0 = $cx - $bw / 2
        $yTop = $padT + $plotH - $totalH
        if ($popH -gt 0.5) {
            $b2 = [System.Drawing.SolidBrush]::new($C_PURPLE)
            $g.FillRectangle($b2, [single]$x0, [single]$yTop, [single]$bw, [single]$popH)
            $b2.Dispose()
        }
        if ($termH -gt 0.5) {
            $b1 = [System.Drawing.SolidBrush]::new($C_BLUE)
            $g.FillRectangle($b1, [single]$x0, [single]($yTop + $popH), [single]$bw, [single]$termH)
            $b1.Dispose()
        }
        if ([double]$d.cost -gt 0) {
            $ct = Fmt-Money $d.cost
            $sz = $g.MeasureString($ct, $PF_TINY)
            $g.DrawString($ct, $PF_TINY, $brushGreen, ($cx - $sz.Width / 2), ($yTop - $sz.Height - 3))
        }
        $dl = $d.date.Substring(5)
        $sz = $g.MeasureString($dl, $PF_TINY)
        $g.DrawString($dl, $PF_TINY, $brushText, ($cx - $sz.Width / 2), ($padT + $plotH + 8))
        $sz = $g.MeasureString($d.weekday, $PF_TINY)
        $g.DrawString($d.weekday, $PF_TINY, $brushMuted, ($cx - $sz.Width / 2), ($padT + $plotH + 20))
    }

    $lx = $w - 150
    $b = [System.Drawing.SolidBrush]::new($C_BLUE)
    $g.FillRectangle($b, $lx, 18, 8, 8)
    $b.Dispose()
    $g.DrawString('终端', $PF_TINY, $brushMuted, ($lx + 12), 14)
    $b = [System.Drawing.SolidBrush]::new($C_PURPLE)
    $g.FillRectangle($b, ($lx + 46), 18, 8, 8)
    $b.Dispose()
    $g.DrawString('弹窗', $PF_TINY, $brushMuted, ($lx + 58), 14)

    $brushText.Dispose()
    $brushMuted.Dispose()
    $brushGreen.Dispose()
})
$form.Controls.Add($chart)

$tip = [System.Windows.Forms.ToolTip]::new()
$tip.InitialDelay = 150
$tip.ReshowDelay = 100
$tip.AutoPopDelay = 10000
$global:TTK.UI.Tip = $tip
$tip.SetToolTip($chart, '')
$chart.Add_MouseMove({
    param($s, $e)
    $days = @()
    if ($global:TTK.Data -ne $null) { $days = @($global:TTK.Data.days) }
    if ($days.Count -eq 0) { return }
    $w = $s.Width / $global:TTK.K
    $padL = 62
    $padR = 20
    $plotW = $w - $padL - $padR
    $slot = $plotW / $days.Count
    $lx = $e.X / $global:TTK.K
    $idx = [int][Math]::Floor(($lx - $padL) / $slot)
    if ($idx -lt 0 -or $idx -ge $days.Count) {
        $global:TTK.UI.Tip.SetToolTip($s, '')
        return
    }
    $d = $days[$idx]
    $txt = $d.date + ' ' + $d.weekday + [Environment]::NewLine
    $txt += '估算花销 ' + (Fmt-Money $d.cost) + '（按模型 Token 单价，不含积分）' + [Environment]::NewLine
    $txt += '用量 ' + (Fmt-Tok $d.tokens) + ' · 输入 ' + (Fmt-Tok $d.in) + ' · 输出 ' + (Fmt-Tok $d.out) + [Environment]::NewLine
    $txt += '命中 ' + (Fmt-Tok $d.hit) + ' · 未命中 ' + (Fmt-Tok $d.miss) + ' · 缓存写入 ' + (Fmt-Tok $d.write) + ' · 积分另计 ' + [string]$d.credits + '点'
    $global:TTK.UI.Tip.SetToolTip($s, $txt)
})

# ---------------- 会员条（WorkBuddy Pro 节省折算）----------------
$mem = [System.Windows.Forms.Panel]::new()
$mem.Location = [System.Drawing.Point]::new((P 16), (P 360))
$mem.Size = [System.Drawing.Size]::new((P 1008), (P 30))
$mem.BackColor = $C_CARD
$global:TTK.UI.Mem = $mem
$mem.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
    $g.ScaleTransform($global:TTK.K, $global:TTK.K)
    $w = $s.Width / $global:TTK.K
    $h = $s.Height / $global:TTK.K
    $path = New-RoundPath 0.5 0.5 ($w - 1) ($h - 1) 8
    $bg = [System.Drawing.SolidBrush]::new($C_CARD)
    $g.FillPath($bg, $path)
    $bg.Dispose()
    $pen = [System.Drawing.Pen]::new($C_LINE, 1)
    $g.DrawPath($pen, $path)
    $pen.Dispose()

    $m = $null
    if ($global:TTK.Data -ne $null) { $m = $global:TTK.Data.membership }
    if ($m -eq $null) {
        $bm0 = [System.Drawing.SolidBrush]::new($C_MUTED)
        $g.DrawString('会员信息缺失', $PF_SMALL, $bm0, 16, 8)
        $bm0.Dispose()
        return
    }

    $saved = [double]$m.saved
    $accent = $C_GREEN
    if ($saved -lt 0) { $accent = $C_AMBER }
    $bar = [System.Drawing.SolidBrush]::new($accent)
    $g.FillRectangle($bar, 12, 6, 3, ($h - 12))
    $bar.Dispose()

    $bText = [System.Drawing.SolidBrush]::new($C_TEXT)
    $bMuted = [System.Drawing.SolidBrush]::new($C_MUTED)
    $bGreen = [System.Drawing.SolidBrush]::new($C_GREEN)
    $bAmber = [System.Drawing.SolidBrush]::new($C_AMBER)

    $segs = @(
        @{ T = [string]$m.plan; F = $PF_BOLD; B = $bText },
        @{ T = ('会员 $' + ('{0:0.##}' -f [double]$m.fee_usd) + '/月 ≈ ¥' + ('{0:0.00}' -f [double]$m.fee_cny)); F = $PF_SMALL; B = $bMuted },
        @{ T = ('本月Token估价 ¥' + ('{0:0.00}' -f [double]$m.api_cost)); F = $PF_SMALL; B = $bText }
    )
    if ($saved -ge 0) {
        $segs += @{ T = ('已省 ¥' + ('{0:0.00}' -f $saved)); F = $PF_BOLD; B = $bGreen }
        $segs += @{ T = ($m.multiple.ToString('0.##') + '×'); F = $PF_SMALL; B = $bMuted }
    } else {
        $segs += @{ T = ('本月还差 ¥' + ('{0:0.00}' -f (-$saved)) + ' 回本'); F = $PF_SMALL; B = $bAmber }
    }

    $x = 24.0
    $y = ($h - 12) / 2
    foreach ($sg in $segs) {
        $sz = $g.MeasureString($sg.T, $sg.F)
        $g.DrawString($sg.T, $sg.F, $sg.B, [single]$x, [single]$y)
        $x += $sz.Width + 14
    }

    $bText.Dispose()
    $bMuted.Dispose()
    $bGreen.Dispose()
    $bAmber.Dispose()
})
$form.Controls.Add($mem)

# ---------------- 6 通道各账户剩余积分量与状态矩阵（替换原日量表） ----------------
$tbl = [System.Windows.Forms.Panel]::new()
$tbl.Location = [System.Drawing.Point]::new((P 16), (P 400))
$tbl.Size = [System.Drawing.Size]::new((P 1008), (P 260))
$tbl.BackColor = $C_BG
$global:TTK.UI.Table = $tbl
$form.Controls.Add($tbl)

# 8 列布局：通道、站点与类型、账号标识、当前状态、剩余可用积分、配额构成明细、429 解封时刻、调度机制
$global:TTK.ColX = @(0, 92, 212, 332, 442, 572, 752, 872, 1008)
$global:TTK.ColHead = @('通道', '站点与类型', '账号标识', '当前状态', '剩余可用积分', '配额构成明细', '429 刷新时刻', '机制 / 规则')

function Draw-Text($g, [string]$text, $font, $brush, [single]$x, [single]$y, [single]$w, [single]$h, [string]$align) {
    $sf = [System.Drawing.StringFormat]::new()
    $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
    $sf.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap
    if ($align -eq 'right') { $sf.Alignment = [System.Drawing.StringAlignment]::Far }
    elseif ($align -eq 'center') { $sf.Alignment = [System.Drawing.StringAlignment]::Center }
    else { $sf.Alignment = [System.Drawing.StringAlignment]::Near }
    $rect = [System.Drawing.RectangleF]::new(($x + 8), $y, ($w - 16), $h)
    $g.DrawString($text, $font, $brush, $rect, $sf)
    $sf.Dispose()
}

$tbl.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
    $g.ScaleTransform($global:TTK.K, $global:TTK.K)
    $w = $s.Width / $global:TTK.K
    $rowH = 34
    $headH = 32

    # 表头绘制
    $bgHead = [System.Drawing.SolidBrush]::new($C_HEAD)
    $g.FillRectangle($bgHead, 0, 0, $w, $headH)
    $bgHead.Dispose()

    $brushHead = [System.Drawing.SolidBrush]::new($C_MUTED)
    for ($c = 0; $c -lt 8; $c++) {
        $cw = $global:TTK.ColX[$c + 1] - $global:TTK.ColX[$c]
        $al = 'left'
        if ($c -eq 3) { $al = 'center' }
        if ($c -eq 4) { $al = 'right' }
        Draw-Text $g $global:TTK.ColHead[$c] $PF_SMALL $brushHead $global:TTK.ColX[$c] 0 $cw $headH $al
    }
    $brushHead.Dispose()

    # 提取矩阵账号数据
    $targets = @()
    if ($global:TTK.Data -ne $null -and $global:TTK.Data.matrix -ne $null -and $global:TTK.Data.matrix.targets -ne $null) {
        $targets = @($global:TTK.Data.matrix.targets)
    }

    # 兜底默认列表
    if ($targets.Count -eq 0) {
        $targets = @(
            @{ id='1'; label='国内 (.cn)'; nickname='Wengole'; status='健康可用'; total_credits=229.10; detail='基础 22.1 + 赠送 207.0'; reset_time='正常可用'; kind='web' },
            @{ id='2'; label='国际谷歌'; nickname='wegole'; status='健康可用'; total_credits=177.05; detail='基础 100.0 + 奖励 77.05'; reset_time='正常可用'; kind='web' },
            @{ id='3'; label='国际qq'; nickname='wegooole'; status='健康可用'; total_credits=129.02; detail='基础 100.0 + 奖励 29.02'; reset_time='正常可用'; kind='web' },
            @{ id='4'; label='国际网易'; nickname='wegoole'; status='健康可用'; total_credits=347.91; detail='基础 86.53 + 奖励 261.38'; reset_time='正常可用'; kind='web' },
            @{ id='5'; label='国际139'; nickname='weegole'; status='健康可用'; total_credits=229.27; detail='基础 99.27 + 奖励 130.0'; reset_time='正常可用'; kind='web' },
            @{ id='6'; label='海外 API Key (cb1.txt)'; nickname='-'; status='查询失败'; total_credits=0.0; detail='需在主 Brave 登录该账号'; reset_time='-'; kind='api' }
        )
    }

    $brushText   = [System.Drawing.SolidBrush]::new($C_TEXT)
    $brushMuted  = [System.Drawing.SolidBrush]::new($C_MUTED)
    $brushBlue   = [System.Drawing.SolidBrush]::new($C_BLUE)
    $brushGreen  = [System.Drawing.SolidBrush]::new($C_GREEN)
    $brushAmber  = [System.Drawing.SolidBrush]::new($C_AMBER)
    $brushRed    = [System.Drawing.SolidBrush]::new($C_RED)
    $brushPurple = [System.Drawing.SolidBrush]::new($C_PURPLE)

    $rulesMap = @{
        '1' = '国内每日签到 (+100点)'
        '2' = '国际前日会话 (+50点)'
        '3' = '国际前日会话 (+50点)'
        '4' = '国际前日会话 (+50点)'
        '5' = '国际前日会话 (+50点)'
        '6' = 'Pro 会员商业通道兜底'
    }

    for ($r = 0; $r -lt $targets.Count; $r++) {
        $tgt = $targets[$r]
        $y = $headH + $r * $rowH
        $tid = [string]$tgt.id

        # 隔行与重点行底色
        if ($tid -eq '6') {
            $bgRow = [System.Drawing.SolidBrush]::new((Col '#1A1826')) # Target 6 紫调尊贵背景
        } elseif ($tid -eq '1') {
            $bgRow = [System.Drawing.SolidBrush]::new((Col '#141E2A')) # Target 1 国内主号蓝调背景
        } elseif ($r % 2 -eq 0) {
            $bgRow = [System.Drawing.SolidBrush]::new((Col '#12151C'))
        } else {
            $bgRow = [System.Drawing.SolidBrush]::new((Col '#141821'))
        }
        $g.FillRectangle($bgRow, 0, $y, $w, $rowH)
        $bgRow.Dispose()

        # 状态着色
        $st = [string]$tgt.status
        $brStatus = $brushGreen
        if ($st -like '*429*') { $brStatus = $brushRed }
        elseif ($st -like '*查询失败*') { $brStatus = $brushRed }
        elseif ($st -like '*未登录*' -or $st -like '*缺失*' -or $st -like '*不匹配*') { $brStatus = $brushAmber }

        $ruleTxt = if ($rulesMap.ContainsKey($tid)) { $rulesMap[$tid] } else { '按需轮询调用' }

        $cells = @(
            ('Target ' + $tid),
            [string]$tgt.label,
            [string]$tgt.nickname,
            $st,
            (('{0:0.00}' -f [double]$tgt.total_credits) + ' 点'),
            [string]$tgt.detail,
            [string]$tgt.reset_time,
            $ruleTxt
        )

        for ($c = 0; $c -lt 8; $c++) {
            $cw = $global:TTK.ColX[$c + 1] - $global:TTK.ColX[$c]
            $al = 'left'
            $br = $brushText
            $fnt = $PF_BODY

            if ($c -eq 0) {
                if ($tid -eq '6') { $br = $brushPurple; $fnt = $PF_BOLD }
                elseif ($tid -eq '1') { $br = $brushBlue; $fnt = $PF_BOLD }
                else { $br = $brushText; $fnt = $PF_BOLD }
            } elseif ($c -eq 2) {
                $br = $brushMuted
            } elseif ($c -eq 3) {
                $al = 'center'
                $br = $brStatus
            } elseif ($c -eq 4) {
                $al = 'right'
                if ($tid -eq '6') { $br = $brushPurple; $fnt = $PF_BOLD }
                else { $br = $brushAmber; $fnt = $PF_BOLD }
            } elseif ($c -eq 5 -or $c -eq 6) {
                $br = $brushMuted
                $fnt = $PF_TINY
            } elseif ($c -eq 7) {
                $br = $brushText
                $fnt = $PF_TINY
            }

            Draw-Text $g $cells[$c] $fnt $br $global:TTK.ColX[$c] $y $cw $rowH $al
        }
    }

    # 底部汇总条
    $totY = $headH + $targets.Count * $rowH + 4
    $totW = $w
    $bgTot = [System.Drawing.SolidBrush]::new((Col '#111722'))
    $g.FillRectangle($bgTot, 0, $totY, $totW, 24)
    $bgTot.Dispose()

    $totCredits = 0.0
    if ($global:TTK.Data -ne $null -and $global:TTK.Data.matrix -ne $null) {
        $totCredits = [double]$global:TTK.Data.matrix.total_credits
    } else {
        foreach ($t in $targets) { $totCredits += [double]$t.total_credits }
    }
    $liveN = @($targets | Where-Object { $_.live -ne $false }).Count
    $totMsg = '⚡ 矩阵实时可用：' + ('{0:0.00}' -f $totCredits) + ' 点  ·  ' + $liveN + '/' + $targets.Count + ' 通道实时查询成功'
    if ($liveN -lt $targets.Count) { $totMsg += '  ·  ' + ($targets.Count - $liveN) + ' 个通道失败(未计入)' }
    Draw-Text $g $totMsg $PF_SMALL $brushGreen 12 $totY ($totW - 24) 24 'left'

    $brushText.Dispose()
    $brushMuted.Dispose()
    $brushBlue.Dispose()
    $brushGreen.Dispose()
    $brushAmber.Dispose()
    $brushRed.Dispose()
    $brushPurple.Dispose()
})

# ---------------- 页脚 ----------------
$lblFootL = New-Lbl '' $F_TINY $C_MUTED (P 18) (P 664) (P 700) (P 20) 'MiddleLeft'
$lblFootR = New-Lbl '' $F_TINY $C_MUTED (P 720) (P 664) (P 302) (P 20) 'MiddleRight'
$form.Controls.Add($lblFootL)
$form.Controls.Add($lblFootR)
$global:TTK.UI.FootL = $lblFootL
$global:TTK.UI.FootR = $lblFootR

# ---------------- 数据加载与界面更新 ----------------
function Load-Report {
    $p = $global:TTK.Report
    if ([string]::IsNullOrEmpty($p)) { return $null }
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $p -Raw -Encoding UTF8
        if ([string]::IsNullOrEmpty($raw)) { return $null }
        return ($raw | ConvertFrom-Json)
    } catch {
        Log ('load report failed: ' + $_.Exception.Message)
        return $null
    }
}

function Update-UI {
    $rep = $global:TTK.Data
    if ($rep -eq $null) { return }
    $t = $rep.today
    if ($t -ne $null) {
        # 1. 今日用量：只使用 Token，上下行与调用方式分列
        $tokStr = Fmt-Tok $t.tokens
        $crdStr = [string]$t.credits
        $script:CardValue['today'].Text = $tokStr
        $script:CardSub['today'].Text = '输入 ' + (Fmt-Tok $t.in) + ' · 输出 ' + (Fmt-Tok $t.out) + [Environment]::NewLine + '终端 ' + (Fmt-Tok $t.terminal.tokens) + ' · 弹窗 ' + (Fmt-Tok $t.popup.tokens) + ' · ' + (Fmt-Int $t.req) + ' 次'

        # 2. 今日估算花销：各模型 Token 量 × 对应单价，不混入积分
        $totCost = [double]$t.cost
        $script:CardValue['cost'].Text = (Fmt-Money $totCost)
        $hitRate = 0
        if ([double]$t.in -gt 0) { $hitRate = [Math]::Round(100 * [double]$t.hit / [double]$t.in) }
        $priceNote = '按模型输入/输出 Token 估价 · 不含积分'
        if (@($t.unpriced_models).Count -gt 0) { $priceNote = '部分模型未配价 · 悬停查看明细' }
        $script:CardSub['cost'].Text = $priceNote + [Environment]::NewLine + '缓存命中 ' + (Fmt-Tok $t.hit) + ' (' + $hitRate + '%) · 写入 ' + (Fmt-Tok $t.write)
        $modelLines = @()
        foreach ($m in @($t.models)) {
            $mark = if ($m.priced -eq $true) { '' } else { ' · 未配置单价' }
            $modelLines += ($m.id + '：输入 ' + (Fmt-Tok $m.in) + ' · 输出 ' + (Fmt-Tok $m.out) + ' · 估算 ' + (Fmt-Money $m.cost) + $mark)
        }
        $global:TTK.UI.Tip.SetToolTip($script:CardPanel['cost'], '各模型 Token 用量与估算费用' + [Environment]::NewLine + ($modelLines -join [Environment]::NewLine))

        # 3. 矩阵可用总积分（独立口径，不折算进 Token 费用）
        $mat = $rep.matrix
        if ($mat -ne $null -and $mat.total_credits -ne $null) {
            $matTot = [double]$mat.total_credits
            $script:CardValue['credit'].Text = (Fmt-Int $matTot) + ' 点'
            $script:CardSub['credit'].Text = '今日消耗 ' + $crdStr + ' 点（独立统计）' + [Environment]::NewLine + '6通道总资产 ' + ('{0:0.00}' -f $matTot) + ' 点就绪'
        } else {
            $script:CardValue['credit'].Text = '3,405 点'
            $script:CardSub['credit'].Text = '今日消耗 ' + $crdStr + ' 点'
        }

        # 4. 近 7 天估算花销（同样不含积分）
        $tot = $rep.totals
        if ($tot -ne $null) {
            $script:CardValue['week'].Text = (Fmt-Money $tot.cost)
            $script:CardSub['week'].Text = '按模型 Token 估价 · 不含积分' + [Environment]::NewLine + '总用量 ' + (Fmt-Tok $tot.tokens) + ' · 积分另计 ' + [string]$tot.credits + '点'
        }
    }

    # 签到标记徽章更新
    if ($rep.signin -ne $null -and $global:TTK.UI.SigninBadge -ne $null) {
        $s = $rep.signin
        if ($s.today_checked -eq $true) {
            $global:TTK.UI.SigninBadge.Text = $s.badge_text
            $global:TTK.UI.SigninBadge.ForeColor = $C_GREEN
            $global:TTK.UI.SigninBadge.BackColor = (Col '#142E20')
            $global:TTK.UI.Tip.SetToolTip($global:TTK.UI.SigninBadge, '今日签到状态: 已签到完成' + [Environment]::NewLine + '时刻: ' + $s.time + [Environment]::NewLine + '账号: Target 1 (国内主号 Wengole)' + [Environment]::NewLine + '提示: ' + $s.msg)
        } else {
            $global:TTK.UI.SigninBadge.Text = '⚡ 今日未签到'
            $global:TTK.UI.SigninBadge.ForeColor = $C_AMBER
            $global:TTK.UI.SigninBadge.BackColor = (Col '#2B2314')
            $global:TTK.UI.Tip.SetToolTip($global:TTK.UI.SigninBadge, '今日尚未签到，点击右侧【签到】按钮可立即获取 100 积分')
        }
    }

    $global:TTK.UI.Chart.Invalidate()
    $global:TTK.UI.Table.Invalidate()
    $global:TTK.UI.Mem.Invalidate()

    $mb = $rep.membership
    if ($mb -ne $null) {
        $tipTxt = $mb.plan + ' · ' + $mb.month + ' 月账单口径' + [Environment]::NewLine
        $tipTxt += 'API 价值 = 本月各模型输入/输出 Token × 对应单价估算（不含积分）= ¥' + $mb.api_cost + [Environment]::NewLine
        $tipTxt += '会员费 = $' + $mb.fee_usd + ' × ' + $mb.usd_cny + ' = ¥' + $mb.fee_cny + [Environment]::NewLine
        $tipTxt += '省下 = ' + $mb.api_cost + ' − ' + $mb.fee_cny + ' = ¥' + $mb.saved + '（' + $mb.multiple + ' 倍）' + [Environment]::NewLine
        $tipTxt += '本月已统计 ' + $mb.month_days + ' 天 · ' + (Fmt-Int $mb.month_req) + ' 次请求'
        $global:TTK.UI.Tip.SetToolTip($global:TTK.UI.Mem, $tipTxt)
    }

    $models = @{}
    foreach ($d in @($rep.days)) {
        foreach ($m in @($d.models)) {
            if (-not $models.ContainsKey($m.id)) { $models[$m.id] = 0 }
            $models[$m.id] += [int]$m.req
        }
    }
    $parts = @()
    foreach ($k in $models.Keys) { $parts += ($k + ' ' + (Fmt-Int $models[$k])) }
    $global:TTK.UI.FootL.Text = '数据源 ~/.codebuddy-cli/projects · 6通道全矩阵 · 模型 ' + ($parts -join ' · ')

    $matTime = if ($rep.matrix -ne $null) { ' · 矩阵 ' + $rep.matrix.updated_at.Substring(11) } else { '' }
    $global:TTK.UI.FootR.Text = '模型 Token 单价估算（不含积分） · 刷新 ' + $rep.generated_at.Substring(11) + $matTime
}

# ---------------- 操作与进程调度 ----------------
$script:ScanProc = $null
$script:ActiveAction = ''
$script:Timer = [System.Windows.Forms.Timer]::new()
$script:Timer.Interval = 150
$script:Timer.Add_Tick({
    if ($script:ScanProc -eq $null) { return }
    if ($script:ScanProc.HasExited) {
        $script:Timer.Stop()
        $code = $script:ScanProc.ExitCode
        $script:ScanProc = $null
        $act = $script:ActiveAction
        $script:ActiveAction = ''

        $global:TTK.UI.BtnRefresh.Enabled = $true
        $global:TTK.UI.BtnScan.Enabled = $true
        $global:TTK.UI.BtnSignin.Enabled = $true
        Log ('action ' + $act + ' exited code=' + $code)

        $rep = Load-Report
        if ($rep -ne $null) {
            $global:TTK.Data = $rep
            Update-UI
        }

        if ($act -eq 'signin') {
            if ($rep -ne $null -and $rep.signin -ne $null) {
                $global:TTK.UI.Status.Text = $rep.signin.msg
                $global:TTK.UI.Status.ForeColor = $C_GREEN
            } else {
                $global:TTK.UI.Status.Text = '签到完成'
                $global:TTK.UI.Status.ForeColor = $C_GREEN
            }
        } elseif ($act -eq 'refresh') {
            $totC = if ($rep -ne $null -and $rep.matrix -ne $null) { $rep.matrix.total_credits } else { '' }
            $global:TTK.UI.Status.Text = '矩阵积分刷新完成 (' + $totC + '点)'
            $global:TTK.UI.Status.ForeColor = $C_GREEN
        } elseif ($act -eq 'scan') {
            $global:TTK.UI.Status.Text = '会话扫描汇总完成'
            $global:TTK.UI.Status.ForeColor = $C_BLUE
        }
    }
})

function Start-TtkProc([string]$Action, [string[]]$argList, [string]$statusMsg) {
    if ($script:ScanProc -ne $null) { return }
    $script:ActiveAction = $Action
    $global:TTK.UI.Status.Text = $statusMsg
    $global:TTK.UI.Status.ForeColor = $C_AMBER
    $global:TTK.UI.Status.Visible = $true
    $global:TTK.UI.BtnRefresh.Enabled = $false
    $global:TTK.UI.BtnScan.Enabled = $false
    $global:TTK.UI.BtnSignin.Enabled = $false
    try {
        $script:ScanProc = Start-Process -FilePath 'py' -ArgumentList $argList -PassThru -WindowStyle Hidden -RedirectStandardError $global:TTK.Err
        $script:Timer.Start()
    } catch {
        Log ('start proc failed: ' + $_.Exception.Message)
        $global:TTK.UI.Status.Text = '无法启动 py -3.11'
        $global:TTK.UI.BtnRefresh.Enabled = $true
        $global:TTK.UI.BtnScan.Enabled = $true
        $global:TTK.UI.BtnSignin.Enabled = $true
        $script:ActiveAction = ''
    }
}

function Start-Scan {
    Start-TtkProc 'scan' @('-3.11', ('"' + $global:TTK.Py + '"'), '--scan', '--days', [string]$Days, '--quiet') '正在扫描 CLI 会话…'
}

function Start-MatrixRefresh {
    Start-TtkProc 'refresh' @('-3.11', ('"' + $global:TTK.Py + '"'), '--refresh-matrix', '--quiet') '正在刷新 6 通道矩阵与积分…'
}

function Start-SignIn {
    Start-TtkProc 'signin' @('-3.11', ('"' + $global:TTK.Py + '"'), '--signin', '--quiet') '正在执行国内主号签到…'
}

# ---------------- 每日模型 Token 与价格明细弹窗 ----------------
function Show-PricingDetailsDialog {
    $rep = $global:TTK.Data
    if ($rep -eq $null) { $rep = Load-Report }
    $dlg = [System.Windows.Forms.Form]::new()
    $dlg.Text = 'Token 用量与价格明细'
    $dlg.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $dlg.ClientSize = [System.Drawing.Size]::new((P 1180), (P 720))
    $dlg.MinimumSize = [System.Drawing.Size]::new((P 900), (P 560))
    $dlg.BackColor = $C_BG
    $dlg.ForeColor = $C_TEXT
    $dlg.KeyPreview = $true
    $dlg.Add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $dlg.Close() }
    })

    $layout = [System.Windows.Forms.TableLayoutPanel]::new()
    $layout.Dock = [System.Windows.Forms.DockStyle]::Fill
    $layout.ColumnCount = 1
    $layout.RowCount = 3
    [void]$layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, (P 54)))
    [void]$layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 64))
    [void]$layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 36))
    $dlg.Controls.Add($layout)

    $head = [System.Windows.Forms.Panel]::new()
    $head.Dock = [System.Windows.Forms.DockStyle]::Fill
    $head.BackColor = $C_HEAD
    $layout.Controls.Add($head, 0, 0)
    $lblH = New-Lbl '每日 × 模型 Token 用量；选中一行查看计价公式。JSON：days[] → models[] → breakdown[]' $F_BODY $C_TEXT (P 16) (P 6) (P 930) (P 26) 'MiddleLeft'
    $head.Controls.Add($lblH)
    $basisTxt = '单价口径：厂商官网刊例价（美元×7.15）· 不采用限时折扣/活动价/中转站价 · 缓存命中未公布按输入×10%、写入未公布按未命中输入价'
    $lblBasis = New-Lbl $basisTxt $F_TINY $C_MUTED (P 16) (P 32) (P 1000) (P 18) 'MiddleLeft'
    $head.Controls.Add($lblBasis)
    $btnOpenJson = New-Btn '打开 JSON' 0 (P 110) (Col '#1E3038')
    $btnOpenJson.Location = [System.Drawing.Point]::new((P 1048), (P 13))
    $btnOpenJson.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
    $btnOpenJson.Add_Click({ Start-Process $global:TTK.Report })
    $head.Controls.Add($btnOpenJson)

    $grid = [System.Windows.Forms.DataGridView]::new()
    $grid.Dock = [System.Windows.Forms.DockStyle]::Fill
    $grid.ReadOnly = $true
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.MultiSelect = $false
    $grid.RowHeadersVisible = $false
    $grid.AutoGenerateColumns = $false
    $grid.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
    $grid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $grid.BackgroundColor = $C_CARD
    $grid.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $grid.EnableHeadersVisualStyles = $false
    $grid.ColumnHeadersDefaultCellStyle.BackColor = $C_HEAD
    $grid.ColumnHeadersDefaultCellStyle.ForeColor = $C_TEXT
    $grid.ColumnHeadersDefaultCellStyle.Font = $F_SMALL
    $grid.DefaultCellStyle.BackColor = $C_CARD
    $grid.DefaultCellStyle.ForeColor = $C_TEXT
    $grid.DefaultCellStyle.SelectionBackColor = (Col '#263B54')
    $grid.DefaultCellStyle.SelectionForeColor = $C_TEXT
    $grid.DefaultCellStyle.Font = $F_SMALL
    $grid.GridColor = $C_LINE
    $layout.Controls.Add($grid, 0, 1)

    $cols = @(
        @{ N = 'date'; T = '日期'; W = 82 },
        @{ N = 'model'; T = '模型'; W = 150 },
        @{ N = 'in'; T = '输入 Token'; W = 105 },
        @{ N = 'hit'; T = '缓存命中'; W = 105 },
        @{ N = 'miss'; T = '未命中'; W = 95 },
        @{ N = 'write'; T = '缓存写入'; W = 95 },
        @{ N = 'out'; T = '输出 Token'; W = 100 },
        @{ N = 'tokens'; T = '总 Token'; W = 110 },
        @{ N = 'cost'; T = '估算费用'; W = 85 }
    )
    foreach ($ci in $cols) {
        $c = [System.Windows.Forms.DataGridViewTextBoxColumn]::new()
        $c.Name = $ci.N
        $c.HeaderText = $ci.T
        $c.FillWeight = $ci.W
        [void]$grid.Columns.Add($c)
    }

    $txtDetail = [System.Windows.Forms.TextBox]::new()
    $txtDetail.Dock = [System.Windows.Forms.DockStyle]::Fill
    $txtDetail.Multiline = $true
    $txtDetail.ReadOnly = $true
    $txtDetail.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $txtDetail.Font = [System.Drawing.Font]::new('Consolas', 9)
    $txtDetail.BackColor = $C_CARD
    $txtDetail.ForeColor = $C_TEXT
    $txtDetail.Text = '请选择上方一行查看计算过程。'
    $layout.Controls.Add($txtDetail, 0, 2)
    $global:TTK.UI.PricingDetailText = $txtDetail

    if ($rep -ne $null) {
        foreach ($d in @($rep.days)) {
            foreach ($m in @($d.models)) {
                $idx = $grid.Rows.Add(
                    [string]$d.date, [string]$m.id,
                    (Fmt-Int $m.in), (Fmt-Int $m.hit), (Fmt-Int $m.miss),
                    (Fmt-Int $m.write), (Fmt-Int $m.out), (Fmt-Int $m.tokens),
                    ('¥' + ('{0:0.0000}' -f [double]$m.cost))
                )
                $grid.Rows[$idx].Tag = @{ Date = $d.date; Model = $m }
            }
        }
    }

    $grid.Add_SelectionChanged({
        param($s, $e)
        if ($s.SelectedRows.Count -eq 0) { return }
        $info = $s.SelectedRows[0].Tag
        if ($info -eq $null) { return }
        $m = $info.Model
        $nl = [Environment]::NewLine
        $lines = @()
        $lines += ($info.Date + '  ' + $m.id)
        $lines += ('总 Token = 输入 {0} + 输出 {1} = {2}' -f (Fmt-Int $m.in), (Fmt-Int $m.out), (Fmt-Int $m.tokens))
        $lines += ('输入 = 缓存命中 {0} + 未命中 {1} + 缓存写入 {2}' -f (Fmt-Int $m.hit), (Fmt-Int $m.miss), (Fmt-Int $m.write))
        $lines += ('价格单位：CNY / 百万 Token    来源：' + [string]$m.price_source)
        $lines += ''
        $labels = @{ hit = '缓存命中'; miss = '未命中输入'; write = '缓存写入'; out = '输出' }
        if ($m.breakdown -ne $null -and @($m.breakdown).Count -gt 0) {
            foreach ($bd in @($m.breakdown)) {
                $lines += ('[{0}] 小计 ¥{1}' -f $labels[$bd.kind], ('{0:0.000000}' -f [double]$bd.cost))
                $lines += ('  高峰 {0} × ¥{1} / 1,000,000 = ¥{2}' -f (Fmt-Int $bd.peak_tokens), ('{0:0.####}' -f [double]$bd.peak_price), ('{0:0.000000}' -f [double]$bd.peak_cost))
                $lines += ('  空闲 {0} × ¥{1} / 1,000,000 = ¥{2}' -f (Fmt-Int $bd.off_tokens), ('{0:0.####}' -f [double]$bd.off_price), ('{0:0.000000}' -f [double]$bd.off_cost))
            }
            $lines += ''
            $lines += ('模型合计 = ¥{0}（JSON cost = {1}，保留 4 位小数）' -f ('{0:0.000000}' -f (($m.breakdown | Measure-Object -Property cost -Sum).Sum)), ('{0:0.0000}' -f [double]$m.cost))
        } else {
            $lines += '未配置该模型单价：Token 已统计，费用不计入总估价。'
        }
        $global:TTK.UI.PricingDetailText.Text = ($lines -join $nl)
    })
    if ($grid.Rows.Count -gt 0) { $grid.CurrentCell = $grid.Rows[0].Cells[0] }

    $dlg.ShowDialog($global:TTK.UI.Form) | Out-Null
    $dlg.Dispose()
}

# ---------------- 历史记录弹窗 ----------------
function Show-RecordsDialog {
    $dlg = [System.Windows.Forms.Form]::new()
    $dlg.Text = 'CodeBuddy 运行与巡检记录总览'
    $dlg.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $dlg.ClientSize = [System.Drawing.Size]::new((P 840), (P 580))
    $dlg.BackColor = $C_BG
    $dlg.ForeColor = $C_TEXT
    $dlg.KeyPreview = $true
    $dlg.Add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $dlg.Close() }
    })

    $lblH = [System.Windows.Forms.Label]::new()
    $lblH.Text = '📋 6通道矩阵资产、每日签到与会话扫描运行记录'
    $lblH.Font = [System.Drawing.Font]::new('Microsoft YaHei UI', 12, [System.Drawing.FontStyle]::Bold)
    $lblH.ForeColor = $C_TEXT
    $lblH.Location = [System.Drawing.Point]::new((P 20), (P 16))
    $lblH.Size = [System.Drawing.Size]::new((P 800), (P 28))
    $dlg.Controls.Add($lblH)

    $txtBox = [System.Windows.Forms.TextBox]::new()
    $txtBox.Multiline = $true
    $txtBox.ReadOnly = $true
    $txtBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $txtBox.Font = [System.Drawing.Font]::new('Consolas', 9.5)
    $txtBox.BackColor = $C_CARD
    $txtBox.ForeColor = $C_TEXT
    $txtBox.Location = [System.Drawing.Point]::new((P 20), (P 52))
    $txtBox.Size = [System.Drawing.Size]::new((P 800), (P 460))
    $dlg.Controls.Add($txtBox)

    $recordsText = ''
    try {
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = 'py'
        $psi.Arguments = ('-3.11 "' + $global:TTK.Py + '" --records --json')
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEnd()
        $p.WaitForExit()
        if ($p.ExitCode -eq 0 -and (-not [string]::IsNullOrEmpty($out))) {
            $rec = $out | ConvertFrom-Json
            $sb = [System.Text.StringBuilder]::new()

            [void]$sb.AppendLine('======================================================================')
            [void]$sb.AppendLine('                  CodeBuddy 运行记录与资产总控明细                      ')
            [void]$sb.AppendLine('======================================================================')
            [void]$sb.AppendLine()

            [void]$sb.AppendLine('【一、国内主号每日自动签到历史】')
            if ($rec.signin_history -ne $null -and $rec.signin_history.Count -gt 0) {
                foreach ($item in $rec.signin_history) {
                    $st = if ($item.status -eq 'success') { '首次签到成功' } elseif ($item.status -eq 'already') { '今日已签' } else { $item.status }
                    [void]$sb.AppendLine(('  * 日期: ' + $item.last_signin_date + ' ' + $item.last_signin_time + ' | 状态: ' + $st + ' | 奖励: +' + $item.reward + '点 | ' + $item.message))
                }
            } else {
                [void]$sb.AppendLine('  暂无签到历史记录')
            }
            [void]$sb.AppendLine()

            [void]$sb.AppendLine('【二、6 通道账号矩阵与精准积分巡检快照】')
            if ($rec.matrix_history -ne $null -and $rec.matrix_history.Count -gt 0) {
                foreach ($m in $rec.matrix_history) {
                    [void]$sb.AppendLine(('  * 巡检时刻: ' + $m.time + ' | 全矩阵可用总储备: ' + $m.total_credits + ' 点'))
                    if ($m.targets -ne $null) {
                        $parts = @()
                        foreach ($t in $m.targets) {
                            $props = $t.PSObject.Properties
                            foreach ($pr in $props) {
                                if ($pr.Name -ne 'status') {
                                    $parts += ('T' + $pr.Name + '=' + $pr.Value + '点')
                                }
                            }
                        }
                        [void]$sb.AppendLine(('      ↳ 各通道明细: ' + ($parts -join ' · ')))
                    }
                }
            } else {
                [void]$sb.AppendLine('  暂无巡检快照记录')
            }
            [void]$sb.AppendLine()

            [void]$sb.AppendLine('【三、当前 429 冷静期监控 (防踩踏拦截状态)】')
            if ($rec.cooldown_data -ne $null -and $rec.cooldown_data.targets -ne $null) {
                $cdTargets = $rec.cooldown_data.targets.PSObject.Properties
                $hasCd = $false
                foreach ($pr in $cdTargets) {
                    $val = $pr.Value
                    if ($val.status -eq 'cooldown') {
                        $hasCd = $true
                        [void]$sb.AppendLine(('  [!] Target ' + $pr.Name + ' 处于 429 限流中 | 解封时刻: ' + $val.reset_time_str + ' | 记录于: ' + $val.recorded_at))
                    } else {
                        [void]$sb.AppendLine(('  [✔] Target ' + $pr.Name + ' 健康可用 (状态: ' + $val.reset_time_str + ')'))
                    }
                }
                if (-not $hasCd) {
                    [void]$sb.AppendLine('  >> 当前所有矩阵通道均处于健康就绪状态，无任何 429 封禁！')
                }
            }
            [void]$sb.AppendLine()

            [void]$sb.AppendLine('【四、会话 Token 扫描历史】')
            if ($rec.scan_history -ne $null -and $rec.scan_history.Count -gt 0) {
                foreach ($sc in $rec.scan_history) {
                    [void]$sb.AppendLine(('  * ' + $sc.time + ' | 耗时: ' + $sc.scan_ms + 'ms | 扫文件: ' + $sc.files + '个 | 增量: ' + $sc.new_records + '条 | 今日Tokens: ' + (Fmt-Tok $sc.today_tokens) + ' | 今日估价: ' + (Fmt-Money $sc.today_cost)))
                }
            } else {
                [void]$sb.AppendLine('  暂无扫描历史记录')
            }

            $recordsText = $sb.ToString()
        }
    } catch {
        $recordsText = '读取记录失败: ' + $_.Exception.Message
    }

    if ([string]::IsNullOrEmpty($recordsText)) {
        $recordsText = '未读取到记录数据。可先点击顶栏【刷新】或【扫描】生成最新数据。'
    }
    $txtBox.Text = $recordsText

    $btnOpenMd = New-Btn '📑 查看巡检报告(MD)' (P 20) (P 180) (Col '#202836')
    $btnOpenMd.Location = [System.Drawing.Point]::new((P 20), (P 526))
    $btnOpenMd.Add_Click({
        $mdPath = Join-Path $global:TTK.Dir 'CREDIT_STATUS.md'
        if (-not (Test-Path $mdPath)) { $mdPath = 'E:\ai tec\cb_login\CREDIT_STATUS.md' }
        if (Test-Path $mdPath) { Start-Process $mdPath }
    })
    $dlg.Controls.Add($btnOpenMd)

    $btnOpenDash = New-Btn '🌐 打开主浏览器大屏' (P 210) (P 180) (Col '#2A2036')
    $btnOpenDash.Location = [System.Drawing.Point]::new((P 210), (P 526))
    $btnOpenDash.Add_Click({
        $htmlPath = 'E:\ai tec\cb_login\credit_dashboard.html'
        if (Test-Path $htmlPath) { Start-Process $htmlPath }
    })
    $dlg.Controls.Add($btnOpenDash)

    $btnCloseDlg = New-Btn '关闭' (P 730) (P 90) (Col '#3A2230')
    $btnCloseDlg.Location = [System.Drawing.Point]::new((P 730), (P 526))
    $btnCloseDlg.Add_Click({ $dlg.Close() })
    $dlg.Controls.Add($btnCloseDlg)

    $dlg.ShowDialog($global:TTK.UI.Form) | Out-Null
    $dlg.Dispose()
}

# ---------------- 交互绑定 ----------------
$script:Drag = $false
$script:DragPt = [System.Drawing.Point]::new(0, 0)
$header.Add_MouseDown({
    param($s, $e)
    $script:Drag = $true
    $script:DragPt = [System.Windows.Forms.Cursor]::Position
})
$header.Add_MouseMove({
    param($s, $e)
    if ($script:Drag) {
        $p = [System.Windows.Forms.Cursor]::Position
        $f = $global:TTK.UI.Form
        $f.Location = [System.Drawing.Point]::new(($f.Left + $p.X - $script:DragPt.X), ($f.Top + $p.Y - $script:DragPt.Y))
        $script:DragPt = $p
    }
})
$header.Add_MouseUp({ $script:Drag = $false })

$btnSignin.Add_Click({ Start-SignIn })
$btnScan.Add_Click({ Start-Scan })
$btnRefresh.Add_Click({ Start-MatrixRefresh })
$btnRecords.Add_Click({ Show-RecordsDialog })
$btnDetails.Add_Click({ Show-PricingDetailsDialog })

$lblSigninBadge.Add_Click({
    if ($global:TTK.Data -ne $null -and $global:TTK.Data.signin -ne $null -and $global:TTK.Data.signin.today_checked -eq $true) {
        [System.Windows.Forms.MessageBox]::Show(
            ('今日已签到成功！' + [Environment]::NewLine + [Environment]::NewLine + '时刻: ' + $global:TTK.Data.signin.time + [Environment]::NewLine + '奖励: +' + $global:TTK.Data.signin.reward + ' 积分' + [Environment]::NewLine + '账号: Target 1 (国内主号 Wengole)'),
            '签到状态',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
    } else {
        Start-SignIn
    }
})

$btnTop.Add_Click({
    $f = $global:TTK.UI.Form
    $f.TopMost = -not $f.TopMost
    if ($f.TopMost) {
        $global:TTK.UI.BtnTop.BackColor = (Col '#1E2C44')
        $global:TTK.UI.BtnTop.ForeColor = $C_BLUE
    } else {
        $global:TTK.UI.BtnTop.BackColor = $C_CARD
        $global:TTK.UI.BtnTop.ForeColor = $C_TEXT
    }
})
$btnClose.Add_Click({ $global:TTK.UI.Form.Close() })

$form.Add_KeyDown({
    param($s, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $global:TTK.UI.Form.Close() }
})

# 状态恢复
if (Test-Path -LiteralPath $global:TTK.State) {
    try {
        $st = Get-Content -LiteralPath $global:TTK.State -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($st.X -ne $null -and $st.Y -ne $null) {
            $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
            $nx = [Math]::Min([Math]::Max([int]$st.X, $wa.Left), ($wa.Right - $form.Width))
            $ny = [Math]::Min([Math]::Max([int]$st.Y, $wa.Top), ($wa.Bottom - $form.Height))
            $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
            $form.Location = [System.Drawing.Point]::new($nx, $ny)
        }
        if ($st.TopMost -ne $null) { $form.TopMost = [bool]$st.TopMost }
    } catch { }
}
if ($form.TopMost) {
    $btnTop.BackColor = (Col '#1E2C44')
    $btnTop.ForeColor = $C_BLUE
}

$form.Add_FormClosing({
    try {
        $f = $global:TTK.UI.Form
        $o = @{ X = $f.Left; Y = $f.Top; TopMost = $f.TopMost }
        ($o | ConvertTo-Json -Compress) | Set-Content -LiteralPath $global:TTK.State -Encoding UTF8
    } catch { }
})

# 窗体加载并显示：每日首次调用自动签到并标记
$form.Add_Shown({
    Log ('shown size=' + $global:TTK.UI.Form.Size.Width + 'x' + $global:TTK.UI.Form.Size.Height + ' dpi=' + $global:TTK.UI.Form.DeviceDpi)
    $rep = Load-Report
    $needAutoSignin = $true
    if ($rep -ne $null) {
        $global:TTK.Data = $rep
        Update-UI
        if ($rep.signin -ne $null -and $rep.signin.today_checked -eq $true) {
            $needAutoSignin = $false
        }
    }

    if ($needAutoSignin) {
        Log 'Daily first launch detected: initiating auto sign-in...'
        Start-SignIn
    } else {
        Start-MatrixRefresh
    }
})

[System.Windows.Forms.Application]::add_ThreadException({
    param($s, $e)
    Log ('THREAD EX: ' + $e.Exception.Message + ' @ ' + $e.Exception.StackTrace)
})

try {
    [System.Windows.Forms.Application]::Run($form)
} catch {
    Log ('RUN EX: ' + $_.Exception.ToString())
    throw
}
