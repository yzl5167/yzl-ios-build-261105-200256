# 临时公开仓库编译法：把本机 iOS 源码推到一个新建的**公开**仓库 -> 触发 macOS Runner 免费编译
# -> 把 IPA/TIPA 下载到本地 -> **立刻删掉那个仓库**（编译失败则改成私有保留现场，方便查日志）。
#
# 为什么临时公开：GitHub 只对公开仓库免费放行标准 macOS Runner；私有仓库按 $0.062/分钟计费
# （Free 计划只有 2000 标准分钟/月）。源码因此只在编译那十几分钟里短暂可见，编完即删。
#
#   $env:GITHUB_TOKEN="ghp_..."        # classic token，需要 repo + workflow 作用域
#   powershell -ExecutionPolicy Bypass -File .\YZL-Launcher-iOS\scripts\ephemeral-build.ps1
#   powershell ... -File .\ephemeral-build.ps1 -KeepRepo            # 调试：编完不删
#   powershell ... -File .\ephemeral-build.ps1 -ReuseRepo yzl-ios-build-261105-1930
#
param(
    [string]$RepoPrefix = "yzl-ios-build",
    [string]$RepoName = "",
    [string]$ReuseRepo = "",
    [string]$SourceDir = "YZL-Launcher-iOS",
    [string]$OutputDir = "",
    [string]$Branch = "main",
    [int]$TimeoutMinutes = 35,
    [switch]$KeepRepo
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
[Net.ServicePointManager]::Expect100Continue = $false
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$token = $env:GITHUB_TOKEN
if ([string]::IsNullOrWhiteSpace($token)) { $token = Read-Host "GITHUB_TOKEN（classic，需 repo+workflow）" }
if ([string]::IsNullOrWhiteSpace($token)) { throw "没有令牌，无法继续。" }

$headers = @{
    Authorization          = "Bearer $token"
    Accept                 = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
    "User-Agent"           = "yzl-ios-ephemeral-build"
}
$api  = "https://api.github.com"
$json = "application/json"
$workflowFile = "build-ipa.yml"
$wantedArtifacts = @('YZLLauncher-unsigned-ipa', 'YZLLauncher-trollstore-tipa')

function Invoke-Post($uri, $body) {
    Invoke-RestMethod -Uri $uri -Headers $headers -Method Post -Body ($body | ConvertTo-Json -Depth 8) -ContentType $json
}
function Invoke-Patch($uri, $body) {
    Invoke-RestMethod -Uri $uri -Headers $headers -Method Patch -Body ($body | ConvertTo-Json -Depth 8) -ContentType $json
}
function Invoke-Put($uri, $body) {
    Invoke-RestMethod -Uri $uri -Headers $headers -Method Put -Body ($body | ConvertTo-Json -Depth 8) -ContentType $json
}
function Try-Get($uri) {
    try { return Invoke-RestMethod -Uri $uri -Headers $headers } catch { return $null }
}
function Parse-RunDate($value) {
    return [DateTime]::Parse($value, [System.Globalization.CultureInfo]::InvariantCulture).ToUniversalTime()
}
function Show-FailureLogs($run) {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("yzl-ios-logs-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        $zip = Join-Path $tmp "logs.zip"
        Invoke-WebRequest -Uri "$($run.url)/logs" -Headers $headers -OutFile $zip
        Expand-Archive -Path $zip -DestinationPath (Join-Path $tmp "out") -Force
        $hits = @(Get-ChildItem -LiteralPath (Join-Path $tmp "out") -Recurse -File -Filter *.txt |
            Select-String -Pattern "error:|fatal error|The following build commands failed" |
            Select-Object -First 40)
        if ($hits.Count -eq 0) {
            Write-Host "      日志里没匹配到 error:，完整日志包在 $tmp"
        } else {
            Write-Host "      ---- 编译错误摘录 ----"
            foreach ($h in $hits) { Write-Host ("      {0}" -f $h.Line.Trim()) }
            Write-Host "      ---- 摘录结束 ----"
        }
    } catch {
        Write-Host "      拉日志失败：$($_.Exception.Message)"
    }
}

Write-Host "[1/7] 校验令牌与目录"
$me = Invoke-RestMethod -Uri "$api/user" -Headers $headers
$owner = $me.login
$projDir = (Resolve-Path (Join-Path (Get-Location) $SourceDir)).Path
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path ([Environment]::GetFolderPath('Desktop')) 'YZL-iOS-builds'
}
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
Write-Host "      账号 $owner / 源码 $projDir / 产物 $OutputDir"

if (-not [string]::IsNullOrWhiteSpace($ReuseRepo)) {
    $RepoName = $ReuseRepo
    $repoUri = "$api/repos/$owner/$RepoName"
    $repo = Try-Get $repoUri
    if ($null -eq $repo) { throw "找不到要复用的仓库 $owner/$RepoName" }
    Write-Host "[2/7] 复用仓库 $owner/$RepoName，临时转为公开（只有公开仓库的 macOS Runner 免费）"
    Invoke-Patch $repoUri @{ private = $false } | Out-Null
} else {
    if ([string]::IsNullOrWhiteSpace($RepoName)) {
        $RepoName = "{0}-{1}" -f $RepoPrefix, (Get-Date).ToString('yyMMdd-HHmmss')
    }
    Write-Host "[2/7] 新建公开仓库 $owner/$RepoName"
    Invoke-Post "$api/user/repos" @{
        name         = $RepoName
        private      = $false
        auto_init    = $false
        has_issues   = $false
        has_wiki     = $false
        has_projects = $false
        description  = "TEMP public build mirror for YZL Launcher iOS. Deleted right after the artifact is downloaded."
    } | Out-Null
    $repoUri = "$api/repos/$owner/$RepoName"
}

Write-Host "[3/7] 建 $Branch 分支（先塞一个 README，Git Data API 需要 parent commit）"
$readmePath = Join-Path $projDir "README.md"
if (Test-Path $readmePath) {
    $seed = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($readmePath))
} else {
    $seed = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("# YZL Launcher iOS (temp build mirror)`n"))
}
Invoke-Put "$repoUri/contents/README.md" @{
    message = "chore: seed temp build mirror"
    content = $seed
} | Out-Null

Write-Host "[4/7] 上传源码树"
$skipDirs = @('\.git\', '\build\', '\build-test\', '\build-output\', '\dist\', '\bin\', '\obj\', '\node_modules\', '\.deriveddata\')
$skipExt  = @('.ipa', '.tipa', '.zip', '.exe', '.dll', '.log')
$all = @(Get-ChildItem -LiteralPath $projDir -Recurse -File)
$files = @($all | Where-Object {
    $path = $_.FullName
    $hit = $false
    foreach ($s in $skipDirs) { if ($path -like ('*' + $s + '*')) { $hit = $true; break } }
    (-not $hit) -and ($skipExt -notcontains $_.Extension)
})
Write-Host "      $($files.Count) 个文件（本地共 $($all.Count) 个，已排除 build-output 与二进制产物）"
$tree = @()
$n = 0
foreach ($f in $files) {
    $n++
    Write-Progress -Activity "upload" -Status $f.Name -PercentComplete ($n * 100 / $files.Count)
    $b64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($f.FullName))
    $sha = (Invoke-Post "$repoUri/git/blobs" @{ content = $b64; encoding = "base64" }).sha
    $rel = $f.FullName.Substring($projDir.Length + 1) -replace "\\", "/"
    $mode = if ($rel -match '\.sh$') { "100755" } else { "100644" }
    $tree += @{ path = $rel; mode = $mode; type = "blob"; sha = $sha }
}
Write-Progress -Activity "upload" -Completed
$rootTree = Invoke-Post "$repoUri/git/trees" @{ tree = $tree }
$parent = Invoke-RestMethod -Uri "$repoUri/git/ref/heads/$Branch" -Headers $headers
$commit = Invoke-Post "$repoUri/git/commits" @{
    message = "temp build mirror (ephemeral): $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') local time"
    tree    = $rootTree.sha
    parents = @($parent.object.sha)
}
Invoke-Patch "$repoUri/git/refs/heads/$Branch" @{ sha = $commit.sha; force = $true } | Out-Null
Write-Host "      commit $($commit.sha.Substring(0,7)) on $Branch"

Write-Host "[5/7] 触发 $workflowFile 并等待 macOS 构建（通常 5-20 分钟）"
$sinceUtc = [DateTime]::UtcNow.AddMinutes(-2)
Invoke-Post "$repoUri/actions/workflows/$workflowFile/dispatches" @{ ref = $Branch } | Out-Null
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$run = $null
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 20
    $runs = Try-Get "$repoUri/actions/runs?branch=$Branch&per_page=20"
    if ($null -eq $runs) { continue }
    $fresh = @($runs.workflow_runs | Where-Object { (Parse-RunDate $_.created_at) -ge $sinceUtc } |
        Sort-Object { Parse-RunDate $_.created_at } -Descending)
    if ($fresh.Count -eq 0) { Write-Host "      还没排队上"; continue }
    $run = $fresh[0]
    Write-Host ("      run {0}: {1} / {2}" -f $run.id, $run.status, $run.conclusion)
    if ($run.status -eq "completed") { break }
}
if ($null -eq $run -or $run.status -ne "completed") {
    Write-Host "      超时了（$TimeoutMinutes 分钟）。仓库 $RepoName 转成私有保留现场，别再公开挂着。"
    Invoke-Patch $repoUri @{ private = $true } | Out-Null
    throw "构建超时；可用 -ReuseRepo $RepoName 重试"
}

Write-Host "[6/7] 下载产物到 $OutputDir"
$ok = ($run.conclusion -eq "success")
if (-not $ok) { Write-Host "      构建结论是 $($run.conclusion)，先抓错误给你看" }
$got = @()
if ($ok) {
    $arts = Try-Get "$($run.url)/artifacts"
    foreach ($name in $wantedArtifacts) {
        $art = @($arts.artifacts | Where-Object { $_.name -eq $name -and -not $_.expired } | Select-Object -First 1)
        if ($art.Count -eq 0) { Write-Host "      没有 artifact：$name（可能这次构建没产出 .tipa）"; continue }
        $a = $art[0]
        $zip = Join-Path $env:TEMP ("yzl-art-" + $a.id + ".zip")
        Invoke-WebRequest -Uri $a.archive_download_url -Headers $headers -OutFile $zip
        $tmpOut = Join-Path $env:TEMP ("yzl-art-" + $a.id)
        if (Test-Path $tmpOut) { Remove-Item -Recurse -Force $tmpOut }
        Expand-Archive -Path $zip -DestinationPath $tmpOut -Force
        Get-ChildItem -LiteralPath $tmpOut -Recurse -File | ForEach-Object {
            $dest = Join-Path $OutputDir $_.Name
            Copy-Item -LiteralPath $_.FullName -Destination $dest -Force
            $got += $dest
        }
        Remove-Item -Force $zip
        Remove-Item -Recurse -Force $tmpOut
    }
    if ($got.Count -gt 0) {
        $info = Join-Path $OutputDir '最新包信息.txt'
        $lines = @()
        $lines += ("生成时间(本地): " + (Get-Date).ToString('s'))
        $lines += ("仓库: $owner/$RepoName   run: $($run.id)   commit: $($run.head_sha)")
        $lines += ("仓库已删除: " + $(if ($KeepRepo) { '否（-KeepRepo）' } else { '是' }))
        foreach ($g in $got) {
            $fi = Get-Item -LiteralPath $g
            $h = (Get-FileHash -LiteralPath $g -Algorithm SHA256).Hash.ToLower()
            $lines += ("{0}  {1:N0} bytes  sha256={2}" -f $fi.Name, $fi.Length, $h)
        }
        [System.IO.File]::WriteAllLines($info, $lines, (New-Object System.Text.UTF8Encoding($true)))
        foreach ($g in $got) {
            $fi = Get-Item -LiteralPath $g
            Write-Host ("      {0}  {1:N0} bytes" -f $fi.Name, $fi.Length)
        }
    }
} else {
    Show-FailureLogs $run
}

Write-Host "[7/7] 收尾：处理临时仓库"
if ($KeepRepo) {
    Write-Host "      -KeepRepo：仓库 $owner/$RepoName 保留（公开状态，记得自己删）"
} elseif ($ok -and $got.Count -gt 0 -and [string]::IsNullOrWhiteSpace($ReuseRepo)) {
    Invoke-RestMethod -Uri $repoUri -Headers $headers -Method Delete | Out-Null
    Write-Host "      已删除临时仓库 $owner/$RepoName（源码不再公开）"
} elseif (-not $ok) {
    Invoke-Patch $repoUri @{ private = $true } | Out-Null
    Write-Host "      构建失败：已把 $owner/$RepoName 转为**私有**保留现场，查完用 -ReuseRepo $RepoName 重试"
} else {
    Invoke-Patch $repoUri @{ private = $true } | Out-Null
    Write-Host "      没拿到产物：先把 $owner/$RepoName 转私有，避免一直公开挂着"
}
Write-Host "DONE"
