# Switches which Antigravity account `agy` runs on, by swapping the OAuth
# credential in Windows Credential Manager.
#
# agy has no --account or --profile flag. Its token lives under one fixed
# generic credential target, "gemini:antigravity", per Windows user. The only
# way to run a second subscription *as you*, in your own herdr pane with a real
# TUI, is to keep both accounts' credentials in a vault under different target
# names and copy the wanted one into the live target before starting an agent.
#
# This script never prints a credential blob. It prints a truncated SHA-256 of
# one, which is enough to tell two accounts apart and useless to anyone else.
#
# agy refreshes its OAuth token during a session and writes the new one back to
# the live target (measured: sessions started at 12:44 were still running when
# the entry was rewritten at 14:39). Two things follow. Accounts cannot be mixed
# while agents run, because a running agent will clobber a credential we swapped
# in. And a vault entry goes stale as soon as its account has done any work, so
# the live credential must be synced back to its own vault entry before another
# one is swapped over it. Which account is live is therefore tracked in a state
# file: after a refresh the blob no longer matches anything in the vault, so the
# hash cannot answer that question.
#
# Modes:
#   list                      what is in the vault, and what is live right now
#   save    -Account a|b      copy the live credential into the vault
#   use     -Account a|b      sync the outgoing account, then make a|b live
#   sync                      copy the live credential back over its own vault entry
#   watch   -Minutes N        poll the live credential and report every change
[CmdletBinding()]
param(
  [ValidateSet('list','save','use','sync','watch')][string]$Mode = 'list',
  [ValidateSet('a','b')][string]$Account,
  [int]$Minutes = 90,
  [int]$IntervalSeconds = 60,
  # `use` refuses to run while an agent is live, because the live target is
  # shared by every agy process on this profile.
  [switch]$Force
)

$ErrorActionPreference = 'Stop'

$LIVE  = 'gemini:antigravity'
$VAULT = @{ a = 'herdr-swarm:agy-a'; b = 'herdr-swarm:agy-b' }
$STATE = Join-Path $env:LOCALAPPDATA 'herdr-swarm\live-account'

Add-Type -Namespace Swarm -Name Cred -MemberDefinition @'
[StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
public struct CREDENTIAL {
  public uint Flags; public uint Type; public string TargetName; public string Comment;
  public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
  public uint CredentialBlobSize; public IntPtr CredentialBlob; public uint Persist;
  public uint AttributeCount; public IntPtr Attributes; public string TargetAlias; public string UserName;
}
[DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
public static extern bool CredRead(string target, uint type, uint flags, out IntPtr credential);
[DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
public static extern bool CredWrite([In] ref CREDENTIAL credential, uint flags);
[DllImport("advapi32.dll")] public static extern void CredFree(IntPtr buffer);
'@

function Read-Cred([string]$target) {
  $ptr = [IntPtr]::Zero
  if (-not [Swarm.Cred]::CredRead($target, 1, 0, [ref]$ptr)) { return $null }
  try {
    $c = [Runtime.InteropServices.Marshal]::PtrToStructure($ptr, [type][Swarm.Cred+CREDENTIAL])
    $bytes = New-Object byte[] $c.CredentialBlobSize
    if ($c.CredentialBlobSize -gt 0) {
      [Runtime.InteropServices.Marshal]::Copy($c.CredentialBlob, $bytes, 0, $c.CredentialBlobSize)
    }
    $ticks = ([long]$c.LastWritten.dwHighDateTime -shl 32) -bor ([long]$c.LastWritten.dwLowDateTime -band 0xFFFFFFFFL)
    [pscustomobject]@{
      Bytes       = $bytes
      UserName    = $c.UserName
      Comment     = $c.Comment
      Persist     = $c.Persist
      LastWritten = [datetime]::FromFileTime($ticks)
      # Truncated on purpose: enough to compare two blobs, not enough to be a secret.
      Sha         = [BitConverter]::ToString([Security.Cryptography.SHA256]::HashData($bytes)).Replace('-','').Substring(0,12)
    }
  } finally { [Swarm.Cred]::CredFree($ptr) }
}

function Write-Cred([string]$target, $src) {
  $blob = [Runtime.InteropServices.Marshal]::AllocHGlobal($src.Bytes.Length)
  try {
    [Runtime.InteropServices.Marshal]::Copy($src.Bytes, 0, $blob, $src.Bytes.Length)
    $c = New-Object Swarm.Cred+CREDENTIAL
    $c.Type = 1                      # CRED_TYPE_GENERIC
    $c.TargetName = $target
    $c.Comment = $src.Comment
    $c.CredentialBlobSize = $src.Bytes.Length
    $c.CredentialBlob = $blob
    $c.Persist = $src.Persist
    $c.UserName = $src.UserName
    if (-not [Swarm.Cred]::CredWrite([ref]$c, 0)) {
      throw (New-Object ComponentModel.Win32Exception([Runtime.InteropServices.Marshal]::GetLastWin32Error())).Message
    }
  } finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($blob) }
}

function Show([string]$label, [string]$target) {
  $c = Read-Cred $target
  if ($c) {
    $user = if ($c.UserName) { $c.UserName } else { '-' }
    '{0,-8} {1,-24} sha={2} size={3} user={4} written={5}' -f $label, $target, $c.Sha, $c.Bytes.Length, $user, $c.LastWritten.ToString('yyyy-MM-dd HH:mm:ss')
  } else {
    '{0,-8} {1,-24} (empty)' -f $label, $target
  }
}

function Agy-Count { @(Get-Process -Name agy -ErrorAction SilentlyContinue).Count }

function Get-LiveAccount {
  if (Test-Path $STATE) { (Get-Content $STATE -Raw).Trim() } else { $null }
}

function Set-LiveAccount([string]$account) {
  $dir = Split-Path $STATE -Parent
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  Set-Content -Path $STATE -Value $account -NoNewline
}

# Copies the live credential back over the vault entry of whichever account is
# live, so a token agy refreshed during a session is not lost when that account
# is swapped out and later swapped back in.
function Sync-Live {
  $acct = Get-LiveAccount
  if (-not $acct) { return "cannot sync: no record of which account is live" }
  $live = Read-Cred $LIVE
  if (-not $live) { return "cannot sync: no live credential" }
  $vault = Read-Cred $VAULT[$acct]
  if ($vault -and $vault.Sha -eq $live.Sha) { return "vault '$acct' already current (sha=$($live.Sha))" }
  Write-Cred $VAULT[$acct] $live
  "synced live credential (sha=$($live.Sha)) back into vault '$acct'"
}

switch ($Mode) {

  'list' {
    Show 'live' $LIVE
    Show 'vault a' $VAULT.a
    Show 'vault b' $VAULT.b
    # Not $account: PowerShell variable names are case-insensitive, so that
    # would assign to the $Account parameter and trip its ValidateSet.
    $current = Get-LiveAccount
    'account  {0}' -f $(if ($current) { "'$current' is live" } else { 'unknown (no state file yet)' })
    "agy      {0} process(es) running" -f (Agy-Count)
  }

  'save' {
    if (-not $Account) { throw 'save needs -Account a|b' }
    $live = Read-Cred $LIVE
    if (-not $live) { throw "No live credential under $LIVE. Run agy and sign in first." }
    Write-Cred $VAULT[$Account] $live
    Set-LiveAccount $Account
    "saved live credential (sha=$($live.Sha)) into vault '$Account', which is now recorded as live"
  }

  'sync' { Sync-Live }

  # Exit codes are the interface to scripts/lib.sh, which has to tell these
  # cases apart to decide between "run on the other account", "stop and report"
  # and "the vault is not set up yet".
  #   0 swapped, or already live   3 agents are running, so accounts would mix
  #   4 that vault entry is empty  5 no record of which account is live
  'use' {
    if (-not $Account) { throw 'use needs -Account a|b' }
    $v = Read-Cred $VAULT[$Account]
    if (-not $v) {
      [Console]::Error.WriteLine("Vault '$Account' is empty. Sign in as that account and run: -Mode save -Account $Account")
      exit 4
    }

    $current = Get-LiveAccount
    if ($current -eq $Account) {
      "account '$Account' is already live"
      exit 0
    }

    # One credential target serves every agy process on this profile, and a
    # running agent writes its refreshed token back to it. Swapping now would
    # both change that agent's account and lose the swapped-in credential.
    $running = Agy-Count
    if ($running -gt 0 -and -not $Force) {
      [Console]::Error.WriteLine("$running agy process(es) are running on account '$current'. Accounts cannot be mixed: wait for them to finish, or pass -Force to swap anyway.")
      exit 3
    }

    # The outgoing account's vault entry is stale the moment it has done any
    # work, because agy rewrote the live entry with a refreshed token.
    if (-not $current -and -not $Force) {
      [Console]::Error.WriteLine('No record of which account is live, so the current credential cannot be filed back into the vault and would be lost. Run: -Mode save -Account <the account you are signed in as>')
      exit 5
    }
    if ($current) { Sync-Live }

    Write-Cred $LIVE $v
    Set-LiveAccount $Account
    "live credential set to account '$Account' (sha=$($v.Sha))"
    exit 0
  }

  'watch' {
    # Answers one question: does agy rewrite the credential while a session is
    # running? If it does, the token is refreshed and persisted mid-session, and
    # swapping accounts under a live agent is unsafe by construction.
    $end  = (Get-Date).AddMinutes($Minutes)
    $prev = Read-Cred $LIVE
    if (-not $prev) { throw "No credential under $LIVE." }
    "watching $LIVE for $Minutes min, every $IntervalSeconds s"
    "start  sha=$($prev.Sha) size=$($prev.Bytes.Length) written=$($prev.LastWritten.ToString('yyyy-MM-dd HH:mm:ss')) agy_running=$(Agy-Count)"
    $changes = 0
    while ((Get-Date) -lt $end) {
      Start-Sleep -Seconds $IntervalSeconds
      $now = Read-Cred $LIVE
      if (-not $now) { "$(Get-Date -Format HH:mm:ss)  credential DISAPPEARED"; continue }
      if ($now.Sha -ne $prev.Sha -or $now.LastWritten -ne $prev.LastWritten) {
        $changes++
        "$(Get-Date -Format HH:mm:ss)  CHANGED sha=$($prev.Sha) -> $($now.Sha) size=$($now.Bytes.Length) written=$($now.LastWritten.ToString('HH:mm:ss')) agy_running=$(Agy-Count)"
        $prev = $now
      }
    }
    ''
    if ($changes -eq 0) {
      "VERDICT: no rewrite in $Minutes min. agy did not persist a refreshed token during this window."
    } else {
      "VERDICT: $changes rewrite(s). agy persists refreshed tokens, so the live credential must not be swapped while an agent runs."
    }
  }
}
