# Install Mandalin

Run the command for your platform and follow the prompts.

## One command

You'll need a GitHub account with access to Mandalin. The installer guides login
when needed.

macOS, glibc Linux, or Windows **Git Bash**:

```bash
curl -fsSL --proto '=https' --proto-redir '=https' https://raw.githubusercontent.com/erk1ny/mandalin-install/main/bootstrap.sh | bash
```

Native Windows **PowerShell** (no Bash required):

```powershell
& ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/erk1ny/mandalin-install/main/bootstrap.ps1').Content))
```

## What happens

1. Check the OS/architecture and reuse Node.js 22.19+ when present. Otherwise ask
   to download official Node 24 into `~/.mandalin/runtimes`, verifying its SHA-256.
2. Ask to install missing Git through Apple Command Line Tools, Linux's existing
   apt/dnf/pacman/zypper, or Windows winget. Only that OS prerequisite can need
   administrator approval. An Apple installer must finish before continuing.
3. Try existing Git access without interactive credential prompts. If access
   fails, offer a checksum-verified local GitHub CLI, start browser/device login
   when necessary, and configure Git's per-user GitHub credential helper with
   consent. Recheck access before cloning. Login cannot grant repository
   membership: a team invitation is required if the account lacks access.
4. Select the highest stable `vX.Y.Z` tag. If no tag exists, explicitly ask before
   using the main-branch pilot. Tags can appear before release CI completes.
5. Reuse JDK 21 or offer checksum-verified Eclipse Temurin 21 in the managed
   runtime folder, without replacing system Java.
6. Clone into `~/.mandalin/app` and run the normal install/build/doctor process.
   Existing unrelated directories or dirty checkouts are refused; clean reruns
   use fast-forward-only updates. No reset, deletion or stashing of user work.
7. Offer user PATH/Java configuration. Unix shell files are backed up before
   adding an idempotent source line; Windows changes only user environment values.
8. Offer to open `mandalin setup`, which starts in Connections for model-provider
   login. GitHub login and model-provider subscriptions are separate.

Burp Suite itself and optional security tools are not silently installed. The
installer prints the built `mandalin-burp.jar` path and where to load it in Burp.
Temporary downloads are retained for inspection; setup failure does not erase
research data. Do not delete/move the managed checkout or active runtimes.

## Platforms and boundaries

- macOS: x64/ARM64, Bash/Zsh/Fish shell setup; native dependency support depends
  on the supported OS versions of Node/Pi and Temurin.
- Linux: x64/ARM64 with glibc, curl and tar. Alpine/musl is rejected. Install Git
  manually if the distribution has no supported package manager.
- Windows: x64/ARM64 entry points, with existing Git Bash or native PowerShell.
  Missing Git needs winget; otherwise install Git for Windows and rerun. Runtime
  package availability and native dependency support can still limit a platform.
- WSL is a Linux installation, not a native Windows installation. To connect a
  Windows Burp process, use the native Windows installer unless separately
  configuring the WSL/Windows bridge.
- A fresh Windows machine cannot execute `curl | bash` without Bash. Use the
  PowerShell command instead; the installer does not pretend Bash is universal.
- Interactive terminal required. No blanket `--yes` mode, automatic elevation,
  antivirus exclusions, proxy bypasses or credential copying.

Use an absolute `MANDALIN_HOME` to relocate the managed data/checkouts. The normal
installer also honors `MANDALIN_PREFIX` and explicit Pi directory overrides.
For another public host, set `MANDALIN_BOOTSTRAP_URL` to the HTTPS directory
containing all three bootstrap files for the bootstrap process.
