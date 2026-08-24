# 从 tool/build/logo.png（1024x1024）生成三端应用图标：
#   Windows: windows/runner/resources/app_icon.ico（256 PNG 内嵌）
#   Android: android/app/src/main/res/mipmap-*/ic_launcher.png
#   iOS:     ios/Runner/Assets.xcassets/AppIcon.appiconset/*.png
# 用法: powershell -ExecutionPolicy Bypass -File tool/gen_icons.ps1
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$src = Join-Path $PSScriptRoot 'build\logo.png'
if (-not (Test-Path $src)) { throw "missing ${src}（先运行 flutter test --update-goldens tool/icon_render_test.dart）" }
$root = Split-Path $PSScriptRoot -Parent

function Resize-Png([string]$outPath, [int]$size) {
    $dir = Split-Path $outPath -Parent
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $bmp = New-Object System.Drawing.Bitmap $src
    $resized = New-Object System.Drawing.Bitmap $size, $size
    $g = [System.Drawing.Graphics]::FromImage($resized)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.DrawImage($bmp, 0, 0, $size, $size)
    $resized.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $resized.Dispose(); $bmp.Dispose()
    Write-Host "  $outPath ($size)"
}

# ---------- Android ----------
Write-Host '== Android mipmap =='
$res = Join-Path $root 'android\app\src\main\res'
Resize-Png (Join-Path $res 'mipmap-mdpi\ic_launcher.png') 48
Resize-Png (Join-Path $res 'mipmap-hdpi\ic_launcher.png') 72
Resize-Png (Join-Path $res 'mipmap-xhdpi\ic_launcher.png') 96
Resize-Png (Join-Path $res 'mipmap-xxhdpi\ic_launcher.png') 144
Resize-Png (Join-Path $res 'mipmap-xxxhdpi\ic_launcher.png') 192

# ---------- iOS ----------
Write-Host '== iOS AppIcon =='
$icons = Join-Path $root 'ios\Runner\Assets.xcassets\AppIcon.appiconset'
$iosSizes = @{
    'Icon-App-20x20@1x.png' = 20; 'Icon-App-20x20@2x.png' = 40; 'Icon-App-20x20@3x.png' = 60
    'Icon-App-29x29@1x.png' = 29; 'Icon-App-29x29@2x.png' = 58; 'Icon-App-29x29@3x.png' = 87
    'Icon-App-40x40@1x.png' = 40; 'Icon-App-40x40@2x.png' = 80; 'Icon-App-40x40@3x.png' = 120
    'Icon-App-60x60@2x.png' = 120; 'Icon-App-60x60@3x.png' = 180
    'Icon-App-76x76@1x.png' = 76; 'Icon-App-76x76@2x.png' = 152
    'Icon-App-83.5x83.5@2x.png' = 167
    'Icon-App-1024x1024@1x.png' = 1024
}
foreach ($name in $iosSizes.Keys) {
    Resize-Png (Join-Path $icons $name) $iosSizes[$name]
}

# ---------- Windows ----------
Write-Host '== Windows ico =='
$icoPath = Join-Path $root 'windows\runner\resources\app_icon.ico'
$pngBytes = [System.IO.File]::ReadAllBytes($src)
$ms = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter($ms)
$bw.Write([UInt16]0)          # reserved
$bw.Write([UInt16]1)          # type = icon
$bw.Write([UInt16]1)          # count = 1
$bw.Write([Byte]0)            # width 0 = 256
$bw.Write([Byte]0)            # height 0 = 256
$bw.Write([Byte]0)            # palette
$bw.Write([Byte]0)            # reserved
$bw.Write([UInt16]1)          # planes
$bw.Write([UInt16]32)         # bpp
$bw.Write([UInt32]$pngBytes.Length)  # data size
$bw.Write([UInt32]22)         # data offset
$bw.Write($pngBytes)
$bw.Flush()
[System.IO.File]::WriteAllBytes($icoPath, $ms.ToArray())
$bw.Dispose(); $ms.Dispose()
Write-Host "  ${icoPath} (PNG-in-ICO 256)"

Write-Host '== done =='
