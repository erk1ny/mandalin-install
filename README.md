# Install Mandalin

macOS or glibc Linux:

```bash
curl -fsSL --proto '=https' --proto-redir '=https' https://raw.githubusercontent.com/erk1ny/mandalin-install/main/bootstrap.sh | bash
```

Windows PowerShell:

```powershell
& ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/erk1ny/mandalin-install/main/bootstrap.ps1').Content))
```

Git Bash can also use the first command. WSL installs the Linux version.

## Setup

1. Confirm installation.
2. Sign into GitHub if needed, using the account invited to the private download repository.
3. Download and verify the matching prebuilt package.
4. Add the launcher to your user PATH and open Mandalin.

No cloning, npm install, compilation, JDK or Gradle is needed. The package includes
Node, npm/npx, production dependencies and the built Burp extension. A small
checksum-verified GitHub CLI helper is downloaded if not already available.
No administrator rights are required for this base installation.

The installer selects a published stable release only when its platform archive
and checksum are present. If no package is available, it stops; it does not fall
back to a development build. Maintainers must publish a portable release before
deploying this installer. Releases predating portable packages are not compatible.

## Burp extension

Select **Extensions → Installed → Add → Java** in Burp, then choose:

- macOS/Linux: `~/Mandalin/Burp/mandalin-burp.jar`
- Windows: `%USERPROFILE%\Mandalin\Burp\mandalin-burp.jar`

This is a normal, visible folder. A versioned copy is also kept there.
Burp Suite itself is installed separately.

## Updates and integrations

Run `mandalin` from a target directory. Open Connections to sign in to model
providers; GitHub download access and model subscriptions are separate.

The Agents menu checks for releases every 30 minutes. Confirm with `u`, or run
`mandalin update`. Updates verify and activate a new package; no local build is
needed. Restart Mandalin afterward. `mandalin rollback` restores the previous
version after an update.

Optional integrations retain their guided setup chats. Node/npm/npx are available
to their tools. External engines, Git for Git-based integrations, paid licenses and
platform-specific runtimes are separate choices—not silently installed. Keep
their tools/configuration in the integration workspace, not in an app version.

Sessions, credentials, integration data and downloaded tools stay in
`~/.mandalin`. Application versions are kept separately under `~/.mandalin/versions`.
An existing source checkout is preserved when switching to packaged installation.

## Options

- `MANDALIN_HOME`: absolute application-data directory.
- `MANDALIN_BURP_DIR`: absolute visible Burp JAR destination.
- `MANDALIN_DISTRIBUTION_REPOSITORY`: private GitHub download repository
  (`owner/repo`); defaults to `erk1ny/mandalin`.

Supported package targets: macOS, glibc Linux and Windows, each x64/ARM64.
Use an interactive terminal. For account problems, retry after accepting the
invite, choose browser login, or explicitly select another saved account.
Completing the device-code authorization—not merely opening GitHub—finishes login.
