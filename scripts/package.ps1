$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path -LiteralPath (Split-Path -Parent $PSScriptRoot)).Path
$outputRoot = Join-Path $projectRoot 'dist'
if ((Test-Path -LiteralPath $outputRoot) -and ((Get-Item -LiteralPath $outputRoot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw '安装包输出目录使用了目录联接或符号链接，停止打包。'
}
New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
$manifest = Get-Content -LiteralPath (Join-Path $projectRoot 'mods-unpacked\Potato-AutoBuild\manifest.json') -Raw -Encoding utf8 | ConvertFrom-Json
$packageRoot = [IO.Path]::GetFullPath((Join-Path $outputRoot ('Potato-AutoBuild-' + $manifest.version_number)))
$buildPath = 'dist\.Potato-AutoBuild-' + [Guid]::NewGuid().ToString('N')
$buildRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot $buildPath))
if ((Split-Path -Parent $packageRoot) -ne $outputRoot -or (Split-Path -Parent $buildRoot) -ne $outputRoot) {
    throw '安装包路径不在指定输出目录内。'
}

$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
if (!(Test-Path -LiteralPath $compiler -PathType Leaf)) { throw '未找到 Windows .NET Framework 自带的 C# 编译器。' }
$installScripts = @('install-common.ps1', 'install.ps1', 'uninstall.ps1')
$modPath = 'mods-unpacked\Potato-AutoBuild'
New-Item -ItemType Directory -Path $buildRoot | Out-Null
try {
    $versionSource = Join-Path $buildRoot 'InstallerVersion.cs'
    [IO.File]::WriteAllText($versionSource, @"
using System.Reflection;

[assembly: AssemblyTitle("土豆兄弟助手安装程序")]
[assembly: AssemblyProduct("土豆兄弟助手")]
[assembly: AssemblyVersion("$($manifest.version_number).0")]
[assembly: AssemblyInformationalVersion("$($manifest.version_number)")]
"@, [Text.UTF8Encoding]::new($true))

    $compilerArguments = @(
        '/nologo', '/target:winexe', '/optimize+', '/codepage:65001',
        '/reference:System.Windows.Forms.dll', '/reference:System.Drawing.dll',
        "/out:$buildPath\Potato-AutoBuild-Setup.exe", 'scripts\installer.cs', "$buildPath\InstallerVersion.cs"
    )
    $compilerArguments += foreach ($name in $installScripts) {
        "/resource:scripts\$name,scripts/$name"
    }
    $compilerArguments += foreach ($file in Get-ChildItem -LiteralPath (Join-Path $projectRoot $modPath) -File) {
        "/resource:$modPath\$($file.Name),mods-unpacked/Potato-AutoBuild/$($file.Name)"
    }
    Push-Location -LiteralPath $projectRoot
    try {
        $compilerOutput = & $compiler @compilerArguments
        if ($LASTEXITCODE -ne 0) { throw "编译安装程序失败。`n$($compilerOutput -join "`n")" }
    } finally {
        Pop-Location
    }
    Remove-Item -LiteralPath $versionSource

    $paths = @('mods-unpacked', 'README.md', '安装.cmd', '卸载.cmd') | ForEach-Object { Join-Path $projectRoot $_ }
    Copy-Item -LiteralPath $paths -Destination $buildRoot -Recurse -Force
    $scriptTarget = New-Item -ItemType Directory -Path (Join-Path $buildRoot 'scripts')
    foreach ($name in ($installScripts + 'package.ps1' + 'installer.cs')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $scriptTarget.FullName
    }
    $docsTarget = New-Item -ItemType Directory -Path (Join-Path $buildRoot 'docs')
    Copy-Item -LiteralPath (Join-Path $projectRoot 'docs/角色机制覆盖.md') -Destination $docsTarget.FullName
    Copy-Item -LiteralPath (Join-Path $projectRoot 'reference') -Destination $buildRoot -Recurse

    if (Test-Path -LiteralPath $packageRoot) {
        $links = @(Get-Item -LiteralPath $packageRoot -Force; Get-ChildItem -LiteralPath $packageRoot -Recurse -Force) |
            Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }
        if ($links) { throw '已有安装目录含目录联接或符号链接，停止替换。' }
        Remove-Item -LiteralPath $packageRoot -Recurse -Force
    }
    Move-Item -LiteralPath $buildRoot -Destination $packageRoot
} finally {
    if (Test-Path -LiteralPath $buildRoot) { Remove-Item -LiteralPath $buildRoot -Recurse -Force }
}
Write-Output $packageRoot
