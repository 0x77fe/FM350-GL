#Requires -Version 5.1
<#
  download.ps1 —— 下载离线依赖包（ipk 体系）到本目录并逐一校验
  在**联网的 Windows 机器**上执行（Windows PowerShell 5.1 / PowerShell 7 均可，不需要 Git Bash 或 WSL）

  与同目录 download.sh 等价：同一份 SHA256SUMS、同一套镜像回落顺序、同样"校验不过不落盘"的策略。
  Linux / macOS，或装了 Git Bash / WSL 的 Windows 机器，直接用 `sh download.sh` 亦可（两者产物相同）。

  目标固件：ImmortalWrt 24.10.x x86_64（kernel 6.6.122，kmods ABI 6.6.122-1-e7e50fbc0aafa7443418a79928da2602）

  用法（在仓库根目录）：
      powershell -ExecutionPolicy Bypass -File dist\deps-ipk\download.ps1     # 下载 + 校验 17 个依赖，并取回主包
      # 生成的目录里会同时有：17 个第三方依赖（从官方镜像）+ 预编译主包（从本项目的 GitHub Release）
      # 打包送到路由器（Windows 自带 bsdtar 与 OpenSSH；PowerShell 里的 tar 管道会损坏二进制，所以先打包再传）：
      tar -czf "$env:TEMP\deps-ipk.tar.gz" -C dist\deps-ipk .
      scp -O "$env:TEMP\deps-ipk.tar.gz" root@<router>:/tmp/
      ssh root@<router> "mkdir -p /tmp/deps-ipk && tar -xzf /tmp/deps-ipk.tar.gz -C /tmp/deps-ipk"
      ssh root@<router> "sh /tmp/deps-ipk/install_all.sh"

  参数（命令行优先，其次环境变量，最后默认值）：
      -Version  固件版本       $env:FM350_VER      默认 24.10.5（换版本要同时换一套 SHA256SUMS 与主包）
      -Abi      kmods ABI      $env:FM350_ABI      默认 6.6.122-1-e7e50fbc0aafa7443418a79928da2602
      -Mirrors  镜像列表       $env:FM350_MIRRORS  空格分隔，按顺序尝试，默认 NJU → USTC → PKU → 官方
      -ReleaseBase 主包来源前缀 $env:FM350_RELEASE_BASE 默认本项目 Release 的 latest/download
                   （GitHub 慢/不可达时换成镜像或代理前缀重跑）
      设 $env:FM350_NO_APP=1 则跳过取主包（只要依赖时用）

  说明：
    · 仓库**不含二进制**：包名与 sha256 固定在 SHA256SUMS 里，本脚本按清单逐个下载并校验，
      只有校验通过才会留下文件（不会留下半成品或被篡改的包）；
    · kmod 与固件内核 ABI 强绑定，装错版本 opkg 会拒绝；odhcp6c / odhcpd-ipv6only 来自 base feed，
      其余（jq / sms-tool）来自 packages feed —— 下面按包名前缀分派下载路径；
    · 本项目自身的包（luci-app-fm350_*.ipk）不在 SHA256SUMS 里：文件名与 sha256 固定在
      APP-SHA256SUMS，本脚本据此从 GitHub Release（预编译产物）取回；也可自行编译后拷进来
      （构建机：sh build/build-ipk.sh）。
#>
[CmdletBinding()]
param(
	[string]$Version     = $env:FM350_VER,
	[string]$Abi         = $env:FM350_ABI,
	[string]$Mirrors     = $env:FM350_MIRRORS,
	[string]$ReleaseBase = $env:FM350_RELEASE_BASE
)

$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot

if ([string]::IsNullOrEmpty($Version)) { $Version = '24.10.5' }
if ([string]::IsNullOrEmpty($Abi))     { $Abi     = '6.6.122-1-e7e50fbc0aafa7443418a79928da2602' }
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

Write-Host ('== 目标固件 {0} / ABI {1} ==' -f $Version, $Abi)
$ok = 0; $fail = 0
foreach ($e in $entries) {
	$f = $e.File
	if ($f -like 'kmod-*') {
		$rel = "targets/x86/64/kmods/$Abi/$f"
	} elseif ($f -like 'odhcp*') {
		$rel = "packages/x86_64/base/$f"
	} else {
		$rel = "packages/x86_64/packages/$f"
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
		Write-Host ('  下载  {0,-58} <- {1}' -f $f, $got)
		$ok++
	} else {
		Write-Host ('  失败  {0}（所有镜像都下不到，或 sha256 不符）' -f $f)
		$fail++
	}
}

Write-Host ('== 依赖：成功 {0} 个，失败 {1} 个 ==' -f $ok, $fail)
if ($fail -gt 0) { exit 1 }

Write-Host ''
# ---- 主包：本目录已有就跳过；没有则按 APP-SHA256SUMS 从 GitHub Release 取回预编译产物 ----
$appFile = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'luci-app-fm350_*.ipk') -File -ErrorAction SilentlyContinue) | Select-Object -First 1
$appSums = Join-Path $PSScriptRoot 'APP-SHA256SUMS'

if ($appFile) {
	Write-Host ('== 主包已在本目录：{0}（{1} 字节）==' -f $appFile.Name, $appFile.Length)
} elseif ($env:FM350_NO_APP) {
	Write-Host '== 跳过主包（FM350_NO_APP 已设）=='
} elseif (Test-Path -LiteralPath $appSums) {
	$line = Get-Content -LiteralPath $appSums | Where-Object { $_ -match '\S' } | Select-Object -First 1
	if ($line -match '^\s*([0-9a-fA-F]{64})\s+\*?(.+?)\s*$') {
		$want = $Matches[1].ToLowerInvariant()
		$name = $Matches[2] -replace '^\./', '' -replace '^\.\\', ''
		$tmpName = "$name.new"
		Write-Host ('== 主包不在本目录 → 从 Release 取：{0} ==' -f $name)
		$ok2 = $false
		for ($tryN = 1; $tryN -le 3; $tryN++) {
			try {
				Invoke-WebRequest -Uri "$ReleaseBase/$name" -OutFile $tmpName -UseBasicParsing -TimeoutSec 600
				if ((Test-Path -LiteralPath $tmpName) -and ((Get-Item -LiteralPath $tmpName).Length -gt 0) -and ((Get-Sha256 $tmpName) -eq $want)) {
					Move-Item -LiteralPath $tmpName -Destination $name -Force
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
			Write-Host ('  已取回 {0}（sha256 与 APP-SHA256SUMS 一致）✓' -f $name)
			$appFile = Get-Item -LiteralPath $name
		} else {
			Write-Host '  !! 取不到或校验失败（已重试 3 次）：GitHub 在国内可能很慢或不可达'
			Write-Host '     ① 换镜像/代理重跑：$env:FM350_RELEASE_BASE="<镜像前缀>"; .\download.ps1'
			Write-Host '     ② 在构建机上自行编译后拷进来：sh build/build-ipk.sh && cp dist/luci-app-fm350_*.ipk dist\deps-ipk\'
		}
	}
} else {
	Write-Host '== 缺少 APP-SHA256SUMS，无法确定主包文件名与 sha256 =='
}

if (-not $appFile) {
	Write-Host ''
	Write-Host '== 本目录还不完整（缺主包 luci-app-fm350_*.ipk）：按上面的提示补上后再传路由器 =='
	exit 1
}

Write-Host ''
Write-Host '== 下一步：整个目录传到路由器，再跑 install_all.sh =='
Write-Host '   Windows（仓库根目录执行；PowerShell 里别用 tar 管道，会损坏二进制）：'
Write-Host '     tar -czf "$env:TEMP\deps-ipk.tar.gz" -C dist\deps-ipk .'
Write-Host '     scp -O "$env:TEMP\deps-ipk.tar.gz" root@<router>:/tmp/'
Write-Host '     ssh root@<router> "mkdir -p /tmp/deps-ipk && tar -xzf /tmp/deps-ipk.tar.gz -C /tmp/deps-ipk"'
Write-Host '     ssh root@<router> "sh /tmp/deps-ipk/install_all.sh"'
Write-Host '   Linux（或 Windows 上的 Git Bash / WSL）：'
Write-Host '     tar -czf - -C dist/deps-ipk . | ssh root@<router> "mkdir -p /tmp/deps-ipk && tar -xzf - -C /tmp/deps-ipk"'
Write-Host '     ssh root@<router> "sh /tmp/deps-ipk/install_all.sh"'
exit 0
