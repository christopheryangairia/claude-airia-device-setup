# airia-claude-cred-helper.ps1 (Windows)
#
# Claude Desktop credential helper for an Airia AI Gateway in User Impersonation
# mode. Pushed identically to every PC by MDM; it carries no secrets and no
# per-user values.
#
# First run for a user: no token stored yet, so it runs `claude setup-token`
# itself. The user's browser opens once, they approve with their own Claude
# account, and the resulting 1-year token is stored encrypted with DPAPI
# (CurrentUser) under %LOCALAPPDATA%\Airia. Every later run just reads it.
#
# Desktop config (managed, HKLM\SOFTWARE\Policies\Claude or the .reg kit):
#   inferenceProvider                     gateway
#   inferenceGatewayAuthScheme            bearer
#   inferenceCredentialKind               helper-script
#   inferenceCredentialHelperWindows      C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe
#   inferenceCredentialHelperArgs         ["-NoProfile","-NonInteractive","-ExecutionPolicy","Bypass",
#                                          "-File","C:\Program Files\Airia\airia-claude-cred-helper.ps1"]
#   inferenceCredentialHelperTimeoutSec   600   (the maximum; an SSO sign-in can take
#                                                 4-5 minutes, measured at 272s on a VM)
#   inferenceCustomHeaders                {"x-airia-key":"agk-..."}
#
# Contract: Desktop reads a bare token from stdout. Diagnostics go to stderr.
# Re-mint: run with -Reset, or delete %LOCALAPPDATA%\Airia\claude-gateway-token.dat.

param([switch]$Reset)

$ErrorActionPreference = 'Stop'
$StoreDir   = Join-Path $env:LOCALAPPDATA 'Airia'
$StoreFile  = Join-Path $StoreDir 'claude-gateway-token.dat'
$MaxAgeDays = 350

function Log([string]$m) { [Console]::Error.WriteLine("airia-claude-cred-helper: $m") }

function Read-Token {
    if (-not (Test-Path $StoreFile)) { return $null }
    if (((Get-Date) - (Get-Item $StoreFile).LastWriteTime).TotalDays -ge $MaxAgeDays) { return $null }
    try {
        $sec  = Get-Content -Raw $StoreFile | ConvertTo-SecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    } catch { Log "stored token unreadable; signing in again"; return $null }
}

function Save-Token([string]$tok) {
    New-Item -ItemType Directory -Force -Path $StoreDir | Out-Null
    ConvertTo-SecureString $tok -AsPlainText -Force | ConvertFrom-SecureString | Set-Content -NoNewline $StoreFile
}

# Desktop re-runs the helper as soon as the gateway rejects a token, so a
# revoked token would otherwise be handed back forever. count_tokens is free and
# answers 401 only for a revoked or invalid token. Anything else, including no
# route to api.anthropic.com, keeps the cached token; an unreachable result is
# remembered for an hour so a gateway-only network doesn't pay the timeout on
# every launch.
function Test-TokenRevoked([string]$tok) {
    $stamp = Join-Path $StoreDir 'anthropic-unreachable'
    if ((Test-Path $stamp) -and ((Get-Date) - (Get-Item $stamp).LastWriteTime).TotalSeconds -lt 3600) { return $false }
    try {
        Invoke-WebRequest -UseBasicParsing -TimeoutSec 4 -Method Post -Uri 'https://api.anthropic.com/v1/messages/count_tokens' `
            -Headers @{ authorization = "Bearer $tok"; 'anthropic-beta' = 'oauth-2025-04-20'; 'anthropic-version' = '2023-06-01' } `
            -ContentType 'application/json' -Body '{"model":"claude-haiku-4-5","messages":[{"role":"user","content":"x"}]}' | Out-Null
        return $false
    } catch {
        $resp = $_.Exception.Response
        if ($resp) { return ([int]$resp.StatusCode -eq 401) }
        New-Item -ItemType Directory -Force -Path $StoreDir | Out-Null
        Set-Content -Path $stamp -Value ''
        return $false
    }
}

function Find-Claude {
    $c = @(
        (Get-Command claude.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source),
        (Join-Path $env:USERPROFILE '.local\bin\claude.exe'),
        # The copy Claude Desktop installs for its Code tab.
        (Get-ChildItem -ErrorAction SilentlyContinue -Recurse -Filter claude.exe -Path (Join-Path $env:LOCALAPPDATA 'Claude-3p\claude-code') |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName)
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    return $c
}

# setup-token needs a terminal and Desktop gives the helper none. ConPTY
# (Windows 10 1809+) supplies one, the same job `script` does on macOS.
$conPty = @'
using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class AiriaConPty {
    [StructLayout(LayoutKind.Sequential)] struct COORD { public short X; public short Y; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO {
        public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
        public int dwX; public int dwY; public int dwXSize; public int dwYSize;
        public int dwXCountChars; public int dwYCountChars; public int dwFillAttribute; public int dwFlags;
        public short wShowWindow; public short cbReserved2; public IntPtr lpReserved2;
        public IntPtr hStdInput; public IntPtr hStdOutput; public IntPtr hStdError;
    }
    [StructLayout(LayoutKind.Sequential)] struct STARTUPINFOEX { public STARTUPINFO StartupInfo; public IntPtr lpAttributeList; }
    [StructLayout(LayoutKind.Sequential)] struct PROCESS_INFORMATION { public IntPtr hProcess; public IntPtr hThread; public int dwProcessId; public int dwThreadId; }

    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CreatePipe(out SafeFileHandle r, out SafeFileHandle w, IntPtr sa, int size);
    [DllImport("kernel32.dll", SetLastError = true)] static extern int CreatePseudoConsole(COORD size, SafeFileHandle hIn, SafeFileHandle hOut, uint flags, out IntPtr hPC);
    [DllImport("kernel32.dll", SetLastError = true)] static extern void ClosePseudoConsole(IntPtr hPC);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attr, IntPtr value, IntPtr size, IntPtr prev, IntPtr retSize);
    [DllImport("kernel32.dll", SetLastError = true)] static extern void DeleteProcThreadAttributeList(IntPtr list);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcess(string app, string cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string dir, ref STARTUPINFOEX si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll", SetLastError = true)] static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool TerminateProcess(IntPtr h, uint code);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr h);

    static StringBuilder sb;
    static IntPtr hProc, hPCs, attrs;
    static SafeFileHandle inW;
    static Thread rdr;

    public static string Output { get { lock (sb) return sb.ToString(); } }
    public static bool HasExited { get { return WaitForSingleObject(hProc, 0) == 0; } }

    // Starts commandLine under a pseudo console; read Output while it runs.
    public static void Start(string commandLine) {
        SafeFileHandle inRead, inWrite, outRead, outWrite;
        if (!CreatePipe(out inRead, out inWrite, IntPtr.Zero, 0) || !CreatePipe(out outRead, out outWrite, IntPtr.Zero, 0))
            throw new Exception("CreatePipe failed: " + Marshal.GetLastWin32Error());
        COORD size; size.X = 400; size.Y = 50;
        IntPtr hPC;
        int hr = CreatePseudoConsole(size, inRead, outWrite, 0, out hPC);
        if (hr != 0) throw new Exception("CreatePseudoConsole failed: 0x" + hr.ToString("X"));
        inRead.Dispose(); outWrite.Dispose();

        sb = new StringBuilder();
        FileStream outStream = new FileStream(outRead, FileAccess.Read);
        rdr = new Thread(delegate() {
            byte[] buf = new byte[8192];
            Decoder dec = Encoding.UTF8.GetDecoder();
            char[] chars = new char[16384];
            try {
                int n;
                while ((n = outStream.Read(buf, 0, buf.Length)) > 0) {
                    int c = dec.GetChars(buf, 0, n, chars, 0);
                    lock (sb) sb.Append(chars, 0, c);
                }
            } catch (IOException) { }
        });
        rdr.IsBackground = true;
        rdr.Start();
        hPCs = hPC; inW = inWrite;

        IntPtr attrSize = IntPtr.Zero;
        InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref attrSize);
        IntPtr attrList = Marshal.AllocHGlobal(attrSize);
        try {
            if (!InitializeProcThreadAttributeList(attrList, 1, 0, ref attrSize))
                throw new Exception("InitializeProcThreadAttributeList failed: " + Marshal.GetLastWin32Error());
            if (!UpdateProcThreadAttribute(attrList, 0, (IntPtr)0x00020016, hPC, (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero))
                throw new Exception("UpdateProcThreadAttribute failed: " + Marshal.GetLastWin32Error());
            STARTUPINFOEX si = new STARTUPINFOEX();
            si.StartupInfo.cb = Marshal.SizeOf(typeof(STARTUPINFOEX));
            si.lpAttributeList = attrList;
            // The helper's own stdout is a pipe to Claude Desktop. Without this flag the
            // child inherits that pipe and writes past the pseudo console.
            si.StartupInfo.dwFlags = 0x00000100; // STARTF_USESTDHANDLES, handles left null
            PROCESS_INFORMATION pi;
            // EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT
            if (!CreateProcess(null, commandLine, IntPtr.Zero, IntPtr.Zero, false, 0x00080000 | 0x00000400, IntPtr.Zero, null, ref si, out pi))
                throw new Exception("CreateProcess failed: " + Marshal.GetLastWin32Error());
            CloseHandle(pi.hThread);
            hProc = pi.hProcess; attrs = attrList;
        } catch {
            ClosePseudoConsole(hPC);
            DeleteProcThreadAttributeList(attrList);
            Marshal.FreeHGlobal(attrList);
            throw;
        }
    }

    // Waits for exit (killing it after timeoutMs) and releases the pseudo console.
    public static void Finish(int timeoutMs) {
        if (WaitForSingleObject(hProc, (uint)timeoutMs) != 0) TerminateProcess(hProc, 1);
        CloseHandle(hProc);
        ClosePseudoConsole(hPCs);
        DeleteProcThreadAttributeList(attrs);
        Marshal.FreeHGlobal(attrs);
        rdr.Join(5000);
        inW.Dispose();
    }
}
'@

# What BROWSER points at. Setting BROWSER to explorer.exe opened nothing on some
# PCs even though explorer.exe opens the same URL fine from a prompt, so hand the
# CLI a tiny exe instead. It takes the URL however it is passed, logs the raw
# command line, and opens it with ShellExecute (the default browser).
$openUrl = @'
using System;
using System.IO;
using System.Diagnostics;
using System.Text.RegularExpressions;

public static class AiriaOpenUrl {
    public static int Main(string[] args) {
        string raw = Environment.CommandLine;
        string dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Airia");
        try { File.AppendAllText(Path.Combine(dir, "browser-launch.log"), DateTime.Now.ToString("s") + " " + raw + Environment.NewLine); } catch { }
        Match m = Regex.Match(raw, "https?://[^\\s\"']+");
        if (!m.Success) return 1;
        Process.Start(new ProcessStartInfo(m.Value) { UseShellExecute = true });
        return 0;
    }
}
'@

function Get-BrowserLauncher {
    $exe = Join-Path $StoreDir 'airia-open-url.exe'
    if (Test-Path $exe) { return $exe }
    New-Item -ItemType Directory -Force -Path $StoreDir | Out-Null
    try {
        Add-Type -TypeDefinition $openUrl -Language CSharp -OutputAssembly $exe -OutputType WindowsApplication
        return $exe
    } catch {
        Log "could not build the browser launcher ($($_.Exception.Message)); falling back to explorer.exe"
        return (Join-Path $env:WINDIR 'explorer.exe')
    }
}

function Get-NewToken {
    $claude = Find-Claude
    if (-not $claude) {
        Log 'Claude Code CLI not found; installing it for setup-token'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command 'irm https://claude.ai/install.ps1 | iex' 2>&1 | ForEach-Object { Log "$_" }
        $claude = Find-Claude
        if (-not $claude) { throw 'claude.exe still not found after install' }
    }
    if (-not ('AiriaConPty' -as [type])) { Add-Type -TypeDefinition $conPty -Language CSharp }
    Log 'no gateway token for this user; opening the browser for a one-time Claude sign-in'
    # The CLI's own browser launch fails silently when Desktop runs this helper, but
    # it honors BROWSER, and the URL it hands over has the localhost callback that
    # finishes sign-in without a code to paste. Get-BrowserLauncher opens it in the default browser.
    $env:BROWSER = Get-BrowserLauncher
    [AiriaConPty]::Start("`"$claude`" setup-token")
    # The CLI opens the browser itself, with a localhost callback that completes the
    # sign-in on its own. Don't open the printed URL instead: that one ends on a page
    # showing a code to paste into the terminal, and the user has no terminal here.
    # Desktop stops waiting at inferenceCredentialHelperTimeoutSec (600) but does not
    # kill the helper, so give up first and terminate setup-token ourselves.
    $deadline = (Get-Date).AddSeconds(570)
    while (-not [AiriaConPty]::HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
    [AiriaConPty]::Finish(5000)
    $raw = [AiriaConPty]::Output
    $raw = $raw -replace "\x1b\][^\x07\x1b]*(\x07|\x1b\\)", ''
    $raw = $raw -replace "\x1b\[[0-9;?<>]*[A-Za-z~]", ''
    $raw = $raw -replace "\x1b[78()][A-Z0-9]?", ''
    New-Item -ItemType Directory -Force -Path $StoreDir | Out-Null
    ($raw -replace 'sk-ant-oat01-[A-Za-z0-9_\-\s]+', 'sk-ant-oat01-<redacted>') | Set-Content (Join-Path $StoreDir 'setup-token.log')
    $i = $raw.LastIndexOf('sk-ant-oat01-')
    if ($i -lt 0) { throw 'sign-in did not complete (no token returned)' }
    $m = [regex]::Match($raw.Substring($i), '^sk-ant-oat01-[A-Za-z0-9_\-\s]+?(?=Store|$)')
    $tok = $m.Value -replace '\s', ''
    if ($tok.Length -lt 40) { throw 'could not read the token from setup-token output' }
    Save-Token $tok
    Log "token stored for $env:USERNAME ($StoreFile, DPAPI)"
    return $tok
}

try {
    if ($Reset) {
        Remove-Item -Force -ErrorAction SilentlyContinue $StoreFile
        Log 'token removed; the next Claude Desktop launch signs in again'
        exit 0
    }
    $tok = Read-Token
    if ($tok -and (Test-TokenRevoked $tok)) {
        Log 'stored token was revoked or is invalid; signing in again'
        Remove-Item -Force -ErrorAction SilentlyContinue $StoreFile
        $tok = $null
    }
    if (-not $tok) {
        # One sign-in at a time; Desktop can call the helper from several places.
        $mutex = New-Object System.Threading.Mutex($false, 'Local\AiriaClaudeCredHelper')
        # A helper killed mid sign-in abandons the mutex; the next waiter still owns it.
        $owned = $false
        try { $owned = $mutex.WaitOne(580000) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
        try {
            $tok = Read-Token
            if (-not $tok) { $tok = Get-NewToken }
        } finally { if ($owned) { $mutex.ReleaseMutex() } }
    }
    [Console]::Out.Write($tok + "`n")
    exit 0
} catch {
    Log $_.Exception.Message
    exit 1
}
