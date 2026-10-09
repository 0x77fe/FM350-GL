#Requires -Version 5.1
<#
  download.ps1 —— 下载离线依赖包（apk 体系）到本目录并逐一校验
  在**联网的 Windows 机器**上执行（Windows PowerShell 5.1 / PowerShell 7 均可，不需要 Git Bash 或 WSL）

  与同目录 download.sh 等价：同一份 SHA256SUMS、同一套镜像回落顺序、同样"校验不过不落盘"的策略。
  Linux / macOS，或装了 Git Bash / WSL 的 Windows 机器，直接用 `sh download.sh` 亦可（两者产物相同）。

  目标固件：ImmortalWrt 25.12.x x86/64（kernel 6.12.94，kmods ABI 6.12.94-1-0413601b1c3f0490e17f340fe09229ea）

  用法（在仓库根目录）：
      powershell -ExecutionPolicy Bypass -File dist\deps-apk\download.ps1     # 下载 + 校验 19 个依赖，并取回主包
      # 生成的目录里会同时有：19 个第三方依赖（从官方镜像）+ 预编译主包（从本项目的 GitHub Release）
      # 打包送到路由器（Windows 自带 bsdtar 与 OpenSSH；PowerShell 里的 tar 管道会损坏二进制，所以先打包再传）：
      tar -czf "$env:TEMP\deps-apk.tar.gz" -C dist\deps-apk .
      scp -O "$env:TEMP\deps-apk.tar.gz" root@<router>:/tmp/
      ssh root@<router> "mkdir -p /tmp/deps-apk && tar -xzf /tmp/deps-apk.tar.gz -C /tmp/deps-apk"
      ssh root@<router> "sh /tmp/deps-apk/install_all.sh"

  参数（命令行优先，其次环境变量，最后本目录 META）：
      -Version  固件版本       $env:FM350_VER      默认取 META 的 FM350_VER（当前 25.12.1）
      -Abi      kmods ABI      $env:FM350_ABI      默认取 META 的 FM350_ABI
      -Target   目标架构       $env:FM350_TARGET   默认取 META 的 FM350_TARGET（x86/64）
      -PkgArch  包架构         $env:FM350_PKGARCH  默认取 META 的 FM350_PKGARCH（x86_64）
      -Mirrors  镜像列表       $env:FM350_MIRRORS  空格分隔，按顺序尝试，默认 NJU → USTC → PKU → 官方
      -ReleaseBase 主包来源前缀 $env:FM350_RELEASE_BASE 默认本项目 Release 的 latest/download
                   （GitHub 慢/不可达时换成镜像或代理前缀重跑）
      设 $env:FM350_NO_APP=1 则跳过取主包（只要依赖时用）
      设 $env:FM350_LOCAL_APP=1 则用本目录里最新的自编主包放行（跳过发布哈希校验）

  说明：
    · 固件版本 / 目标架构 / 包架构 / kmods ABI 都从同目录 META 读取（与 download.sh 同一份），
      同名环境变量或参数优先；换固件版本时改 META 即可，不用动脚本；
    · 仓库**不含二进制**：包名与 sha256 固定在 SHA256SUMS 里，本脚本按清单逐个下载并校验，
      只有校验通过才会留下文件（不会留下半成品或被篡改的包）；
    · 镜像只按文件名直取（不依赖目录列表）：NJU 列表完整故作默认首位，USTC/PKU/官方作后备；
    · 本项目自身的包（luci-app-fm350-*.apk）不在 SHA256SUMS 里：文件名与 sha256 固定在
      APP-SHA256SUMS，本脚本只认清单里的确切文件名与哈希（旧包、损坏包不跳过），据此从
      GitHub Release（预编译产物）取回；也可自行编译后拷进来
      （构建机：sh build/build-apk.sh，本地自编包加 FM350_LOCAL_APP=1 放行）。
#>
[CmdletBinding()]
param(
	[string]$Version     = $env:FM350_VER,
	[string]$Abi         = $env:FM350_ABI,
	[string]$Target      = $env:FM350_TARGET,
	[string]$PkgArch     = $env:FM350_PKGARCH,
	[string]$Mirrors     = $env:FM350_MIRRORS,
	[string]$ReleaseBase = $env:FM350_RELEASE_BASE
)

$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot

# 固件版本、目标架构、包架构与 kmods ABI 来自本目录 META（与 download.sh 同一份）；
# 同名环境变量或同名参数优先。META 是简单的 KEY=value 行，忽略空行与 # 开头的注释行。
function Get-MetaValue([string]$Key) {
	$metaFile = Join-Path $PSScriptRoot 'META'
	if (-not (Test-Path -LiteralPath $metaFile)) { return '' }
	# 必须显式 -Encoding UTF8：PS 5.1 默认按 ANSI（GBK）解码，中文注释的行尾字节会把换行一并吞掉
	foreach ($line in (Get-Content -LiteralPath $metaFile -Encoding UTF8)) {
		if ($line -match '^\s*#') { continue }
		if ($line -match ('^' + [regex]::Escape($Key) + '=(.*)$')) { return $Matches[1].Trim() }
	}
	return ''
}

if ([string]::IsNullOrEmpty($Version)) { $Version = Get-MetaValue 'FM350_VER' }
if ([string]::IsNullOrEmpty($Abi))     { $Abi     = Get-MetaValue 'FM350_ABI' }
if ([string]::IsNullOrEmpty($Target))  { $Target  = Get-MetaValue 'FM350_TARGET' }
if ([string]::IsNullOrEmpty($PkgArch)) { $PkgArch = Get-MetaValue 'FM350_PKGARCH' }
if ([string]::IsNullOrEmpty($Version) -or [string]::IsNullOrEmpty($Abi) -or
    [string]::IsNullOrEmpty($Target) -or [string]::IsNullOrEmpty($PkgArch)) {
	Write-Host '缺少 META（固件版本/架构/ABI）；可用 FM350_VER / FM350_ABI / FM350_TARGET / FM350_PKGARCH 环境变量显式给出'
	exit 1
}

if ([string]::IsNullOrEmpty($Mirrors)) {
	$Mirrors = 'https://mirror.nju.edu.cn/immortalwrt https://mirrors.ustc.edu.cn/immortalwrt https://mirrors.pku.edu.cn/immortalwrt https://downloads.immortalwrt.org'
}
if ([string]::IsNullOrEmpty($ReleaseBase)) { $ReleaseBase = 'https://github.com/0x77fe/FM350-GL/releases/latest/download' }

# PS 5.1 默认可能没开 TLS 1.2（ImmortalWrt 的源只收 TLS 1.2+）；
# 另外 Invoke-WebRequest 的进度条会让下载慢十倍以上，这里关掉
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

$sumsFile = Join-Path $PSScriptRoot 'SHA256SUMS'
if (-not (Test-Path -LiteralPath $sumsFile)) {
	Write-Host '缺少 SHA256SUMS（依赖清单），无法确定要下什么'
	exit 1
}

function Get-Sha256([string]$Path) {
	(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

# SHA256SUMS 是 sha256sum 的输出格式：<64位sha256><空白>./<文件名>
$entries = @()
foreach ($line in (Get-Content -LiteralPath $sumsFile)) {
	if ($line -match '^\s*([0-9a-fA-F]{64})\s+\*?(.+?)\s*$') {
		$file = $Matches[2] -replace '^\./', '' -replace '^\.\\', ''
		$entries += [pscustomobject]@{ Want = $Matches[1].ToLowerInvariant(); File = $file }
	}
}
if ($entries.Count -eq 0) {
	Write-Host 'SHA256SUMS 里没有可识别的条目'
	exit 1
}

$mirrorList = @($Mirrors -split '\s+' | Where-Object { $_ })

Write-Host ('== 目标固件 {0} / {1} / ABI {2} ==' -f $Version, $Target, $Abi)
$ok = 0; $fail = 0
foreach ($e in $entries) {
	$f = $e.File
	if ($f -like 'kmod-*') {
		$rel = "targets/$Target/kmods/$Abi/$f"
	} else {
		$rel = "packages/$PkgArch/packages/$f"
	}

	if ((Test-Path -LiteralPath $f) -and ((Get-Item -LiteralPath $f).Length -gt 0) -and ((Get-Sha256 $f) -eq $e.Want)) {
		Write-Host ('  已有  {0}' -f $f)
		$ok++
		continue
	}

	$got = ''
	foreach ($m in $mirrorList) {
		$tmp = "$f.new"
		try {
			Invoke-WebRequest -Uri "$m/releases/$Version/$rel" -OutFile $tmp -UseBasicParsing -TimeoutSec 300
		} catch {
			if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
			continue
		}
		if ((Test-Path -LiteralPath $tmp) -and ((Get-Item -LiteralPath $tmp).Length -gt 0) -and ((Get-Sha256 $tmp) -eq $e.Want)) {
			Move-Item -LiteralPath $tmp -Destination $f -Force
			$got = $m
			break
		}
		Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
	}

	if ($got) {
		Write-Host ('  下载  {0,-42} <- {1}' -f $f, $got)
		$ok++
	} else {
		Write-Host ('  失败  {0}（所有镜像都下不到，或 sha256 不符）' -f $f)
		$fail++
	}
}

Write-Host ('== 依赖：成功 {0} 个，失败 {1} 个 ==' -f $ok, $fail)
if ($fail -gt 0) { exit 1 }

Write-Host ''
# 主包：按 APP-SHA256SUMS 的确切文件名与 sha256 核验，不跳过旧包 / 损坏包
$appSums = Join-Path $PSScriptRoot 'APP-SHA256SUMS'
$appName = ''    # 清单要求的主包文件名
$appWant = ''    # 清单要求的主包 sha256
if (Test-Path -LiteralPath $appSums) {
	$line = Get-Content -LiteralPath $appSums -ErrorAction SilentlyContinue | Where-Object { $_ -match '\S' } | Select-Object -First 1
	if ($line -match '^\s*([0-9a-fA-F]{64})\s+\*?(.+?)\s*$') {
		$appWant = $Matches[1].ToLowerInvariant()
		$appName = $Matches[2] -replace '^\./', '' -replace '^\.\\', ''
	}
}

$app = ''    # 最终选中的主包文件名；空 = 没选到
if ($env:FM350_NO_APP) {
	Write-Host '== 跳过主包（FM350_NO_APP 已设，只要依赖）=='
} elseif (-not $appName) {
	Write-Host '!! 缺少 APP-SHA256SUMS（主包文件名与 sha256），无法核验主包'
} elseif ((Test-Path -LiteralPath $appName) -and ((Get-Item -LiteralPath $appName).Length -gt 0) -and ((Get-Sha256 $appName) -eq $appWant)) {
	Write-Host ('== 主包已在本目录且校验通过：{0} ==' -f $appName)
	$app = $appName
} elseif ($env:FM350_LOCAL_APP) {
	# 本地自编包：按 -r<release> 的数字取最大（等价 shell 侧的 pick_local_app）
	$localApps = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'luci-app-fm350-*.apk') -File -ErrorAction SilentlyContinue |
		Sort-Object -Property @{ Expression = { [int]([regex]::Match($_.Name, '-r(\d+)').Groups[1].Value) } } -Descending)
	if ($localApps.Count -gt 0) {
		$app = $localApps[0].Name
		Write-Host ('== 跳过发布哈希校验（FM350_LOCAL_APP=1，本地自编包）：{0} ==' -f $app)
	} else {
		Write-Host '!! FM350_LOCAL_APP=1，但本目录没有 luci-app-fm350-*.apk'
	}
} else {
	if (Test-Path -LiteralPath $appName) {
		Write-Host ('== 已有 {0} 与清单哈希不符（旧包或损坏），重新取回 ==' -f $appName)
	}
	Write-Host ('== 从 Release 取主包：{0}（最多 3 次）==' -f $appName)
	$tmpName = "$appName.new"
	$ok2 = $false
	for ($tryN = 1; $tryN -le 3; $tryN++) {
		try {
			Invoke-WebRequest -Uri "$ReleaseBase/$appName" -OutFile $tmpName -UseBasicParsing -TimeoutSec 600
			if ((Test-Path -LiteralPath $tmpName) -and ((Get-Item -LiteralPath $tmpName).Length -gt 0) -and ((Get-Sha256 $tmpName) -eq $appWant)) {
				Move-Item -LiteralPath $tmpName -Destination $appName -Force
				$ok2 = $true
				break
			}
		} catch { }
		if (Test-Path -LiteralPath $tmpName) { Remove-Item -LiteralPath $tmpName -Force -ErrorAction SilentlyContinue }
		if ($tryN -lt 3) {
			Write-Host ('  第 {0}/3 次失败（GitHub 偶发连不上），3 秒后重试…' -f $tryN)
			Start-Sleep -Seconds 3
		}
	}
	if ($ok2) {
		# 清掉不在清单里的旧主包，避免安装器或人工挑错文件
		foreach ($old in @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'luci-app-fm350-*.apk') -File -ErrorAction SilentlyContinue)) {
			if ($old.Name -eq $appName) { continue }
			Write-Host ('  清理不在清单里的主包：{0}' -f $old.Name)
			Remove-Item -LiteralPath $old.FullName -Force -ErrorAction SilentlyContinue
		}
		Write-Host ('  已取回 {0}（sha256 与 APP-SHA256SUMS 一致）✓' -f $appName)
		$app = $appName
	} else {
		Write-Host '  !! 取不到或校验失败（已重试 3 次）：GitHub 在国内可能很慢或不可达'
		Write-Host '     ① 换镜像/代理重跑：$env:FM350_RELEASE_BASE="<镜像前缀>"; .\download.ps1'
		Write-Host '     ② 在构建机上自行编译后拷进来：sh build/build-apk.sh && cp dist/luci-app-fm350-*.apk dist\deps-apk\'
		Write-Host '     ③ 本地自编包用于测试：加 $env:FM350_LOCAL_APP=1 放行，或直接手动拷入'
	}
}

if (-not $app -and -not $env:FM350_NO_APP) {
	Write-Host ''
	Write-Host '== 本目录还不完整（缺清单里的主包）：按上面的提示补上后再传路由器 =='
	exit 1
}

Write-Host ''
Write-Host '== 下一步：整个目录传到路由器，再跑 install_all.sh =='
Write-Host '   Windows（仓库根目录执行；PowerShell 里别用 tar 管道，会损坏二进制）：'
Write-Host '     tar -czf "$env:TEMP\deps-apk.tar.gz" -C dist\deps-apk .'
Write-Host '     scp -O "$env:TEMP\deps-apk.tar.gz" root@<router>:/tmp/'
Write-Host '     ssh root@<router> "mkdir -p /tmp/deps-apk && tar -xzf /tmp/deps-apk.tar.gz -C /tmp/deps-apk"'
Write-Host '     ssh root@<router> "sh /tmp/deps-apk/install_all.sh"'
Write-Host '   Linux（或 Windows 上的 Git Bash / WSL）：'
Write-Host '     tar -czf - -C dist/deps-apk . | ssh root@<router> "mkdir -p /tmp/deps-apk && tar -xzf - -C /tmp/deps-apk"'
Write-Host '     ssh root@<router> "sh /tmp/deps-apk/install_all.sh"'
exit 0
