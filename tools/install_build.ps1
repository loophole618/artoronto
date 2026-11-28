<#
Fetch the newest green iOS build and install it on the iPhone through Sideloadly - no dragging,
no cable when the phone is on the home Wi-Fi.

    powershell -ExecutionPolicy Bypass -File tools\install_build.ps1                  # newest green main
    powershell -ExecutionPolicy Bypass -File tools\install_build.ps1 -Branch city
    powershell -ExecutionPolicy Bypass -File tools\install_build.ps1 -Run 42          # a run number
    powershell -ExecutionPolicy Bypass -File tools\install_build.ps1 -DownloadOnly
    powershell -ExecutionPolicy Bypass -File tools\install_build.ps1 -Usb             # prefer the cable

1. GitHub: the newest successful "iOS build" run for the branch (or run -Run), its .ipa saved
   flat as Downloads\ARToronto-HelloAR-<run>-<sha>.ipa (kept if already there).
2. Sideloadly (it has no command line): loads that file through its own Open dialog, picks the
   phone (@Wi-Fi first unless -Usb), presses Start and reads its status line until "Done." or an
   error. Everything goes through UI Automation (the desktop-uia skill): no mouse, no keystrokes,
   the screen badge shows Blue while it works. Signing stays with the Apple ID already saved in
   Sideloadly. A dialog Sideloadly raises is reported and left open for a human.
Needs: gh (logged in), Sideloadly, and the Skyhook commons desktop-uia + screen-badge skills.
If the phone won't show: wake it on the home Wi-Fi; if it still won't, turn its Wi-Fi off and on
AND restart Sideloadly (its device list can go stale; 2026-11-28 it took both).
#>
param(
    [string]$Branch = 'main',
    [int]$Run = 0,
    [switch]$DownloadOnly,
    [switch]$Usb,
    [int]$DeviceWaitSec = 90,
    [int]$InstallTimeoutSec = 600
)
$ErrorActionPreference = 'Stop'
$Repo = 'loophole618/artoronto'
$Downloads = Join-Path $env:USERPROFILE 'Downloads'

# ---------------------------------------------------------------- 1. the build
$fields = 'databaseId,number,headSha,headBranch,displayTitle,conclusion,createdAt'
if ($Run -gt 0) {
    $r = gh run list -R $Repo --workflow ios-build.yml --limit 100 --json $fields | ConvertFrom-Json |
        Where-Object { $_.number -eq $Run } | Select-Object -First 1
    if (-not $r) { throw "no iOS build run #$Run" }
    if ($r.conclusion -ne 'success') { throw "run #$Run is '$($r.conclusion)', not a green build" }
} else {
    $r = gh run list -R $Repo --workflow ios-build.yml --branch $Branch --status success --limit 1 --json $fields |
        ConvertFrom-Json | Select-Object -First 1
    if (-not $r) { throw "no green iOS build on branch '$Branch'" }
}
$sha = $r.headSha.Substring(0, 7)
$ipa = Join-Path $Downloads "ARToronto-HelloAR-$($r.number)-$sha.ipa"
Write-Host "build $($r.number)-$sha on $($r.headBranch): $($r.displayTitle)"
if (Test-Path $ipa) {
    Write-Host "  already downloaded: $ipa"
} else {
    $tmp = Join-Path $env:TEMP "artoronto-run-$($r.databaseId)"
    if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
    gh run download $r.databaseId -R $Repo -D $tmp
    if ($LASTEXITCODE -ne 0) { throw "download of run $($r.databaseId) failed" }
    $found = Get-ChildItem $tmp -Recurse -Filter *.ipa | Select-Object -First 1
    if (-not $found) { throw "run $($r.databaseId) has no .ipa in its artifacts" }
    Copy-Item $found.FullName $ipa
    Remove-Item -Recurse -Force $tmp
    Write-Host "  saved: $ipa"
}
if ($DownloadOnly) { return }

# ---------------------------------------------------------------- 2. Sideloadly
$C = Join-Path $env:USERPROFILE '.claude\skye\commons\skills'
. (Join-Path $C 'desktop-uia\DesktopUia.ps1')
$badge = Join-Path $C 'screen-badge\Set-Badge.ps1'
Add-Type -Namespace ArtorontoTools -Name InstallBuildNative -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern System.IntPtr SendMessage(System.IntPtr hWnd, int msg, System.IntPtr wParam, string lParam);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, EntryPoint = "SendMessageW")]
static extern System.IntPtr SendGetText(System.IntPtr hWnd, int msg, System.IntPtr wParam, System.Text.StringBuilder lParam);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
public static string GetText(System.IntPtr hWnd) {
    var sb = new System.Text.StringBuilder(1024);
    SendGetText(hWnd, 0x000D, (System.IntPtr)sb.Capacity, sb);   // WM_GETTEXT works across processes
    return sb.ToString();
}
'@
$TS = [System.Windows.Automation.TreeScope]
$CT = [System.Windows.Automation.ControlType]

function Get-All($root, $type) {
    $cond = New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::ControlTypeProperty), $type
    @($root.FindAll($TS::Descendants, $cond))
}
function Clean([string]$s) { ($s -replace "[​‌‍﻿]", '').Trim() }
# Status line = the lowest label that isn't a field caption or the percentage.
function Read-Status($win) {
    $texts = Get-All $win $CT::Text | Where-Object { $_.Current.Name -notin @('iDevice:', 'Apple ID:') }
    $pct = ($texts | Where-Object { $_.Current.Name -match '^\d+%$' } | Select-Object -First 1)
    $st = $texts | Where-Object { $_.Current.Name -notmatch '^\d+%$' } |
        Sort-Object { $_.Current.BoundingRectangle.Y } | Select-Object -Last 1
    [pscustomobject]@{ Text = if ($st) { Clean $st.Current.Name } else { '' }; Pct = if ($pct) { $pct.Current.Name } else { '' } }
}

& $badge Blue | Out-Null
try {
    $p = Get-Process sideloadly -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $p) {
        $p = Start-OwnedProcess -FilePath (Join-Path $env:LOCALAPPDATA 'Sideloadly\sideloadly.exe') -KeepFocus
        Write-Host "  started Sideloadly"
    }
    # A minimized window sits at -32000 and Find-AppWindow skips it: restore it without activating.
    $min = Get-AppWindows $p.Id | Where-Object { $_.Title -like 'Sideloadly*' -and $_.Left -le -30000 } | Select-Object -First 1
    if ($min) { [void][ArtorontoTools.InstallBuildNative]::ShowWindow($min.Hwnd, 4); Start-Sleep -Seconds 1 }   # SW_SHOWNOACTIVATE
    $win = Find-AppWindow -ProcessId $p.Id -TitleRegex '^Sideloadly' -TimeoutSec 30
    if (-not $win) { throw 'Sideloadly window not found' }
    $open = @(Get-Modals $p.Id | Where-Object { $_.Title -ne 'Choose IPA File' })
    if ($open.Count) { throw "Sideloadly has a dialog open: '$($open[0].Title)'. Close it, then run again." }

    # --- the .ipa, through Sideloadly's own Open dialog. The IPA button is the tall one on the left.
    $ps = $null
    $d = Get-Modals $p.Id | Where-Object { $_.Title -eq 'Choose IPA File' } | Select-Object -First 1
    if (-not $d) {
        $ipaButton = Get-All $win $CT::Button | Sort-Object { $_.Current.BoundingRectangle.Height } | Select-Object -Last 1
        # Pressing it opens a modal dialog, and the press may not return until the dialog closes,
        # so press it from a second thread.
        $ps = [PowerShell]::Create()
        [void]$ps.AddScript({ param($b) $b.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() }).AddArgument($ipaButton)
        $press = $ps.BeginInvoke()
        $deadline = (Get-Date).AddSeconds(15)
        while (-not $d -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 300
            $d = Get-Modals $p.Id | Where-Object { $_.Title -eq 'Choose IPA File' } | Select-Object -First 1
        }
        if (-not $d) { throw "Sideloadly's file dialog didn't open" }
        Start-Sleep -Milliseconds 800
    }
    # The Windows Open dialog's file-name box (Edit 1148) and Open button (1) are plain Win32
    # controls that a UIA descendant search can miss, so take them by window handle.
    $kids = @([DesktopUiaNative]::Children($d.Hwnd))
    $edit = $kids | Where-Object { [DesktopUiaNative]::Class($_) -eq 'Edit' -and
        ([System.Windows.Automation.AutomationElement]::FromHandle($_)).Current.AutomationId -eq '1148' } | Select-Object -First 1
    $openBtn = $kids | Where-Object { [DesktopUiaNative]::Class($_) -eq 'Button' -and [DesktopUiaNative]::Text($_) -eq '&Open' } | Select-Object -First 1
    if (-not $edit -or -not $openBtn) { throw "the file dialog has no file-name box / Open button" }
    # The file-name Edit has no ValuePattern, so its text goes in by WM_SETTEXT (a window message,
    # not a keystroke) and is read back; Open is pressed by BM_CLICK, as Clear-Modals does.
    [void][ArtorontoTools.InstallBuildNative]::SendMessage($edit, 0x000C, [IntPtr]::Zero, $ipa)
    $typed = [ArtorontoTools.InstallBuildNative]::GetText($edit)
    if ($typed -ne $ipa) { throw "the file-name box reads '$typed', not the .ipa path" }
    $res = [IntPtr]::Zero
    [void][DesktopUiaNative]::SendMessageTimeout($openBtn, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero, 2, 5000, [ref]$res)
    [void](Wait-Until { -not (Get-Modals $p.Id) } -TimeoutSec 10)
    if ($ps) { try { [void]$ps.EndInvoke($press) } catch { } finally { $ps.Dispose() } }
    $left = @(Get-Modals $p.Id)
    if ($left.Count) { throw "after choosing the file a dialog is open: '$($left[0].Title)'" }
    $want = [IO.Path]::GetFileName($ipa).Substring(0, 12)
    $label = Get-All $win $CT::Text | Where-Object { (Clean $_.Current.Name).StartsWith($want.Substring(0, 8)) } | Select-Object -First 1
    if (-not $label) { throw "Sideloadly doesn't show the .ipa after loading it" }
    Write-Host "  loaded into Sideloadly"

    # --- the phone: @Wi-Fi first (or USB with -Usb), waiting for it to appear.
    $combo = Get-All $win $CT::ComboBox | Where-Object { $_.Current.Name -eq 'iDevice:' } | Select-Object -First 1
    $device = $null
    $deadline = (Get-Date).AddSeconds($DeviceWaitSec)
    $told = $false
    while (-not $device -and (Get-Date) -lt $deadline) {
        $items = @(Get-All $combo $CT::ListItem | ForEach-Object { $_.Current.Name } | Where-Object { $_ -and $_ -notmatch 'no devices' })
        $wifi = $items | Where-Object { $_ -match '@Wi-Fi' }
        $cable = $items | Where-Object { $_ -notmatch '@Wi-Fi' }
        $device = if ($Usb) { @($cable + $wifi)[0] } else { @($wifi + $cable)[0] }
        if (-not $device) {
            if (-not $told) { Write-Host "  waiting for the phone (wake it on the home Wi-Fi; if it was asleep, turn its Wi-Fi off and on)"; $told = $true }
            Start-Sleep -Seconds 3
        }
    }
    if (-not $device) { throw "no phone in Sideloadly after $DeviceWaitSec s. Wake it; if it still won't show, turn the phone's Wi-Fi off and on AND restart Sideloadly, then run again." }
    if ((Get-ControlValue $combo) -ne $device) { Select-ComboItem $combo $device }
    Write-Host "  device: $device"

    $account = Get-All $win $CT::ComboBox | Where-Object { $_.Current.Name -eq 'Apple ID:' } | Select-Object -First 1
    $who = Get-ControlValue $account
    if (-not $who -or $who -match 'Add New Apple ID') { throw 'no Apple ID selected in Sideloadly' }

    # --- Start, then follow the status line.
    $before = (Read-Status $win).Text
    $start = Get-All $win $CT::Button | Where-Object { $_.Current.Name -eq 'Start' } | Select-Object -First 1
    if (-not $start.Current.IsEnabled) { throw 'Start is greyed out' }
    Invoke-Control $start
    Write-Host "  Start pressed"
    $last = ''
    $moved = $false
    $deadline = (Get-Date).AddSeconds($InstallTimeoutSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 700
        $s = Read-Status $win
        $line = "$($s.Text) $($s.Pct)".Trim()
        if ($line -ne $last) { Write-Host "  sideloadly: $line"; $last = $line }
        if ($s.Text -ne $before -or $s.Pct -ne '100%') { $moved = $true }
        $m = @(Get-Modals $p.Id)
        if ($m.Count) {
            $shot = Join-Path $env:TEMP 'sideloadly-dialog.png'
            Save-Screenshot -Path $shot -Hwnd $m[0].Hwnd
            throw "Sideloadly opened a dialog: '$($m[0].Title)' (left open; screenshot $shot)"
        }
        if ($moved -and $s.Text -match '^Done\.?$') {
            Write-Host "INSTALLED build $($r.number)-$sha on $device"
            return
        }
        if ($moved -and $s.Text -match '(?i)error|fail|guru meditation|exception|unable|denied') {
            throw "Sideloadly: $($s.Text)"
        }
    }
    throw "no 'Done.' after $InstallTimeoutSec s; last status: $last"
} finally {
    & $badge Green | Out-Null
}
