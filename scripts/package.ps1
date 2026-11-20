$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path -LiteralPath (Split-Path -Parent $PSScriptRoot)).Path
$outputRoot = Join-Path $projectRoot 'dist'
if ((Test-Path -LiteralPath $outputRoot) -and ((Get-Item -LiteralPath $outputRoot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw '安装包输出目录使用了目录联接或符号链接，停止打包。'
}
New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
$manifest = Get-Content -LiteralPath (Join-Path $projectRoot 'mods-unpacked\Potato-AutoBuild\manifest.json') -Raw -Encoding utf8 | ConvertFrom-Json
$packageRoot = [IO.Path]::GetFullPath((Join-Path $outputRoot ('Potato-AutoBuild-' + $manifest.version_number)))
if ((Split-Path -Parent $packageRoot) -ne $outputRoot) { throw '安装包路径不在指定输出目录内。' }
if (Test-Path -LiteralPath $packageRoot) {
    $links = @(Get-Item -LiteralPath $packageRoot -Force; Get-ChildItem -LiteralPath $packageRoot -Recurse -Force) |
        Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }
    if ($links) { throw '已有安装目录含目录联接或符号链接，停止替换。' }
    Remove-Item -LiteralPath $packageRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $packageRoot | Out-Null
$paths = @('mods-unpacked', 'README.md', '安装.cmd', '卸载.cmd') | ForEach-Object { Join-Path $projectRoot $_ }
Copy-Item -LiteralPath $paths -Destination $packageRoot -Recurse -Force
$scriptTarget = New-Item -ItemType Directory -Path (Join-Path $packageRoot 'scripts')
foreach ($name in @('install-common.ps1', 'install.ps1', 'uninstall.ps1', 'package.ps1')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $scriptTarget.FullName
}
$docsTarget = New-Item -ItemType Directory -Path (Join-Path $packageRoot 'docs')
Copy-Item -LiteralPath (Join-Path $projectRoot 'docs/角色机制覆盖.md') -Destination $docsTarget.FullName
Copy-Item -LiteralPath (Join-Path $projectRoot 'reference') -Destination $packageRoot -Recurse
Write-Output $packageRoot
