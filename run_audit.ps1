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

param(
    # Ask the ten questions in the console instead of on a form, exactly as
    # earlier versions did. The script also falls back to this on its own if
    # no form can be shown (no desktop session, or a non-STA host).
    [switch]$Console
)

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

# The console only gets in the way while the form is up - the form carries its
# own progress, and a console in front of it invites clicking the wrong window.
# Minimised rather than hidden, so it can still be brought back by hand, and
# so it is already on the taskbar when we restore it afterwards.
#
# The P/Invoke type is compiled on first use rather than at startup: console
# mode never calls this, and there is no reason to make it pay for the compile.
function Set-ConsoleWindowState {
    param([ValidateSet('Minimised', 'Restored')][string]$State)
    try {
        if (-not ('AuditNative.ConsoleWindow' -as [type])) {
            Add-Type -Namespace AuditNative -Name ConsoleWindow -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")]   public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@ -ErrorAction Stop
        }
        $hwnd = [AuditNative.ConsoleWindow]::GetConsoleWindow()
        if ($hwnd -eq [IntPtr]::Zero) { return }
        # 6 = SW_MINIMIZE, 9 = SW_RESTORE
        [void][AuditNative.ConsoleWindow]::ShowWindow($hwnd, $(if ($State -eq 'Minimised') { 6 } else { 9 }))
    } catch {
        # Purely cosmetic; never let a window-state call take down the audit.
        Write-Log "Console window could not be set to $State - $($_.Exception.Message)"
    }
}

# Log lines are collected in memory and flushed to audit.log at the end,
# and also flushed after each tool runs so a yanked stick still leaves
# something behind.
$script:LogLines = New-Object System.Collections.ArrayList
# Deliberately distinctive: PowerShell variable names are case-insensitive,
# so a plain $LogPath here would collide with any local $logPath elsewhere in
# the script and silently redirect the audit trail to the wrong file.
$script:AuditLogPath = $null

# Set only while the GUI is waiting on a tool, so Invoke-Tool's poll loop can
# keep the form repainting instead of letting Windows grey it out as "Not
# Responding". Stays false in console mode, where there is nothing to pump.
$script:PumpUiEvents = $false

# Where Invoke-Tool writes its elapsed counter while the GUI is up. The
# console is minimised behind the form by then, so without this the operator
# has nowhere to see that a tool is still working.
$script:UiStatusLabel = $null

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
        [string]$JsonPath,
        # The GUI has its own button for this, so it asks for the test
        # directly rather than through a console Y/N prompt.
        [switch]$NoPrompt
    )

    if (-not $NoPrompt -and -not (Read-YesNo "$Number. Run internet speed test on ${Medium}?")) {
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
#  GUI front end
#
#  The same ten questions as the console flow, on one form, with a real
#  multi-line box for the technical issues. Builds and returns the usual
#  $answers hashtable, so nothing downstream needs to know which front end
#  was used.
#
#  Returns $null when a form cannot be shown; the caller then falls through
#  to the console interview rather than failing.
#
#  There is no confirm-and-repeat loop here on purpose: every answer stays
#  visible and editable until OK is pressed, so the form is its own review
#  step, and fixing a typo no longer costs a repeat of both speed tests.
# ------------------------------------------------------------------

function Get-AnswersGui {

    # A form needs an STA thread. powershell.exe gives us one, but pwsh.exe
    # defaults to MTA, so measure it rather than assume.
    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
        Write-Log 'GUI: thread is not STA, using the console questions instead.'
        return $null
    }

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        [System.Windows.Forms.Application]::EnableVisualStyles()
    } catch {
        Write-Log "GUI: WinForms is not available - $($_.Exception.Message)"
        return $null
    }

    # Kept in a hashtable rather than two plain variables. A button handler
    # runs in its own scope, so assigning to a variable there would never
    # reach us; writing into a hashtable mutates the one object we share.
    $speeds = @{
        wifi  = @('Not tested', 'Not tested')
        cable = @('Not tested', 'Not tested')
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text            = "Computer Audit  -  $Hostname"
    $form.ClientSize      = New-Object System.Drawing.Size(660, 752)
    $form.StartPosition   = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox     = $false
    $form.MinimizeBox     = $false
    $form.Font            = New-Object System.Drawing.Font('Segoe UI', 9)
    $form.Tag             = ''

    # --- small builders, so the layout below stays readable ---

    function New-QLabel {
        param([string]$Text, [int]$Y, [int]$Width = 630)
        $l = New-Object System.Windows.Forms.Label
        $l.Text     = $Text
        $l.Location = New-Object System.Drawing.Point(14, $Y)
        $l.Size     = New-Object System.Drawing.Size($Width, 18)
        return $l
    }

    function New-QText {
        param([int]$Y)
        $t = New-Object System.Windows.Forms.TextBox
        $t.Location = New-Object System.Drawing.Point(14, $Y)
        $t.Size     = New-Object System.Drawing.Size(630, 24)
        return $t
    }

    # Each Yes/No pair needs its own container: radio buttons group by
    # parent, so four pairs on the bare form would behave as one group of
    # eight. Both start unchecked - the console flow refuses to treat a
    # non-answer as "No", and the form must not be laxer than it was.
    $radios = @{}
    function New-YesNo {
        param([string]$Key, [int]$Y)
        $panel = New-Object System.Windows.Forms.Panel
        $panel.Location = New-Object System.Drawing.Point(474, $Y)
        $panel.Size     = New-Object System.Drawing.Size(170, 24)

        $yes = New-Object System.Windows.Forms.RadioButton
        $yes.Text     = 'Yes'
        $yes.Location = New-Object System.Drawing.Point(0, 2)
        $yes.Size     = New-Object System.Drawing.Size(55, 20)
        $yes.Checked  = $false

        $no = New-Object System.Windows.Forms.RadioButton
        $no.Text     = 'No'
        $no.Location = New-Object System.Drawing.Point(70, 2)
        $no.Size     = New-Object System.Drawing.Size(55, 20)
        $no.Checked  = $false

        $panel.Controls.AddRange(@($yes, $no))
        $radios[$Key] = @{ Yes = $yes; No = $no }
        return $panel
    }

    # --- layout ---

    $intro = New-QLabel "Fill this in for $Hostname, then press Save and continue." 12
    $intro.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)

    $txtRealName = New-QText 64
    $txtLogin    = New-QText 116
    $txtMailbox  = New-QText 470

    # The applications audit sits above the speed tests so it can be started
    # first: WinAudit and CrystalDiskInfo then work through their few minutes
    # while the rest of the form is still being filled in.
    $btnAudit = New-Object System.Windows.Forms.Button
    $btnAudit.Text     = 'Run audit apps'
    $btnAudit.Location = New-Object System.Drawing.Point(14, 170)
    $btnAudit.Size     = New-Object System.Drawing.Size(150, 26)

    $lblAudit = New-Object System.Windows.Forms.Label
    $lblAudit.Text      = 'Not run yet'
    $lblAudit.Location  = New-Object System.Drawing.Point(176, 175)
    $lblAudit.Size      = New-Object System.Drawing.Size(470, 18)
    $lblAudit.ForeColor = [System.Drawing.Color]::DimGray

    $btnWifi = New-Object System.Windows.Forms.Button
    $btnWifi.Text     = 'Run test'
    $btnWifi.Location = New-Object System.Drawing.Point(14, 228)
    $btnWifi.Size     = New-Object System.Drawing.Size(150, 26)

    $lblWifi = New-Object System.Windows.Forms.Label
    $lblWifi.Text      = 'Not tested'
    $lblWifi.Location  = New-Object System.Drawing.Point(176, 233)
    $lblWifi.Size      = New-Object System.Drawing.Size(470, 18)
    $lblWifi.ForeColor = [System.Drawing.Color]::DimGray

    $btnCable = New-Object System.Windows.Forms.Button
    $btnCable.Text     = 'Run test'
    $btnCable.Location = New-Object System.Drawing.Point(14, 286)
    $btnCable.Size     = New-Object System.Drawing.Size(150, 26)

    $lblCable = New-Object System.Windows.Forms.Label
    $lblCable.Text      = 'Not tested'
    $lblCable.Location  = New-Object System.Drawing.Point(176, 291)
    $lblCable.Size      = New-Object System.Drawing.Size(470, 18)
    $lblCable.ForeColor = [System.Drawing.Color]::DimGray

    $txtIssues = New-Object System.Windows.Forms.TextBox
    $txtIssues.Location   = New-Object System.Drawing.Point(14, 524)
    $txtIssues.Size       = New-Object System.Drawing.Size(630, 140)
    $txtIssues.Multiline  = $true
    $txtIssues.ScrollBars = 'Vertical'
    $txtIssues.AcceptsTab = $false
    $txtIssues.WordWrap   = $true

    $hint = New-QLabel 'Questions 1, 2 and 9 are required. Question 10 may be left blank.' 674
    $hint.ForeColor = [System.Drawing.Color]::DimGray

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text     = 'Save and continue'
    $btnOk.Location = New-Object System.Drawing.Point(414, 706)
    $btnOk.Size     = New-Object System.Drawing.Size(130, 30)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text     = 'Cancel'
    $btnCancel.Location = New-Object System.Drawing.Point(554, 706)
    $btnCancel.Size     = New-Object System.Drawing.Size(90, 30)

    $form.Controls.AddRange(@(
        $intro,
        (New-QLabel '1. The real name of the main user using this computer' 44), $txtRealName,
        (New-QLabel '2. The username that authenticates on this computer (e.g. firstname.lastname)' 96), $txtLogin,
        (New-QLabel 'Applications audit - WinAudit and CrystalDiskInfo (start this first)' 148), $btnAudit, $lblAudit,
        (New-QLabel '3. Internet speed test - WiFi' 206), $btnWifi, $lblWifi,
        (New-QLabel '4. Internet speed test - cable' 264), $btnCable, $lblCable,
        (New-QLabel '5. Does the user have admin access to the pc?' 326 450),            (New-YesNo 'admin'     324),
        (New-QLabel '6. Does the user have a password set for authentication?' 356 450), (New-YesNo 'password' 354),
        (New-QLabel '7. Is an antivirus installed on this PC?' 386 450),                 (New-YesNo 'antivirus' 384),
        (New-QLabel '8. Is there a windows sticker on the PC?' 416 450),                 (New-YesNo 'sticker'   414),
        (New-QLabel "9. What is the user's free email space and total capacity?  [occupied/total space]" 450), $txtMailbox,
        (New-QLabel '10. What are the main technical issues for this user?' 504), $txtIssues,
        $hint, $btnOk, $btnCancel
    ))

    # --- long-running buttons ---
    #
    # All of this runs inline on the UI thread. Invoke-Tool polls rather than
    # blocks, and $script:PumpUiEvents makes that poll loop pump the message
    # queue, so the window keeps repainting through the minutes a tool can
    # take. $script:UiStatusLabel gives the loop somewhere on the form to put
    # its elapsed counter, which matters because the console is minimised
    # behind us and is no longer somewhere the operator can watch.
    #
    # Every button is disabled for the duration. Two tools competing for the
    # same DiskInfo.txt, or an OK press landing mid-run, are not worth the
    # convenience of leaving them live.

    function Set-GuiBusy {
        param([bool]$Busy)
        foreach ($b in @($btnAudit, $btnWifi, $btnCable, $btnOk, $btnCancel)) {
            $b.Enabled = -not $Busy
        }
        [System.Windows.Forms.Application]::DoEvents()
    }

    function Invoke-GuiSpeedTest {
        param([string]$Number, [string]$Medium, [string]$JsonName, $Button, $Label)

        Set-GuiBusy $true
        $Label.ForeColor = [System.Drawing.Color]::DimGray
        $Label.Text      = 'Starting...'

        # Nothing a tool does may be allowed to tear down the form: at this
        # point the operator's typed answers exist only in these text boxes,
        # and letting an exception escape would throw them away.
        $res = @('Test failed', 'Test failed')

        $script:UiStatusLabel = $Label
        $script:PumpUiEvents  = $true
        try {
            $res = Invoke-SpeedTest -Number $Number -Medium $Medium `
                                    -JsonPath (Join-Path $ExportDir $JsonName) -NoPrompt
        } catch {
            Write-Log "Speed test ($Medium) threw - $($_.Exception.Message)"
        } finally {
            $script:PumpUiEvents  = $false
            $script:UiStatusLabel = $null
            Set-GuiBusy $false
        }

        if ($res[0] -eq 'Test failed') {
            $Label.Text      = 'Test failed - see audit.log. You can try again.'
            $Label.ForeColor = [System.Drawing.Color]::Firebrick
        } else {
            $Label.Text      = '{0} down / {1} up' -f $res[0], $res[1]
            $Label.ForeColor = [System.Drawing.Color]::ForestGreen
            $Button.Text     = 'Re-test'
        }
        return $res
    }

    function Invoke-GuiAuditTools {
        Set-GuiBusy $true
        $lblAudit.ForeColor = [System.Drawing.Color]::DimGray
        $lblAudit.Text      = 'Starting...'

        $script:UiStatusLabel = $lblAudit
        $script:PumpUiEvents  = $true
        try {
            Invoke-AuditTools
        } catch {
            # Same reasoning as the speed test: the answers are still only in
            # the form. Record the failure, show it, and let the operator carry
            # on - the main flow reports it again at the end from the same flags.
            Write-Log "Applications audit threw - $($_.Exception.Message)"
        } finally {
            $script:PumpUiEvents  = $false
            $script:UiStatusLabel = $null
            Set-GuiBusy $false
        }

        $btnAudit.Text = 'Run again'
        if ($script:WinAuditOk -and $script:DiskInfoOk) {
            $lblAudit.Text      = 'Done - WinAudit and disk / SMART reports saved.'
            $lblAudit.ForeColor = [System.Drawing.Color]::ForestGreen
        } else {
            $parts = @()
            $parts += $(if ($script:WinAuditOk) { 'WinAudit OK' }    else { 'WinAudit FAILED' })
            $parts += $(if ($script:DiskInfoOk) { 'disk report OK' } else { 'disk report FAILED' })
            $lblAudit.Text      = ($parts -join ', ') + ' - see audit.log'
            $lblAudit.ForeColor = [System.Drawing.Color]::Firebrick
        }
    }

    $btnAudit.Add_Click({ Invoke-GuiAuditTools })

    $btnWifi.Add_Click({
        $speeds['wifi'] = Invoke-GuiSpeedTest '3' 'wifi' 'wifispeedtest.json' $btnWifi $lblWifi
    })

    $btnCable.Add_Click({
        $speeds['cable'] = Invoke-GuiSpeedTest '4' 'cable' 'cablespeedtest.json' $btnCable $lblCable
    })

    # --- buttons ---

    $btnOk.Add_Click({
        $problems = New-Object System.Collections.ArrayList
        if (-not $txtRealName.Text.Trim()) { [void]$problems.Add('Question 1 - the real name is required.') }
        if (-not $txtLogin.Text.Trim())    { [void]$problems.Add('Question 2 - the username is required.') }
        if (-not $txtMailbox.Text.Trim())  { [void]$problems.Add('Question 9 - the email space is required.') }
        foreach ($k in @('admin', 'password', 'antivirus', 'sticker')) {
            if (-not ($radios[$k].Yes.Checked -or $radios[$k].No.Checked)) {
                [void]$problems.Add("Question $(@{admin=5; password=6; antivirus=7; sticker=8}[$k]) - answer Yes or No.")
            }
        }
        if ($problems.Count) {
            [void][System.Windows.Forms.MessageBox]::Show(
                $form,
                ("Please finish these first:`r`n`r`n" + ($problems -join "`r`n")),
                'Incomplete',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning)
            return
        }
        $form.Tag = 'ok'
        $form.Close()
    })

    $btnCancel.Add_Click({
        $answer = [System.Windows.Forms.MessageBox]::Show(
            $form,
            'Cancel the audit? Nothing has been saved yet.',
            'Cancel audit',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) { $form.Close() }
    })

    Write-Info 'Answer the questions in the window that just opened.'

    # Out of the way while the form has the screen. The finally guarantees it
    # comes back even if something in the dialog throws - leaving the operator
    # with a minimised console and no window would look like a crash.
    Set-ConsoleWindowState -State 'Minimised'
    try {
        [void]$form.ShowDialog()
    } finally {
        Set-ConsoleWindowState -State 'Restored'
    }

    # Closing with the X behaves like Cancel. Falling back to the console
    # after someone deliberately closed the window would just be ignoring
    # them, so this ends the run instead.
    if ([string]$form.Tag -ne 'ok') {
        $form.Dispose()
        Write-Log 'GUI: cancelled by the operator, nothing was written.'
        Write-Host ''
        Write-Warn 'Cancelled. No files were written.'
        Write-Host ''
        Read-Host '  Press Enter to close'
        exit 6
    }

    $yn = { param($k) if ($radios[$k].Yes.Checked) { 'Yes' } else { 'No' } }

    $issues = $txtIssues.Text.Trim()
    if (-not $issues) { $issues = 'None reported' }

    $result = [ordered]@{
        'Hostname'             = $Hostname
        'Real name'            = $txtRealName.Text.Trim()
        'Login username'       = $txtLogin.Text.Trim()
        'WiFi download'        = $speeds['wifi'][0]
        'WiFi upload'          = $speeds['wifi'][1]
        'Cable download'       = $speeds['cable'][0]
        'Cable upload'         = $speeds['cable'][1]
        'Admin access'         = (& $yn 'admin')
        'Password set'         = (& $yn 'password')
        'Antivirus'            = (& $yn 'antivirus')
        'Windows sticker'      = (& $yn 'sticker')
        'Email space'          = $txtMailbox.Text.Trim()
        'Technical issues'     = $issues
        'Audited by'           = $identity.Name
        'Audit date'           = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    }

    $form.Dispose()
    Write-Log 'Answers collected from the GUI.'
    return $result
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
        if ($script:PumpUiEvents) {
            if ($script:UiStatusLabel) {
                $script:UiStatusLabel.Text = '{0}: {1:mm\:ss} elapsed, please wait...' -f $Name, $sw.Elapsed
            }
            [System.Windows.Forms.Application]::DoEvents()
        }
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

# Question 10 can arrive as several lines now that the GUI gives it a
# multi-line box. Put the first line against the label and indent the rest
# underneath, so a multi-line answer cannot knock the two-column layout out
# of true. Single-line values come out byte-identical to the old formatting.
function Format-LabelledValue {
    param(
        [string]$Label,
        [string]$Value,
        [int]   $Pad,
        [string]$Prefix    = '',
        [string]$Separator = ': '
    )
    $lines  = @(([string]$Value) -split "`r?`n")
    $indent = '{0}{1}{2}' -f $Prefix, (' ' * $Pad), (' ' * $Separator.Length)
    $out    = New-Object System.Collections.ArrayList

    [void]$out.Add(('{0}{1}{2}{3}' -f $Prefix, $Label.PadRight($Pad), $Separator, $lines[0]).TrimEnd())
    for ($i = 1; $i -lt $lines.Count; $i++) {
        [void]$out.Add(($indent + $lines[$i]).TrimEnd())
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

# ------------------------------------------------------------------
#  Applications audit
#
#  WinAudit and CrystalDiskInfo, plus all the post-processing that goes
#  with them. This lives in a function so both front ends can drive it:
#  the console flow calls it in sequence as it always did, while the GUI
#  runs it from its own button, letting the tools work through their few
#  minutes while the technician is still answering questions.
#
#  State goes into $script: flags rather than a return value - the summary
#  section needs four separate pieces of it, and the prefix keeps that
#  visible at every use rather than relying on scope luck.
# ------------------------------------------------------------------

$script:ToolsHaveRun  = $false
$script:WinAuditOk    = $false
$script:DiskInfoOk    = $false
$script:WinAuditSaved = @()
$script:DiskInfoDest  = $null

function Invoke-AuditTools {
    param([string]$Title = 'RUNNING APPLICATIONS AUDIT')

    # Set before any work, not after: a tool that throws must not leave the
    # main flow thinking it still has to run everything a second time.
    $script:ToolsHaveRun = $true

    # Reset, because the GUI button can run this more than once. Without it a
    # second pass would append to $WinAuditSaved and push its count past the
    # number of formats, turning a good run into a reported failure.
    $script:WinAuditSaved = @()
    $script:WinAuditOk    = $false
    $script:DiskInfoOk    = $false

    Write-Title $Title

    # ---------------- WinAudit ----------------

    # WinAudit resolves a RELATIVE /f= against its own folder rather than the
    # working directory, but it handles an absolute path fine even when that
    # path contains spaces. So point it straight at the machine folder - the
    # report never passes through the root, and because the machine folder is
    # created fresh for every run there is no stale output to guard against.
    #
    # One pass per format: WinAudit writes a single format per invocation, so
    # two formats means collecting everything twice.
    $winAuditLogs = @()

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
        $script:WinAuditSaved += $dest
    }

    # Only a clean sweep counts, so a missing second format still shows as a
    # failure rather than passing quietly.
    $script:WinAuditOk = $script:WinAuditSaved.Count -eq $WinAuditFormats.Count

    # Fold WinAudit's own logs into audit.log if anything went wrong, then bin
    # them so the machine folder keeps to the files that matter.
    foreach ($fmtLog in $winAuditLogs) {
        if (-not (Test-Path -LiteralPath $fmtLog)) { continue }

        if (-not $script:WinAuditOk) {
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

    $script:DiskInfoDest = Join-Path $ExportDir "${Hostname}_diskinfo.txt"

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
            Move-Item -LiteralPath $DiskInfoTxtSrc -Destination $script:DiskInfoDest -Force
            $script:DiskInfoOk = $true
            Write-Ok 'Disk / SMART report saved'
            Write-Log "Disk report saved: $script:DiskInfoDest"
        } else {
            Write-Fail 'CrystalDiskInfo finished but wrote no DiskInfo.txt.'
            Write-Log 'CrystalDiskInfo produced no DiskInfo.txt.'
        }
    }

    Save-Log
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

# The form is the default front end. -Console asks for the original prompts
# outright, and Get-AnswersGui returns $null when no form can be shown, so
# either way the interview below runs only when it is actually needed.
if (-not $Console) { $answers = Get-AnswersGui }

while ($null -eq $answers) {

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

    # Throw the rejected set away so the loop condition sends us round again.
    $answers = $null
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
    Format-LabelledValue -Label $key -Value $answers[$key] -Pad 24 |
        ForEach-Object { [void]$txt.Add($_) }
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

# The GUI's "Run audit apps" button may already have done all of this while
# the questions were being answered. Only run it here if it did not.
if (-not $script:ToolsHaveRun) {
    Invoke-AuditTools -Title 'PART 2 OF 2  -  RUNNING APPLICATIONS AUDIT'
} else {
    Write-Host ''
    Write-Info 'Applications audit already completed from the questions window.'
}

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
    Format-LabelledValue -Label $key -Value $answers[$key] -Pad $notePad `
                         -Prefix '    ' -Separator ' : ' | ForEach-Object { Add-Report $_ }
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

$rtfText = if ($script:WinAuditOk) { Convert-RtfToText $script:WinAuditSaved[0] } else { $null }

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
$section = if ($script:DiskInfoOk) { Get-DiskInfoSummary $script:DiskInfoDest } else { $null }
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
if ($script:WinAuditOk) { Write-Host 'saved' -ForegroundColor Green } else { Write-Host 'FAILED' -ForegroundColor Red }
Write-Host '  Disk / SMART report           ' -NoNewline -ForegroundColor White
if ($script:DiskInfoOk) { Write-Host 'saved' -ForegroundColor Green } else { Write-Host 'FAILED' -ForegroundColor Red }
Write-Host '  REPORT_SUMMARY.txt            ' -NoNewline -ForegroundColor White
if ($summaryOk) { Write-Host 'saved' -ForegroundColor Green } else { Write-Host 'FAILED' -ForegroundColor Red }
Write-Host ''

if ($script:WinAuditOk -and $script:DiskInfoOk -and $summaryOk) {
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
