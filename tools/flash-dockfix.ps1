<#
.SYNOPSIS
  Install (or remove) the dock-fix boot image on a OnePlus 8 running LineageOS.

.DESCRIPTION
  Looks at both boot slots, works out which LineageOS build each one holds by
  comparing its hash with the boot.img hashes on download.lineageos.org, and
  writes the matching dock-fix image from this repository's GitHub releases.
  Run it after installing a LineageOS update (before or after rebooting).

  Needs: adb in PATH, USB debugging, a userdebug build (adb root).

.PARAMETER Yes      Do not ask for confirmation.
.PARAMETER Reboot   Reboot the phone when done.
.PARAMETER Restore  Put the stock LineageOS boot.img back instead.
.PARAMETER Force    Treat the running slot as the running build even if its
                    boot partition is not recognised (e.g. a hand-built image).
#>
[CmdletBinding()]
param(
    [switch]$Yes,
    [switch]$Reboot,
    [switch]$Restore,
    [switch]$Force,
    [string]$Repo = "HPotty36/oneplus8-lineage-dock-fixes"
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Device = "instantnoodle"
$LineageApi = "https://download.lineageos.org/api/v2/devices/$Device/builds"
$Cache = Join-Path $PSScriptRoot "cache"
$Remote = "/data/local/tmp/dockfix-boot.img"
New-Item -ItemType Directory -Force -Path $Cache | Out-Null

$AdbExe = (Get-Command adb -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (-not $AdbExe) { throw "adb not found in PATH" }

function Invoke-Adb {
    $ErrorActionPreference = "Continue"   # adb writes progress to stderr
    $out = & $AdbExe @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "adb $($args -join ' ') failed: $out" }
    return ($out | Out-String).Trim()
}
function Sh([string]$cmd) { return Invoke-Adb shell $cmd }
function PartHash([string]$slot, [long]$size) {
    if ($size -gt 0) { $h = Sh "head -c $size /dev/block/by-name/boot$slot | sha256sum" }
    else { $h = Sh "sha256sum /dev/block/by-name/boot$slot" }
    return $h.Split(" ")[0]
}
function GetJson([string]$url) {
    $r = Invoke-WebRequest -Uri $url -UseBasicParsing -Headers @{ "User-Agent" = "flash-dockfix" }
    $c = $r.Content
    if ($c -is [byte[]]) { $c = [Text.Encoding]::UTF8.GetString($c) }
    return $c | ConvertFrom-Json
}
function Fetch([string]$url, [string]$sha, [string]$name) {
    $path = Join-Path $Cache $name
    if (-not (Test-Path $path) -or (Get-FileHash $path -Algorithm SHA256).Hash.ToLower() -ne $sha) {
        Write-Host "  downloading $name ..."
        Invoke-WebRequest -Uri $url -OutFile $path -UseBasicParsing
    }
    if ((Get-FileHash $path -Algorithm SHA256).Hash.ToLower() -ne $sha) { throw "${name}: sha256 mismatch" }
    return $path
}

# --- phone ---------------------------------------------------------------
Invoke-Adb wait-for-device | Out-Null
$codename = Sh "getprop ro.lineage.device"
if ($codename -ne $Device) { throw "Connected device is '$codename', expected $Device" }
$running = Sh "getprop ro.lineage.version"
$curSlot = Sh "getprop ro.boot.slot_suffix"
Invoke-Adb root | Out-Null
Start-Sleep -Seconds 2
Invoke-Adb wait-for-device | Out-Null
if ((Sh "id -u") -ne "0") { throw "adb root is not available (needs a userdebug build)" }
Write-Host "Phone: $running, running slot $curSlot"

# --- what exists ---------------------------------------------------------
$stock = @{}      # stock boot sha256 -> build
foreach ($b in (Invoke-RestMethod $LineageApi -TimeoutSec 60)) {
    $f = $b.files | Where-Object { $_.filename -eq "boot.img" }
    if ($f) { $stock[$f.sha256] = [pscustomobject]@{ Date = $b.date.Replace("-", ""); Url = $f.url; Sha = $f.sha256 } }
}

$byImage = @{}    # dock-fix image sha256 -> release info
$byDate = @{}     # lineage date -> newest dock-fix release
$releases = GetJson "https://api.github.com/repos/$Repo/releases?per_page=100"
foreach ($r in ($releases | Sort-Object published_at)) {
    $infoAsset = $r.assets | Where-Object { $_.name -eq "build-info.json" }
    if (-not $infoAsset) { continue }
    $info = GetJson $infoAsset.browser_download_url
    $img = $r.assets | Where-Object { $_.name -eq $info.image }
    if (-not $img) { continue }
    $rel = [pscustomobject]@{
        Tag = $r.tag_name; Date = $info.lineage_date; Patch = $info.patch_version
        Name = $info.image; Sha = $info.image_sha256; Size = [long]$info.image_size
        Url = $img.browser_download_url; StockSha = $info.stock_boot_sha256
    }
    $byImage[$rel.Sha] = $rel
    $byDate[$rel.Date] = $rel          # sorted by date published: newest wins
}

# --- slots ---------------------------------------------------------------
$plan = @()
foreach ($slot in "_a", "_b") {
    $full = PartHash $slot 0
    $state = "unknown"; $date = $null; $have = $null
    if ($stock.ContainsKey($full)) {
        $state = "stock"; $date = $stock[$full].Date
    } else {
        foreach ($size in ($byImage.Values | ForEach-Object { $_.Size } | Sort-Object -Unique)) {
            $h = PartHash $slot $size
            if ($byImage.ContainsKey($h)) { $have = $byImage[$h]; $state = "dockfix"; $date = $have.Date; break }
        }
    }
    if ($state -eq "unknown" -and $Force -and $slot -eq $curSlot) {
        $date = ($running -split "-")[1]; $state = "forced"
    }
    $label = if ($have) { "dock-fix $($have.Tag)" } elseif ($date) { "$state, build $date" } else { $state }
    Write-Host ("  boot{0}: {1}" -f $slot, $label)

    if ($Restore) {
        if ($state -in "dockfix", "forced") {
            $s = $stock.Values | Where-Object { $_.Date -eq $date } | Select-Object -First 1
            if ($s) { $plan += [pscustomobject]@{ Slot = $slot; What = "stock boot.img $date"; Url = $s.Url; Sha = $s.Sha; Name = "boot-stock-$date.img"; Size = 0 } }
            else { Write-Warning "boot${slot}: stock boot.img for $date is no longer on download.lineageos.org" }
        }
        continue
    }
    if (-not $date) { continue }
    $want = $byDate[$date]
    if (-not $want) {
        Write-Warning "boot${slot}: no dock-fix image for build $date yet. Run: gh workflow run build-dockfix-boot.yml -R $Repo -f date=$date"
        continue
    }
    if ($have -and $have.Sha -eq $want.Sha) { continue }   # already up to date
    $plan += [pscustomobject]@{ Slot = $slot; What = "dock-fix $($want.Tag)"; Url = $want.Url; Sha = $want.Sha; Name = $want.Name; Size = $want.Size }
}

if ($plan.Count -eq 0) { Write-Host "Nothing to do."; exit 0 }
Write-Host ""
$plan | ForEach-Object { Write-Host ("  write {0} -> boot{1}" -f $_.What, $_.Slot) }
if (-not $Yes) {
    $answer = Read-Host "Proceed? [y/N]"
    if ($answer -notmatch "^[yY]") { Write-Host "Aborted."; exit 1 }
}

# --- flash ---------------------------------------------------------------
foreach ($p in $plan) {
    $local = Fetch $p.Url $p.Sha $p.Name
    Write-Host "  boot$($p.Slot): pushing $($p.Name)"
    Invoke-Adb push $local $Remote | Out-Null
    if ((Sh "sha256sum $Remote").Split(" ")[0] -ne $p.Sha) { throw "pushed file is corrupt" }
    Sh "dd if=$Remote of=/dev/block/by-name/boot$($p.Slot) bs=4194304 conv=fsync && sync" | Out-Null
    Sh "rm -f $Remote" | Out-Null
    if ((PartHash $p.Slot $p.Size) -ne $p.Sha) { throw "boot$($p.Slot): verification failed after writing!" }
    Write-Host "  boot$($p.Slot): written and verified"
}

if ($Reboot) { Write-Host "Rebooting ..."; Invoke-Adb reboot | Out-Null }
else { Write-Host "Done. The change takes effect on the next reboot." }
