<#
    run_audit.ps1

    Interactive computer audit, designed to be run from a USB stick.

    Asks the technician a short set of questions, then runs WinAudit and
    CrystalDiskInfo. Everything for one machine lands in a folder named
    after that machine's hostname, created next to this script.

    Launch it through run_audit.bat - that handles elevation and the
    execution policy.

    Layout: the bundled tools all live in apps\, so the root of the stick
    holds only these two scripts, apps\ and RESULTS\.

    Paths: every path is built from $PSScriptRoot, so the drive letter the
    USB stick happens to get is irrelevant. Nothing uses the current
    working directory, which after UAC elevation is C:\Windows\System32.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------
#  Configuration
# ------------------------------------------------------------------

# Categories to collect. Letters are CASE SENSITIVE and several are
# composite - one letter can emit more than one category.
#
#   specs    g System Overview   o Operating System  p Processors (+Cache)
#            m Memory            M Memory Device     b BIOS (+Board/Chassis)
#            i Physical Disks    d Drives            a Display Adapters
#            D Display Caps      P Peripherals (+Ports/Slots)
#   software s Installed Programs (also brings Software Updates + Active Setup)
#   system   u Users (+Groups)   N Network Shares    U Uptime Statistics
#
# Deliberately NOT collected: z (Hardware Devices) is per-device driver
# inventory - 255 devices x 12 fields, ~3060 rows and 200 KB on its own,
# which was more than half the file. Add a z here if you ever need driver
# versions.
#
# The full set 'gsoPxuTUeERNtnzDaIbMpmidcSArCOHG' takes ~5.5 minutes; this
# one takes ~20 seconds.
$WinAuditCategories = 'gopmMbidaDPsuNU'

# WinAudit picks its output format from the file extension. List every
# format you want; note it can only write ONE per invocation, so each extra
# format costs another full pass (~30 seconds each).
#   csv2 - one row per field, WITH a header row and a CategoryName column,
#          so every value is labelled and the file can be filtered.
#          Renamed to .csv afterwards so it opens on a double click - the
#          content is ordinary CSV, only the extension picks the format.
#   rtf  - readable document, a table per category, opens in WordPad.
#          Nice to read, but you cannot sort or filter it.
#   csv  - AVOID: no header row at all, just unlabelled positional values
#   html - AVOID: in command line mode WinAudit writes HTML as frames,
#          which produces several files instead of one.
$WinAuditFormats = @('rtf')

$WinAuditTimeoutSec = 900   # 15 min; a full audit can genuinely take minutes
$DiskInfoTimeoutSec = 180   # 3 min

# Internet speed test, run by librespeed-cli. The raw JSON is kept per
# machine next to the other reports.
$SpeedTestServer     = 106   # Belgrade, Serbia (SOX)
$SpeedTestConcurrent = 8
$SpeedTestTimeoutSec = 180   # a healthy link finishes in about 35 seconds

# ------------------------------------------------------------------
#  Paths
# ------------------------------------------------------------------

$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) {
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
}

# Every bundled tool lives under apps\, which is what keeps the root of the
# stick down to the two scripts plus RESULTS\. Tools are only ever addressed
# through $AppsDir; the root holds nothing any of them needs.
$AppsDir = Join-Path $ScriptDir 'apps'

$WinAuditExe = Join-Path $AppsDir 'WinAudit.exe'
$DiskInfoExe = Join-Path $AppsDir 'DiskInfo64.exe'

# librespeed-cli keeps its own folder inside apps\.
$LibreSpeedExe = Join-Path $AppsDir 'librespeed\librespeed-cli.exe'

# CrystalDiskInfo 9.x is NOT a single-file portable app. Without these
# folders beside the executable it aborts looking for
# CdiResource\dialog\Graph.html and silently writes no report - so they
# belong in apps\ alongside DiskInfo64.exe, never split away from it.
$CdiResourceDir = Join-Path $AppsDir 'CdiResource'
$CdiSmartDir    = Join-Path $AppsDir 'Smart'

# CrystalDiskInfo ignores where you ask it to write and always drops this
# next to its own executable - which is apps\ now, not the root.
$DiskInfoTxtSrc = Join-Path $AppsDir 'DiskInfo.txt'

$Hostname = $env:COMPUTERNAME

# ------------------------------------------------------------------
#  Console helpers
# ------------------------------------------------------------------

function Write-Title {
    param([string]$Text)
    Write-Host ''
    Write-Host ('=' * 62) -ForegroundColor DarkCyan
    Write-Host ("  $Text") -ForegroundColor Cyan
    Write-Host ('=' * 62) -ForegroundColor DarkCyan
    Write-Host ''
}

function Write-Ok   { param([string]$Text) Write-Host "  [ OK ]   $Text" -ForegroundColor Green }
function Write-Fail { param([string]$Text) Write-Host "  [FAIL]   $Text" -ForegroundColor Red }
function Write-Warn { param([string]$Text) Write-Host "  [WARN]   $Text" -ForegroundColor Yellow }
function Write-Info { param([string]$Text) Write-Host "  $Text" -ForegroundColor Gray }

# Log lines are collected in memory and flushed to audit.log at the end,
# and also flushed after each tool runs so a yanked stick still leaves
# something behind.
$script:LogLines = New-Object System.Collections.ArrayList
# Deliberately distinctive: PowerShell variable names are case-insensitive,
# so a plain $LogPath here would collide with any local $logPath elsewhere in
# the script and silently redirect the audit trail to the wrong file.
$script:AuditLogPath = $null

function Write-Log {
    param([string]$Text)
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    [void]$script:LogLines.Add("[$stamp] $Text")
}

function Save-Log {
    if (-not $script:AuditLogPath) { return }
    # A sync client (OneDrive) or antivirus can hold the file open for a
    # moment, and a single silent failure here loses the rest of the log with
    # nothing to show why. Retry, but never let logging take down the run.
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            Set-Content -LiteralPath $script:AuditLogPath -Value $script:LogLines -Encoding UTF8 -ErrorAction Stop
            return
        } catch {
            Start-Sleep -Milliseconds 400
        }
    }
}

# ------------------------------------------------------------------
#  Input helpers
# ------------------------------------------------------------------

function Read-NonEmpty {
    param([string]$Prompt)
    while ($true) {
        Write-Host "  $Prompt" -NoNewline -ForegroundColor White
        $value = Read-Host
        if ($value -and $value.Trim()) { return $value.Trim() }
        Write-Host '  Please type something.' -ForegroundColor Yellow
    }
}

# Free text that may legitimately be left blank. Plenty of machines have
# nothing worth noting, and forcing the operator to type "none" just invites
# junk answers, so an empty reply records a clear default instead.
function Read-Optional {
    param(
        [string]$Prompt,
        [string]$Default = 'None reported'
    )
    Write-Host "  $Prompt" -NoNewline -ForegroundColor White
    $value = Read-Host
    if ($value -and $value.Trim()) { return $value.Trim() }
    return $Default
}

# Anything that isn't a clear yes or no is rejected and re-asked. Treating
# unrecognised input as "no" is how audits end up quietly recording that a
# machine has no antivirus when the tech just fat-fingered a key.
function Read-YesNo {
    param([string]$Prompt)
    while ($true) {
        Write-Host "  $Prompt (Y/N) " -NoNewline -ForegroundColor White
        $value = Read-Host
        if ($value) {
            switch -Regex ($value.Trim()) {
                '^(y|yes)$' { return $true }
                '^(n|no)$'  { return $false }
            }
        }
        Write-Host '  Please answer Y or N.' -ForegroundColor Yellow
    }
}

# Offers to run a speed test on a given medium. If accepted, runs
# librespeed-cli and keeps its raw JSON in the machine folder, then reads the
# figures back out of it.
#
# Always returns two values so the report is never blank: measured speeds on
# success, 'Not tested' if declined, 'Test failed' if the tool errored or
# wrote something unreadable. A failed speed test must not stop the audit.
function Invoke-SpeedTest {
    param(
        [string]$Number,
        [string]$Medium,
        [string]$JsonPath
    )

    if (-not (Read-YesNo "$Number. Run internet speed test on ${Medium}?")) {
        return @('Not tested', 'Not tested')
    }

    Write-Info "   Testing the $Medium link against server $SpeedTestServer, please wait."

    $ok = Invoke-Tool -FilePath $LibreSpeedExe `
                      -Arguments @('--server', "$SpeedTestServer",
                                   '--concurrent', "$SpeedTestConcurrent", '--json') `
                      -WorkingDirectory $AppsDir `
                      -TimeoutSec $SpeedTestTimeoutSec `
                      -Name "Speed test ($Medium)" `
                      -StdOutFile $JsonPath

    if (-not $ok) { return @('Test failed', 'Test failed') }

    # librespeed-cli wraps its result in a single-element array, so index
    # into it rather than reading properties off the array itself.
    try {
        $raw    = Get-Content -LiteralPath $JsonPath -Raw -ErrorAction Stop
        $result = @($raw | ConvertFrom-Json)[0]
        if ($null -eq $result.download) { throw 'no download figure in the JSON' }
    } catch {
        Write-Fail "   Speed test gave no readable result: $($_.Exception.Message)"
        Write-Log  "Speed test ($Medium): could not read JSON - $($_.Exception.Message)"
        return @('Test failed', 'Test failed')
    }

    $down = '{0} Mbps' -f $result.download
    $up   = '{0} Mbps' -f $result.upload

    Write-Ok "   $Medium : $down down, $up up, $($result.ping) ms ping"
    Write-Log "Speed test ($Medium): down=$down up=$up ping=$($result.ping)ms jitter=$($result.jitter)ms"
    Write-Log "Speed test ($Medium): raw JSON saved as $(Split-Path -Leaf $JsonPath)"
    return @($down, $up)
}

# ------------------------------------------------------------------
#  External tool runner
#
#  Returns $true only if the process exited on its own within the
#  timeout. A hung WinAudit (which happens if it decides to show its GUI)
#  gets killed rather than blocking the audit forever.
# ------------------------------------------------------------------

function Invoke-Tool {
    param(
        [string]   $FilePath,
        [string[]] $Arguments,
        [string]   $WorkingDirectory,
        [int]      $TimeoutSec,
        [string]   $Name,
        [string]   $StdOutFile
    )

    Write-Log "$Name : starting -> $FilePath $($Arguments -join ' ')"

    $spArgs = @{
        FilePath         = $FilePath
        ArgumentList     = $Arguments
        WorkingDirectory = $WorkingDirectory
        WindowStyle      = 'Hidden'
        PassThru         = $true
    }
    # librespeed-cli prints its JSON to stdout, so capture it straight to
    # file rather than trying to read it back from a hidden process.
    if ($StdOutFile) { $spArgs['RedirectStandardOutput'] = $StdOutFile }

    try {
        $proc = Start-Process @spArgs -ErrorAction Stop
    } catch {
        Write-Log "$Name : failed to start - $($_.Exception.Message)"
        Write-Fail "$Name could not be started: $($_.Exception.Message)"
        return $false
    }

    # Poll rather than block, so the operator gets a ticking counter. These
    # tools print nothing for minutes at a time and use almost no CPU, so
    # without this the screen looks frozen and people kill the audit.
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $proc.HasExited) {
        if ($sw.Elapsed.TotalSeconds -ge $TimeoutSec) {
            Write-Host "`r$(' ' * 60)`r" -NoNewline
            Write-Log "$Name : timed out after $TimeoutSec seconds, killing process"
            Write-Fail "$Name did not finish within $TimeoutSec seconds and was stopped."
            try { $proc.Kill() } catch { }
            return $false
        }
        Write-Host ("`r    still running... {0:mm\:ss} elapsed  (do not close this window)" -f $sw.Elapsed) `
                   -NoNewline -ForegroundColor DarkGray
        Start-Sleep -Milliseconds 500
    }
    Write-Host "`r$(' ' * 70)`r" -NoNewline

    try { $proc.WaitForExit() } catch { }
    $code = try { $proc.ExitCode } catch { $null }

    if ($null -eq $code) {
        # Start-Process does not surface ExitCode when stdout is redirected.
        # Nothing is wrong; callers that capture output judge success from
        # the output file itself, which is the stronger check anyway.
        Write-Log "$Name : exited (no exit code available while capturing output)"
    } else {
        Write-Log "$Name : exited with code $code"
    }
    return $true
}

# ------------------------------------------------------------------
#  Summary report helpers
#
#  These read back the exports to build REPORT_SUMMARY.txt. Each one
#  returns $null rather than throwing when it cannot find what it wants,
#  so a layout change in either tool shows up as a visible
#  "NOT AVAILABLE" block instead of a silently empty report.
# ------------------------------------------------------------------

# WinAudit's RTF is markup, not text. Letting a RichTextBox render it is
# far more reliable than trying to strip the control words by hand.
function Convert-RtfToText {
    param([string]$Path)
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $box = New-Object System.Windows.Forms.RichTextBox
        $box.Rtf = Get-Content -LiteralPath $Path -Raw
        return ($box.Text -split "`r?`n")
    } catch {
        Write-Log "Summary: could not render the RTF - $($_.Exception.Message)"
        return $null
    }
}

# Pulls one numbered section out of the rendered report. Drives is a parent
# heading whose volumes are each their own numbered sub-section titled with
# just the drive letter, so those get folded in when asked for.
function Get-WinAuditSection {
    param(
        [string[]] $Lines,
        [string]   $Title,
        [switch]   $WithDriveLetters
    )
    $start = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match ('^\s*\d+\)\s*' + [regex]::Escape($Title) + '\s*$')) { $start = $i; break }
    }
    if ($start -lt 0) { return $null }

    $out = New-Object System.Collections.ArrayList
    for ($i = $start + 1; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^\s*\d+\)\s*(.+?)\s*$') {
            $head = $Matches[1]
            if ($WithDriveLetters -and $head -match '^[A-Za-z]$') {
                [void]$out.Add("  Drive $head :")
                continue
            }
            break
        }
        [void]$out.Add($Lines[$i])
    }
    return $out
}

# Turns the rendered "Item<tab>Value" rows into an aligned block.
function Format-AuditPairs {
    param([string[]]$Lines)
    $out = New-Object System.Collections.ArrayList
    foreach ($line in $Lines) {
        $t = $line.TrimEnd()
        if (-not $t.Trim()) { continue }
        if ($t -match '^\s*Item\s*\t\s*Value\s*$') { continue }

        if ($t -notmatch "`t") {
            if ($t -match '^\s') {
                # An injected sub-heading; give it breathing room.
                if ($out.Count) { [void]$out.Add('') }
                [void]$out.Add($t)
            } else {
                # A field WinAudit left empty renders as a bare label with
                # no tab. Keep it in column so the block stays aligned.
                [void]$out.Add(('    {0} :' -f $t.Trim().PadRight(22)))
            }
            continue
        }

        $parts = $t -split "`t", 2
        [void]$out.Add(('    {0} : {1}' -f $parts[0].Trim().PadRight(22), $parts[1].Trim()))
    }
    return $out
}

# Windows licence channel and partial key. None of this appears in any of
# the tool exports - WinAudit only reports the Product ID, which is an
# install identifier and says nothing about how the machine is licensed.
# Returns $null on failure so the report shows a visible NOT AVAILABLE.
function Get-WindowsLicence {
    try {
        $rows = @(Get-CimInstance -ClassName SoftwareLicensingProduct `
                      -Filter "PartialProductKey IS NOT NULL" -ErrorAction Stop |
                  Where-Object { $_.Name -like '*Windows*' })
    } catch {
        Write-Log "Summary: Windows licence query failed - $($_.Exception.Message)"
        return $null
    }
    if (-not $rows.Count) {
        Write-Log 'Summary: no Windows licence with a partial key was found.'
        return $null
    }
    return $rows
}

function Get-LicenceStatusText {
    param($Code)
    switch ([int]$Code) {
        0       { 'Not licensed' }
        1       { 'Activated' }
        2       { 'Grace period (out of box)' }
        3       { 'Grace period (out of tolerance)' }
        4       { 'Grace period (non-genuine)' }
        5       { 'Notification mode - NOT activated' }
        6       { 'Extended grace period' }
        default { "Unknown status code $Code" }
    }
}

# Everything CrystalDiskInfo reports except the S.M.A.R.T. attribute
# tables. Written as skip-and-resume rather than "stop at the first
# S.M.A.R.T." so a machine with several disks keeps every drive's details.
function Get-DiskInfoSummary {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }

    $out  = New-Object System.Collections.ArrayList
    $keep = $true
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        if ($line -match '^--\s*(S\.M\.A\.R\.T\.|IDENTIFY_DEVICE|SMART_NVME|SMART_READ)') {
            $keep = $false
            continue
        }
        # A "(02) Model" line means the next disk's details begin here.
        if (-not $keep -and $line -match '^\s*\(\d+\)\s+\S') {
            $keep = $true
            [void]$out.Add('')
        }
        if ($keep) { [void]$out.Add($line.TrimEnd()) }
    }
    return $out
}

# ==================================================================
#  Preflight
# ==================================================================

Clear-Host
Write-Title "COMPUTER AUDIT  -  $Hostname"

$identity   = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal  = New-Object Security.Principal.WindowsPrincipal($identity)
$isElevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isElevated) {
    Write-Fail 'This script must run as administrator.'
    Write-Info 'Start it with run_audit.bat, which requests elevation for you.'
    Write-Host ''
    Read-Host '  Press Enter to close'
    exit 3
}

# Check the tools are here before making anyone answer seven questions.
# Checked on its own first: if apps\ never made it onto the stick then every
# check below fails at once, and "everything is missing" hides the one thing
# actually wrong.
if (-not (Test-Path -LiteralPath $AppsDir)) {
    Write-Fail 'The apps\ folder is missing, so none of the audit tools are here.'
    Write-Info "Expected it at: $AppsDir"
    Write-Host ''
    Write-Info 'Copy the whole audit folder to the stick. These two scripts on'
    Write-Info 'their own cannot do anything without apps\.'
    Write-Host ''
    Read-Host '  Press Enter to close'
    exit 4
}

$missing = @()
if (-not (Test-Path -LiteralPath $WinAuditExe))    { $missing += 'WinAudit.exe' }
if (-not (Test-Path -LiteralPath $DiskInfoExe))    { $missing += 'DiskInfo64.exe' }
if (-not (Test-Path -LiteralPath $LibreSpeedExe))  { $missing += 'librespeed\librespeed-cli.exe' }
if (-not (Test-Path -LiteralPath $CdiResourceDir)) { $missing += 'CdiResource\ (folder)' }
if (-not (Test-Path -LiteralPath $CdiSmartDir))    { $missing += 'Smart\ (folder)' }
if ($missing.Count -gt 0) {
    Write-Fail "Missing from apps\: $($missing -join ', ')"
    Write-Info "Expected inside: $AppsDir"
    Write-Host ''
    Write-Info 'Copy the WHOLE CrystalDiskInfo folder into apps\, not just the'
    Write-Info 'exe. Without CdiResource\ it fails looking for Graph.html.'
    Write-Host ''
    Read-Host '  Press Enter to close'
    exit 4
}

# Confirm the stick is writable now, rather than after the interview.
try {
    $probe = Join-Path $ScriptDir ('.write_test_{0}' -f [Guid]::NewGuid().ToString('N'))
    Set-Content -LiteralPath $probe -Value 'test' -Encoding ASCII
    Remove-Item -LiteralPath $probe -Force
} catch {
    Write-Fail 'This folder is not writable, so results could not be saved.'
    Write-Info "Folder: $ScriptDir"
    Write-Info 'If the USB stick has a write-protect switch, turn it off.'
    Write-Host ''
    Read-Host '  Press Enter to close'
    exit 5
}

# One folder per machine. If this machine has already been audited from
# this stick, keep the old folder and put the new run beside it rather
# than overwriting work.
# Machine folders live under RESULTS so the root stays just the tools.
# Created if absent, in case only the files get copied to a fresh stick.
$ResultsDir = Join-Path $ScriptDir 'RESULTS'
if (-not (Test-Path -LiteralPath $ResultsDir)) {
    New-Item -ItemType Directory -Path $ResultsDir -Force | Out-Null
}

$OutDir = Join-Path $ResultsDir $Hostname
if (Test-Path -LiteralPath $OutDir) {
    $OutDir = Join-Path $ResultsDir ('{0}_{1}' -f $Hostname, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Write-Warn "A folder for $Hostname already exists, so this run goes to:"
    Write-Info (Split-Path -Leaf $OutDir)
    Write-Host ''
}
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

# Everything the tools produce goes one level down, in exports. That keeps
# the machine folder itself free for the summary report.
$ExportDir = Join-Path $OutDir 'exports'
New-Item -ItemType Directory -Path $ExportDir -Force | Out-Null

$script:AuditLogPath = Join-Path $ExportDir 'audit.log'
Write-Log "Audit started on $Hostname"
Write-Log "Script folder: $ScriptDir"
Write-Log "Output folder: $OutDir"
Write-Log "User running the script: $($identity.Name)"
# Recorded explicitly so nobody has to work out after the fact whether a
# report is complete. Log the measured value rather than asserting "Yes",
# even though the check above means it can only ever be true here.
Write-Log "Running elevated: $(if ($isElevated) { 'Yes' } else { 'No' })"

Write-Info "Results folder: $OutDir"

# ==================================================================
#  Questions
# ==================================================================

$answers = $null

while ($true) {

    Write-Title 'PART 1 OF 2  -  QUESTIONS'

    # --- 1 ---
    Write-Host '  1. The real name of the main user using this computer' -ForegroundColor White
    $realName = Read-NonEmpty '   Real name: '

    # --- 2 ---
    Write-Host ''
    Write-Host '  2. The username that authenticates on this computer' -ForegroundColor White
    $loginName = Read-NonEmpty '   Username (e.g. firstname.lastname): '

    # --- 3 --- wifi; measured, not typed
    Write-Host ''
    $wifi = Invoke-SpeedTest '3' 'wifi' (Join-Path $ExportDir 'wifispeedtest.json')

    # --- 4 --- cable; same logic as wifi
    Write-Host ''
    $cable = Invoke-SpeedTest '4' 'cable' (Join-Path $ExportDir 'cablespeedtest.json')

    # --- 5 to 8 ---
    Write-Host ''
    $isAdmin       = Read-YesNo '5. Does the user have admin access to the pc?'
    Write-Host ''
    $hasPassword   = Read-YesNo '6. Does the user have a password set for authentication?'
    Write-Host ''
    $hasAntivirus  = Read-YesNo '7. Is an antivirus installed on this PC?'
    Write-Host ''
    $hasSticker    = Read-YesNo '8. Is there a windows sticker on the PC?'

    # --- 9 ---
    Write-Host ''
    Write-Host "  9. What is the user's free email space and total capacity?" -ForegroundColor White
    $mailbox = Read-NonEmpty '   Use format [occupied/total space]: '

    # --- 10 ---
    Write-Host ''
    Write-Host '  10. What are the main technical issues for this user?' -ForegroundColor White
    $issues = Read-Optional '    (leave blank if there are none): '

    $yn = { param($b) if ($b) { 'Yes' } else { 'No' } }

    $answers = [ordered]@{
        'Hostname'             = $Hostname
        'Real name'            = $realName
        'Login username'       = $loginName
        'WiFi download'        = $wifi[0]
        'WiFi upload'          = $wifi[1]
        'Cable download'       = $cable[0]
        'Cable upload'         = $cable[1]
        'Admin access'         = (& $yn $isAdmin)
        'Password set'         = (& $yn $hasPassword)
        'Antivirus'            = (& $yn $hasAntivirus)
        'Windows sticker'      = (& $yn $hasSticker)
        'Email space'          = $mailbox
        'Technical issues'     = $issues
        'Audited by'           = $identity.Name
        'Audit date'           = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    }

    # Nothing has been written yet, so a mistyped answer at question 1 is
    # still fixable here.
    Write-Title 'REVIEW'
    foreach ($key in $answers.Keys) {
        Write-Host ('  {0,-24} {1}' -f $key, $answers[$key]) -ForegroundColor White
    }
    Write-Host ''
    if (Read-YesNo 'Is all of the above correct?') { break }

    Write-Host ''
    Write-Warn 'Starting the questions again.'
}

# ==================================================================
#  Save the manual answers FIRST
#
#  This is the expensive data - a person typed it. It must survive
#  anything the audit tools do next.
# ==================================================================

$manualTxt = Join-Path $ExportDir "${Hostname}_manual.txt"

$txt = New-Object System.Collections.ArrayList
[void]$txt.Add('==============================================')
[void]$txt.Add("  COMPUTER AUDIT  -  $Hostname")
[void]$txt.Add('==============================================')
[void]$txt.Add('')
foreach ($key in $answers.Keys) {
    [void]$txt.Add(('{0,-24}: {1}' -f $key, $answers[$key]))
}
[void]$txt.Add('')

Set-Content -LiteralPath $manualTxt -Value $txt -Encoding UTF8

Write-Log 'Manual answers written.'
Write-Host ''
Write-Ok "Answers saved to $(Split-Path -Leaf $manualTxt)"
Save-Log

# ==================================================================
#  Automated tools
# ==================================================================

Write-Title 'PART 2 OF 2  -  RUNNING APPLICATIONS AUDIT'

$winAuditOk = $false
$diskInfoOk = $false

# ---------------- WinAudit ----------------

# WinAudit resolves a RELATIVE /f= against its own folder rather than the
# working directory, but it handles an absolute path fine even when that
# path contains spaces. So point it straight at the machine folder - the
# report never passes through the root, and because the machine folder is
# created fresh for every run there is no stale output to guard against.
#
# One pass per format: WinAudit writes a single format per invocation, so
# two formats means collecting everything twice.
$winAuditLogs  = @()
$winAuditSaved = @()

foreach ($fmt in $WinAuditFormats) {
    $dest   = Join-Path $ExportDir "${Hostname}_winaudit.$fmt"
    $fmtLog = Join-Path $ExportDir "winaudit_run_$fmt.log"
    $winAuditLogs += $fmtLog

    if ($WinAuditFormats.Count -gt 1) {
        Write-Info "Running WinAudit ($fmt)... this can take a few minutes, please wait."
    } else {
        Write-Info 'Running WinAudit... this can take a few minutes, please wait.'
    }

    $winAuditArgs = @(
        "/r=$WinAuditCategories"
        "/f=$dest"
        "/l=$fmtLog"
        '/L=en'
    )

    if (-not (Invoke-Tool -FilePath $WinAuditExe -Arguments $winAuditArgs `
                          -WorkingDirectory $AppsDir -TimeoutSec $WinAuditTimeoutSec `
                          -Name "WinAudit ($fmt)")) {
        continue
    }

    if (-not (Test-Path -LiteralPath $dest)) {
        Write-Fail "WinAudit finished but produced no $fmt file."
        Write-Log "WinAudit produced no $fmt output."
        continue
    }

    # The .csv2 extension is only there to make WinAudit emit the labelled
    # long format; what it writes is ordinary CSV. Rename it so it opens in
    # Excel on a double click.
    if ($fmt -eq 'csv2') {
        $friendlyName = [IO.Path]::ChangeExtension($dest, 'csv')
        Move-Item -LiteralPath $dest -Destination $friendlyName -Force
        $dest = $friendlyName
        Write-Log 'Renamed WinAudit output from .csv2 to .csv (same content).'
    }

    $kb = [math]::Round((Get-Item -LiteralPath $dest).Length / 1KB, 1)
    Write-Ok "WinAudit report saved: $(Split-Path -Leaf $dest) ($kb KB)"
    Write-Log "WinAudit report saved: $dest ($kb KB)"
    $winAuditSaved += $dest
}

# Only a clean sweep counts, so a missing second format still shows as a
# failure rather than passing quietly.
$winAuditOk = $winAuditSaved.Count -eq $WinAuditFormats.Count

# Fold WinAudit's own logs into audit.log if anything went wrong, then bin
# them so the machine folder keeps to the files that matter.
foreach ($fmtLog in $winAuditLogs) {
    if (-not (Test-Path -LiteralPath $fmtLog)) { continue }

    if (-not $winAuditOk) {
        Write-Log "--- $(Split-Path -Leaf $fmtLog) ---"
        foreach ($line in (Get-Content -LiteralPath $fmtLog)) { Write-Log "    $line" }
        Write-Log '--- end log ---'
    }

    # WinAudit can keep its log handle open for a moment after exiting, so
    # retry briefly rather than leaving a stray file in the machine folder.
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        Remove-Item -LiteralPath $fmtLog -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $fmtLog)) { break }
        Start-Sleep -Milliseconds 300
    }
    if (Test-Path -LiteralPath $fmtLog) {
        Write-Log "Could not delete $(Split-Path -Leaf $fmtLog) - file still locked."
    }
}

Save-Log

# ---------------- CrystalDiskInfo ----------------

Write-Host ''
Write-Info 'Running CrystalDiskInfo...'

$diskInfoDest = Join-Path $ExportDir "${Hostname}_diskinfo.txt"

# Delete any DiskInfo.txt left behind by an earlier run. Without this, a
# failed run on this machine would silently hand you the *previous*
# machine's SMART data filed under this hostname.
if (Test-Path -LiteralPath $DiskInfoTxtSrc) {
    Remove-Item -LiteralPath $DiskInfoTxtSrc -Force -ErrorAction SilentlyContinue
    Write-Log 'Removed a stale DiskInfo.txt before running CrystalDiskInfo.'
}

if (Invoke-Tool -FilePath $DiskInfoExe -Arguments @('/CopyExit') `
                -WorkingDirectory $AppsDir -TimeoutSec $DiskInfoTimeoutSec -Name 'CrystalDiskInfo') {

    if (Test-Path -LiteralPath $DiskInfoTxtSrc) {
        Move-Item -LiteralPath $DiskInfoTxtSrc -Destination $diskInfoDest -Force
        $diskInfoOk = $true
        Write-Ok 'Disk / SMART report saved'
        Write-Log "Disk report saved: $diskInfoDest"
    } else {
        Write-Fail 'CrystalDiskInfo finished but wrote no DiskInfo.txt.'
        Write-Log 'CrystalDiskInfo produced no DiskInfo.txt.'
    }
}

Save-Log

# ==================================================================
#  REPORT_SUMMARY.txt
#
#  Reads the finished exports back and pulls the interesting parts into
#  one readable file, which sits above the exports folder. Runs last so
#  every source it needs already exists.
# ==================================================================

Write-Host ''
Write-Info 'Building REPORT_SUMMARY.txt...'

$summaryOk   = $false
$summaryPath = Join-Path $OutDir 'REPORT_SUMMARY.txt'
$rule        = '=' * 78
$thinRule    = '-' * 78
$report      = New-Object System.Collections.ArrayList

function Add-Report { param([string]$Text = '') [void]$report.Add($Text) }
function Add-ReportHeading {
    param([string]$Title)
    Add-Report
    Add-Report
    Add-Report $thinRule
    Add-Report "  $Title"
    Add-Report $thinRule
    Add-Report
}

Add-Report $rule
Add-Report "  COMPUTER AUDIT SUMMARY  -  $Hostname"
Add-Report "  $($answers['Audit date'])"
Add-Report $rule

# The answers are still in memory, so there is no need to parse the file
# we just wrote.
Add-ReportHeading 'TECHNICIAN NOTES'
# Width comes from the longest label so adding a question later cannot
# knock the column out of line.
$notePad = 22
foreach ($key in $answers.Keys) { if ($key.Length -gt $notePad) { $notePad = $key.Length } }
foreach ($key in $answers.Keys) {
    Add-Report ('    {0} : {1}' -f $key.PadRight($notePad), $answers[$key])
}

Add-ReportHeading 'WINDOWS LICENCE'
$licences = Get-WindowsLicence
if ($licences) {
    $first = $true
    foreach ($lic in $licences) {
        if (-not $first) { Add-Report }
        $first = $false
        Add-Report ('    {0} : {1}' -f 'Edition'.PadRight(22),             $lic.Name)
        Add-Report ('    {0} : {1}' -f 'Licence type'.PadRight(22),        $lic.ProductKeyChannel)
        Add-Report ('    {0} : {1}' -f 'Channel detail'.PadRight(22),      $lic.Description)
        Add-Report ('    {0} : {1}' -f 'Partial product key'.PadRight(22), "$($lic.PartialProductKey)   (last 5 characters)")
        Add-Report ('    {0} : {1}' -f 'Activation'.PadRight(22),          (Get-LicenceStatusText $lic.LicenseStatus))
        Write-Log ("Licence: channel={0} partial={1} status={2}" -f `
                   $lic.ProductKeyChannel, $lic.PartialProductKey, $lic.LicenseStatus)
    }
} else {
    Add-Report '    NOT AVAILABLE - could not read Windows licensing information.'
}

$rtfText = if ($winAuditOk) { Convert-RtfToText $winAuditSaved[0] } else { $null }

Add-ReportHeading 'SYSTEM OVERVIEW'
$section = if ($rtfText) { Get-WinAuditSection -Lines $rtfText -Title 'System Overview' } else { $null }
if ($section) {
    Format-AuditPairs $section | ForEach-Object { Add-Report $_ }
} else {
    Add-Report '    NOT AVAILABLE - could not read the System Overview section.'
    Write-Log 'Summary: System Overview section not found.'
}

Add-ReportHeading 'DRIVES'
$section = if ($rtfText) { Get-WinAuditSection -Lines $rtfText -Title 'Drives' -WithDriveLetters } else { $null }
if ($section) {
    Format-AuditPairs $section | ForEach-Object { Add-Report $_ }
} else {
    Add-Report '    NOT AVAILABLE - could not read the Drives section.'
    Write-Log 'Summary: Drives section not found.'
}

Add-ReportHeading 'DISK HEALTH   (S.M.A.R.T. attribute tables omitted)'
$section = if ($diskInfoOk) { Get-DiskInfoSummary $diskInfoDest } else { $null }
if ($section) {
    $section | ForEach-Object { Add-Report (('    ' + $_).TrimEnd()) }
} else {
    Add-Report '    NOT AVAILABLE - no CrystalDiskInfo output to read.'
    Write-Log 'Summary: disk report not available.'
}

Add-Report
Add-Report $rule
Add-Report "  Full exports in:  $(Split-Path -Leaf $ExportDir)\"
Add-Report $rule

try {
    Set-Content -LiteralPath $summaryPath -Value $report -Encoding UTF8 -ErrorAction Stop
    $summaryOk = $true
    Write-Ok "REPORT_SUMMARY.txt written ($($report.Count) lines)"
    Write-Log "Summary written: $summaryPath ($($report.Count) lines)"
} catch {
    Write-Fail "Could not write REPORT_SUMMARY.txt: $($_.Exception.Message)"
    Write-Log  "Summary: write failed - $($_.Exception.Message)"
}

Save-Log

# ==================================================================
#  Summary
# ==================================================================

Write-Title 'FINISHED'

Write-Info "Machine folder: $OutDir"
Write-Host ''
Write-Host '  Manual answers (.txt)         ' -NoNewline -ForegroundColor White
Write-Host 'saved' -ForegroundColor Green
Write-Host '  WinAudit report               ' -NoNewline -ForegroundColor White
if ($winAuditOk) { Write-Host 'saved' -ForegroundColor Green } else { Write-Host 'FAILED' -ForegroundColor Red }
Write-Host '  Disk / SMART report           ' -NoNewline -ForegroundColor White
if ($diskInfoOk) { Write-Host 'saved' -ForegroundColor Green } else { Write-Host 'FAILED' -ForegroundColor Red }
Write-Host '  REPORT_SUMMARY.txt            ' -NoNewline -ForegroundColor White
if ($summaryOk) { Write-Host 'saved' -ForegroundColor Green } else { Write-Host 'FAILED' -ForegroundColor Red }
Write-Host ''

if ($winAuditOk -and $diskInfoOk -and $summaryOk) {
    $exitCode = 0
    Write-Ok 'Audit complete.'
} else {
    $exitCode = 1
    Write-Warn 'Audit finished with problems - see audit.log in the machine folder.'
    Write-Warn 'The answers you typed were saved regardless.'
}

Write-Log "Audit finished with exit code $exitCode"
Save-Log

Write-Host ''
Read-Host '  Press Enter to close'
exit $exitCode
