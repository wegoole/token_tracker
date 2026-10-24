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

$F_TITLE = [System.Drawing.Font]::new('Microsoft YaHei UI', 14, [System.Drawing.FontStyle]::Bold)
$F_H1    = [System.Drawing.Font]::new('Microsoft YaHei UI', 19, [System.Drawing.FontStyle]::Bold)
$F_BODY  = [System.Drawing.Font]::new('Microsoft YaHei UI', 9)
$F_SMALL = [System.Drawing.Font]::new('Microsoft YaHei UI', 8)
$F_TINY  = [System.Drawing.Font]::new('Microsoft YaHei UI', 7.5)
$F_BTN   = [System.Drawing.Font]::new('Microsoft YaHei UI', 8.5)

# 自绘区域内的字体：坐标已被 ScaleTransform 放大，字号需先除以 K
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
$form.Text = 'Token 记录器'
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.ClientSize = [System.Drawing.Size]::new((P 1040), (P 772))
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

$lblTitle = New-Lbl 'Token 记录器' $F_TITLE $C_TEXT (P 56) (P 7) (P 260) (P 26) 'MiddleLeft'
$lblSub = New-Lbl 'CodeBuddy · 终端 / 弹窗 · 近 7 天' $F_SMALL $C_MUTED (P 57) (P 31) (P 300) (P 18) 'MiddleLeft'
$header.Controls.Add($lblTitle)
$header.Controls.Add($lblSub)

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

$btnRefresh = New-Btn '刷新' (P 852) (P 68) (Col '#202836')
$btnTop = New-Btn '置顶' (P 926) (P 56) (Col '#202836')
$btnClose = New-Btn '关闭' (P 988) (P 38) (Col '#3A2230')
$header.Controls.Add($btnRefresh)
$header.Controls.Add($btnTop)
$header.Controls.Add($btnClose)
$global:TTK.UI.BtnRefresh = $btnRefresh
$global:TTK.UI.BtnTop = $btnTop

$lblStatus = New-Lbl '正在汇总…' $F_SMALL $C_AMBER (P 500) (P 14) (P 340) (P 28) 'MiddleLeft'
$header.Controls.Add($lblStatus)
$global:TTK.UI.Status = $lblStatus

# ---------------- 指标卡 ----------------
$script:CardValue = @{}
$script:CardSub = @{}

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
    return $card
}

New-Card 'today' '今日用量' 'tokens' $C_BLUE (P 16) | Out-Null
New-Card 'cost' '今日花销' 'money' $C_GREEN (P 271) | Out-Null
New-Card 'credit' '今日积分' 'credits' $C_AMBER (P 526) | Out-Null
New-Card 'week' '近 7 天' 'week' $C_PURPLE (P 781) | Out-Null

# ---------------- 图表 ----------------
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
    $g.DrawString('每日用量（tokens）', $PF_BODY, $brushText, 18, 12)

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
$tip.InitialDelay = 200
$tip.ReshowDelay = 100
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
    $txt += '用量 ' + (Fmt-Tok $d.tokens) + '（终端 ' + (Fmt-Tok $d.terminal.tokens) + ' / 弹窗 ' + (Fmt-Tok $d.popup.tokens) + '）' + [Environment]::NewLine
    $txt += '命中 ' + (Fmt-Tok $d.hit) + ' · 未命中 ' + (Fmt-Tok $d.miss) + ' · 输出 ' + (Fmt-Tok $d.out) + [Environment]::NewLine
    $txt += '花销 ' + (Fmt-Money $d.cost) + ' · 请求 ' + (Fmt-Int $d.req) + ' 次'
    $global:TTK.UI.Tip.SetToolTip($s, $txt)
})

# ---------------- 会员条（WorkBuddy Pro 省下的钱）----------------
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
        $g.DrawString('会员信息缺失（检查 membership.json）', $PF_SMALL, $bm0, 16, 8)
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
        @{ T = ('本月 API ¥' + ('{0:0.00}' -f [double]$m.api_cost)); F = $PF_SMALL; B = $bText }
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
    if ($m.next_fee_usd -ne $null) {
        $nx = ([string]$m.next_effective).Substring(5, 2) + ' 月起 $' + ('{0:0.##}' -f [double]$m.next_fee_usd) + '/月'
        $sz = $g.MeasureString($nx, $PF_TINY)
        $g.DrawString($nx, $PF_TINY, $bAmber, [single]($w - 16 - $sz.Width), [single]($y + 1))
    }

    $bText.Dispose()
    $bMuted.Dispose()
    $bGreen.Dispose()
    $bAmber.Dispose()
})
$form.Controls.Add($mem)

# ---------------- 今日免费模型额度（用量 vs 历史单日峰值）----------------
$free = [System.Windows.Forms.Panel]::new()
$free.Location = [System.Drawing.Point]::new((P 16), (P 642))
$free.Size = [System.Drawing.Size]::new((P 1008), (P 120))
$free.BackColor = $C_CARD
$global:TTK.UI.Free = $free
$free.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
    $g.ScaleTransform($global:TTK.K, $global:TTK.K)
    $w = $s.Width / $global:TTK.K
    $h = $s.Height / $global:TTK.K
    $path = New-RoundPath 0.5 0.5 ($w - 1) ($h - 1) 10
    $bg = [System.Drawing.SolidBrush]::new($C_CARD)
    $g.FillPath($bg, $path); $bg.Dispose()
    $pen = [System.Drawing.Pen]::new($C_LINE, 1)
    $g.DrawPath($pen, $path); $pen.Dispose()

    $bText = [System.Drawing.SolidBrush]::new($C_TEXT)
    $bMuted = [System.Drawing.SolidBrush]::new($C_MUTED)
    $g.DrawString('今日免费模型额度（用量 / 预估上限）', $PF_BODY, $bText, 18, 10)

    $ws = @()
    if ($global:TTK.Data -ne $null) { $ws = @($global:TTK.Data.warnings) }
    if ($ws.Count -eq 0) {
        $g.DrawString('暂无数据', $PF_BODY, $bMuted, 18, 56)
        $bText.Dispose(); $bMuted.Dispose()
        return
    }
    $x0 = 20.0
    $trackX = 110.0
    $trackW = $w - $trackX - 236.0
    $rowH = 24.0
    $y0 = 38.0
    for ($i = 0; $i -lt $ws.Count; $i++) {
        $wi = $ws[$i]
        $yy = $y0 + $rowH * $i
        $ratioReq = 0.0; $ratioTok = 0.0
        if ([double]$wi.threshold_req -gt 0) { $ratioReq = [double]$wi.req / [double]$wi.threshold_req }
        if ([double]$wi.threshold_tokens -gt 0) { $ratioTok = [double]$wi.tokens / [double]$wi.threshold_tokens }
        $fill = [Math]::Max($ratioReq, $ratioTok)
        $over = $fill -gt 1.0
        if ($over) { $fill = 1.0 }
        $level = [int]$wi.level
        if ([int]$wi.err429 -gt 0) { $level = 2 }
        $col = $C_GREEN
        if ($level -eq 1) { $col = $C_AMBER }
        elseif ($level -ge 2) { $col = $C_RED }

        $g.DrawString($wi.group, $PF_TINY, $bText, $x0, ($yy + 3))

        $trackY = $yy + 3
        $trackH = 14.0
        $tbr = [System.Drawing.SolidBrush]::new($C_BG)
        $rr = New-RoundPath $trackX $trackY $trackW $trackH 6
        $g.FillPath($tbr, $rr); $tbr.Dispose(); $rr.Dispose()
        # 预警刻度线（比例取自 limits.json 的 warn_ratio，兜底 0.8）
        $wr = 0.8
        if ($wi.PSObject.Properties['warn_ratio'] -and [double]$wi.warn_ratio -gt 0) {
            $wr = [double]$wi.warn_ratio
        }
        $px80 = $trackX + $trackW * $wr
        $gp = [System.Drawing.Pen]::new($C_MUTED, 1)
        $g.DrawLine($gp, $px80, $trackY, $px80, ($trackY + $trackH)); $gp.Dispose()
        if ($fill -gt 0.001) {
            $fw = [Math]::Max(2.0, $trackW * $fill)
            $fb = [System.Drawing.SolidBrush]::new($col)
            $rp = New-RoundPath $trackX $trackY $fw $trackH 6
            $g.FillPath($fb, $rp); $fb.Dispose(); $rp.Dispose()
        }
        $txt = (Fmt-Tok $wi.tokens) + ' / ' + (Fmt-Tok $wi.threshold_tokens) + ' · ' + (Fmt-Int $wi.req) + '请求'
        if ([int]$wi.err429 -gt 0) { $txt += (' · 429×' + $wi.err429) }
        $g.DrawString($txt, $PF_TINY, $bText, ($trackX + $trackW + 8), ($yy + 3))
    }
    $bText.Dispose(); $bMuted.Dispose()
})
$form.Controls.Add($free)

# ---------------- 明细表（自绘）----------------
$tbl = [System.Windows.Forms.Panel]::new()
$tbl.Location = [System.Drawing.Point]::new((P 16), (P 400))
$tbl.Size = [System.Drawing.Size]::new((P 1008), (P 240))
$tbl.BackColor = $C_BG
$global:TTK.UI.Table = $tbl
$form.Controls.Add($tbl)

$global:TTK.ColX = @(0, 104, 232, 360, 484, 690, 790, 912, 1008)
$global:TTK.ColHead = @('日期', '终端用量', '弹窗用量', '合计', '命中 / 未命中', '输出', 'DS 花销', '积分')

function Draw-Text($g, [string]$text, $font, $brush, [single]$x, [single]$y, [single]$w, [single]$h, [string]$align) {
    $sf = [System.Drawing.StringFormat]::new()
    $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
    $sf.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap
    if ($align -eq 'right') { $sf.Alignment = [System.Drawing.StringAlignment]::Far }
    else { $sf.Alignment = [System.Drawing.StringAlignment]::Near }
    $rect = [System.Drawing.RectangleF]::new(($x + 10), $y, ($w - 20), $h)
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
    $rowH = 30
    $headH = 30

    $bgHead = [System.Drawing.SolidBrush]::new($C_HEAD)
    $g.FillRectangle($bgHead, 0, 0, $w, $headH)
    $bgHead.Dispose()

    $brushHead = [System.Drawing.SolidBrush]::new($C_MUTED)
    for ($c = 0; $c -lt 8; $c++) {
        $cw = $global:TTK.ColX[$c + 1] - $global:TTK.ColX[$c]
        $al = 'right'
        if ($c -eq 0) { $al = 'left' }
        Draw-Text $g $global:TTK.ColHead[$c] $PF_SMALL $brushHead $global:TTK.ColX[$c] 0 $cw $headH $al
    }
    $brushHead.Dispose()

    $days = @()
    if ($global:TTK.Data -ne $null) { $days = @($global:TTK.Data.days) }
    if ($days.Count -eq 0) {
        $bm = [System.Drawing.SolidBrush]::new($C_MUTED)
        $g.DrawString('暂无数据（首次运行需要扫描会话记录）', $PF_BODY, $bm, 12, ($headH + 16))
        $bm.Dispose()
        return
    }

    $brushText = [System.Drawing.SolidBrush]::new($C_TEXT)
    $brushBlue = [System.Drawing.SolidBrush]::new($C_BLUE)
    $brushGreen = [System.Drawing.SolidBrush]::new($C_GREEN)
    $brushAmber = [System.Drawing.SolidBrush]::new($C_AMBER)
    $todayStr = $days[$days.Count - 1].date

    for ($r = 0; $r -lt $days.Count; $r++) {
        $d = $days[$r]
        $y = $headH + $r * $rowH
        $isToday = ($d.date -eq $todayStr)
        if ($isToday) { $bgRow = [System.Drawing.SolidBrush]::new((Col '#1A2333')) }
        elseif ($r % 2 -eq 0) { $bgRow = [System.Drawing.SolidBrush]::new((Col '#12151C')) }
        else { $bgRow = [System.Drawing.SolidBrush]::new((Col '#141821')) }
        $g.FillRectangle($bgRow, 0, $y, $w, $rowH)
        $bgRow.Dispose()

        $cells = @(
            ($d.date.Substring(5) + '  ' + $d.weekday),
            (Fmt-Tok $d.terminal.tokens),
            (Fmt-Tok $d.popup.tokens),
            (Fmt-Tok $d.tokens),
            ((Fmt-Tok $d.hit) + ' / ' + (Fmt-Tok $d.miss)),
            (Fmt-Tok $d.out),
            (Fmt-Money $d.cost),
            ([string]$d.credits)
        )
        for ($c = 0; $c -lt 8; $c++) {
            $cw = $global:TTK.ColX[$c + 1] - $global:TTK.ColX[$c]
            $al = 'right'
            if ($c -eq 0) { $al = 'left' }
            $br = $brushText
            if ($c -eq 0 -and $isToday) { $br = $brushBlue }
            if ($c -eq 6) { $br = $brushGreen }
            if ($c -eq 7 -and [double]$d.credits -gt 0) { $br = $brushAmber }
            Draw-Text $g $cells[$c] $PF_BODY $br $global:TTK.ColX[$c] $y $cw $rowH $al
        }
    }

    $brushText.Dispose()
    $brushBlue.Dispose()
    $brushGreen.Dispose()
    $brushAmber.Dispose()
})

# ---------------- 页脚 ----------------
$lblFootL = New-Lbl '' $F_TINY $C_MUTED (P 18) (P 650) (P 700) (P 20) 'MiddleLeft'
$lblFootR = New-Lbl '' $F_TINY $C_MUTED (P 720) (P 650) (P 302) (P 20) 'MiddleRight'
$form.Controls.Add($lblFootL)
$form.Controls.Add($lblFootR)
$global:TTK.UI.FootL = $lblFootL
$global:TTK.UI.FootR = $lblFootR

# ---------------- 数据 ----------------
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
        $script:CardValue['today'].Text = (Fmt-Tok $t.tokens)
        $script:CardSub['today'].Text = '终端 ' + (Fmt-Tok $t.terminal.tokens) + ' · 弹窗 ' + (Fmt-Tok $t.popup.tokens) + [Environment]::NewLine + (Fmt-Int $t.req) + ' 次请求'

        $script:CardValue['cost'].Text = (Fmt-Money $t.cost)
        $hitRate = 0
        if ([double]$t.in -gt 0) { $hitRate = [Math]::Round(100 * [double]$t.hit / [double]$t.in) }
        $script:CardSub['cost'].Text = '命中 ' + (Fmt-Tok $t.hit) + '（' + $hitRate + '%）' + [Environment]::NewLine + '未命中 ' + (Fmt-Tok $t.miss) + ' · 输出 ' + (Fmt-Tok $t.out)

        $platformReq = 0
        foreach ($m in @($t.models)) {
            if ($m.id -ne 'deepseek-v4.1-flash' -and $m.id -ne 'deepseek-v4-pro' -and $m.id -ne 'deepseek-flash') {
                $platformReq += [int]$m.req
            }
        }
        $script:CardValue['credit'].Text = [string]$t.credits
        if ($platformReq -gt 0) {
            $script:CardSub['credit'].Text = '平台模型 ' + (Fmt-Int $platformReq) + ' 次' + [Environment]::NewLine + 'hy3 / step-5-preview'
        } else {
            $script:CardSub['credit'].Text = '无非免费接口调用'
        }

        $tot = $rep.totals
        $script:CardValue['week'].Text = (Fmt-Money $tot.cost)
        $script:CardSub['week'].Text = (Fmt-Tok $tot.tokens) + ' tokens' + [Environment]::NewLine + (Fmt-Int $tot.req) + ' 次 · 积分 ' + [string]$tot.credits
    }

    $global:TTK.UI.Chart.Invalidate()
    $global:TTK.UI.Table.Invalidate()
    $global:TTK.UI.Mem.Invalidate()
    $global:TTK.UI.Free.Invalidate()

    $mb = $rep.membership
    if ($mb -ne $null) {
        $tipTxt = $mb.plan + ' · ' + $mb.month + ' 月账单口径' + [Environment]::NewLine
        $tipTxt += 'API 价值 = 本月用量按 DeepSeek 官方峰谷价折算 = ¥' + $mb.api_cost + [Environment]::NewLine
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
    $global:TTK.UI.FootL.Text = '数据源 ~/.codebuddy-cli/projects · 模型 ' + ($parts -join ' · ')

    # 限流(429)汇总：渠道级额度池，仅受限模型命中
    $errTot = 0
    $worst = $null
    $worstN = 0
    foreach ($d in @($rep.days)) {
        $e = $d.errors
        if ($e -ne $null) {
            $n = [int]$e.total
            $errTot += $n
            if ($n -gt $worstN) { $worstN = $n; $worst = $d.date }
        }
    }
    $errTxt = ''
    if ($errTot -gt 0) { $errTxt = ' · 429限流 ' + $errTot + '次(最重 ' + $worst + ')' }
    $global:TTK.UI.FootR.Text = '价格 DeepSeek 官方（' + $rep.prices.fetched_at + '）· 刷新于 ' + $rep.generated_at.Substring(11) + $errTxt

    # 警示模块：免费模型额度接近/触顶
    $alert = 0
    if ($rep.warnings -ne $null) {
        foreach ($w in @($rep.warnings)) {
            if ([int]$w.level -gt $alert) { $alert = [int]$w.level }
        }
    }
    if ($alert -ge 2) {
        $dgroups = (@($rep.warnings) | Where-Object { [int]$_.level -ge 2 } | ForEach-Object { $_.group }) -join '、'
        $global:TTK.UI.Status.Text = '⚠ ' + $dgroups + ' 今日已触发 429 限流'
        $global:TTK.UI.Status.ForeColor = $C_RED
        $global:TTK.UI.Status.Visible = $true
    } elseif ($alert -ge 1) {
        $wgroups = (@($rep.warnings) | Where-Object { [int]$_.level -ge 1 } | ForEach-Object { $_.group }) -join '、'
        $global:TTK.UI.Status.Text = '⚠ ' + $wgroups + ' 接近免费额度上限'
        $global:TTK.UI.Status.ForeColor = $C_AMBER
        $global:TTK.UI.Status.Visible = $true
    } else {
        $global:TTK.UI.Status.Visible = $false
    }
}

# ---------------- 扫描调度 ----------------
$script:ScanProc = $null
$script:Timer = [System.Windows.Forms.Timer]::new()
$script:Timer.Interval = 150
$script:Timer.Add_Tick({
    if ($script:ScanProc -eq $null) { return }
    if ($script:ScanProc.HasExited) {
        $script:Timer.Stop()
        $code = $script:ScanProc.ExitCode
        $script:ScanProc = $null
        $global:TTK.UI.BtnRefresh.Enabled = $true
        Log ('scan done exit=' + $code)
        $rep = Load-Report
        if ($rep -ne $null) {
            $global:TTK.Data = $rep
            Update-UI
        } else {
            $global:TTK.UI.Status.Text = '汇总失败，见 ttk.last.err.txt'
        }
    }
})

function Start-Scan {
    if ($script:ScanProc -ne $null) { return }
    $global:TTK.UI.Status.Text = '正在汇总…'
    $global:TTK.UI.Status.Visible = $true
    $global:TTK.UI.BtnRefresh.Enabled = $false
    $argList = @('-3.11', ('"' + $global:TTK.Py + '"'), '--days', [string]$Days, '--quiet')
    try {
        $script:ScanProc = Start-Process -FilePath 'py' -ArgumentList $argList -PassThru -WindowStyle Hidden -RedirectStandardError $global:TTK.Err
        $script:Timer.Start()
    } catch {
        Log ('start scan failed: ' + $_.Exception.Message)
        $global:TTK.UI.Status.Text = '无法启动 py -3.11'
        $global:TTK.UI.BtnRefresh.Enabled = $true
    }
}

# ---------------- 交互 ----------------
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

$btnRefresh.Add_Click({ Start-Scan })
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

$form.Add_Shown({
    Log ('shown size=' + $global:TTK.UI.Form.Size.Width + 'x' + $global:TTK.UI.Form.Size.Height + ' dpi=' + $global:TTK.UI.Form.DeviceDpi)
    $rep = Load-Report
    if ($rep -ne $null) {
        $global:TTK.Data = $rep
        Update-UI
    }
    Start-Scan
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
