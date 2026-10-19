// Public setup code only. Never embed repository credentials, auth files or user data.
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createWriteStream } from 'node:fs';
import { access, appendFile, mkdir, mkdtemp, readFile, readdir, realpath, writeFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { basename, delimiter, dirname, join, resolve } from 'node:path';
import { createInterface } from 'node:readline/promises';
import { Readable, Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { fileURLToPath } from 'node:url';

export const REPOSITORY = 'erk1ny/mandalin';
export const REPOSITORY_URL = `https://github.com/${REPOSITORY}.git`;

export function platformSpec(platform = process.platform, arch = process.arch) {
  if (!['darwin', 'linux', 'win32'].includes(platform) || !['x64', 'arm64'].includes(arch)) {
    throw new Error(`Unsupported platform: ${platform}/${arch}. Use macOS, glibc Linux, or Windows on x64/ARM64.`);
  }
  return { platform, arch, windows: platform === 'win32', javaOs: { darwin: 'mac', linux: 'linux', win32: 'windows' }[platform],
    javaArch: arch === 'arm64' ? 'aarch64' : 'x64', ghOs: { darwin: 'macOS', linux: 'linux', win32: 'windows' }[platform],
    ghArch: arch === 'x64' ? 'amd64' : 'arm64', ghExtension: platform === 'linux' ? 'tar.gz' : 'zip' };
}

export function stableTag(output) {
  const tags = [...output.matchAll(/refs\/tags\/(v\d+\.\d+\.\d+)$/gmu)].map(match => match[1]);
  return tags.sort((a, b) => {
    const x = a.slice(1).split('.').map(Number); const y = b.slice(1).split('.').map(Number);
    return y[0] - x[0] || y[1] - x[1] || y[2] - x[2];
  })[0] ?? null;
}

export function checksumFor(text, name) {
  const line = text.split(/\r?\n/u).map(value => /^([a-f\d]{64})\s+\*?(.+)$/iu.exec(value)).find(value => value?.[2] === name);
  if (!line) throw new Error(`No SHA-256 checksum for ${name}`);
  return line[1].toLowerCase();
}

export function shellQuote(value) { return `'${value.replaceAll("'", "'\\''")}'`; }
export function mergeUserPath(current, additions) {
  const entries = (current ?? '').split(';').filter(Boolean);
  for (const addition of additions) if (!entries.some(entry => entry.replace(/[\\/]+$/u, '').toLowerCase() === addition.replace(/[\\/]+$/u, '').toLowerCase())) entries.push(addition);
  return entries.join(';');
}

export async function repositoryRefs({ readRefs, signIn }) {
  let refs = await readRefs();
  if (refs.code === 0) return refs;
  await signIn();
  refs = await readRefs();
  if (refs.code !== 0) throw new Error(`GitHub login did not grant repository access. Ask the owner to invite this account to ${REPOSITORY}; check connectivity too. No repository was cloned.`);
  return refs;
}

export function gitInstallPlan(platform, available) {
  if (platform === 'darwin') return { command: '/usr/bin/xcode-select', args: ['--install'], label: 'Apple Command Line Tools (Git); complete the Apple installer before continuing', wait: true };
  if (platform === 'win32') {
    if (!available.includes('winget')) throw new Error('Git is missing and winget is unavailable. Install Git for Windows, then rerun this installer.');
    return { command: 'winget', args: ['install', '--id', 'Git.Git', '--exact', '--source', 'winget', '--accept-source-agreements'], label: 'Git for Windows through winget; its installer may request administrator approval' };
  }
  const plans = {
    'apt-get': ['install', '-y', 'git', 'ca-certificates'], dnf: ['install', '-y', 'git', 'ca-certificates'],
    pacman: ['-S', '--needed', '--noconfirm', 'git', 'ca-certificates'], zypper: ['--non-interactive', 'install', 'git', 'ca-certificates'],
  };
  const command = Object.keys(plans).find(item => available.includes(item));
  if (!command) throw new Error('Install Git with your Linux distribution package manager, then rerun this installer.');
  return { command, args: plans[command], label: `Git and CA certificates through ${command} (may require sudo)` };
}

async function exists(path) { try { await access(path); return true; } catch { return false; } }
async function executable(name, env) {
  for (const entry of (env.PATH ?? env.Path ?? '').split(delimiter)) {
    if (!entry) continue;
    const candidate = join(entry, process.platform === 'win32' && !name.endsWith('.exe') ? `${name}.exe` : name);
    if (await exists(candidate)) return candidate;
  }
  return null;
}

function run(command, args, { env = process.env, cwd, capture = false, timeout = 600_000, allowFailure = false } = {}) {
  return new Promise((resolveResult, reject) => {
    const child = spawn(command, args, { env, cwd, shell: false, stdio: capture ? ['ignore', 'pipe', 'pipe'] : 'inherit', windowsHide: true });
    let stdout = ''; let stderr = '';
    child.stdout?.on('data', chunk => { stdout = (stdout + chunk).slice(-4 * 1024 * 1024); });
    child.stderr?.on('data', chunk => { stderr = (stderr + chunk).slice(-64 * 1024); });
    const timer = timeout > 0 ? setTimeout(() => { child.kill(); reject(new Error(`${basename(command)} timed out. No install completion is claimed; rerun when ready.`)); }, timeout) : undefined;
    child.on('error', error => { clearTimeout(timer); reject(error); });
    child.on('close', code => {
      clearTimeout(timer);
      if (code === 0 || allowFailure) resolveResult({ code, stdout, stderr });
      else reject(new Error(`${basename(command)} failed (exit ${code}). See the command output above; setup has not completed.`));
    });
  });
}

async function response(url) {
  for (let redirects = 0; redirects < 6; redirects++) {
    if (new URL(url).protocol !== 'https:') throw new Error('Downloads require HTTPS.');
    const result = await fetch(url, { headers: { 'User-Agent': 'mandalin-installer' }, redirect: 'manual', signal: AbortSignal.timeout(600_000) });
    if ([301, 302, 303, 307, 308].includes(result.status)) {
      const location = result.headers.get('location'); await result.body?.cancel();
      if (!location) throw new Error('Download redirect has no destination.');
      url = new URL(location, url).href; continue;
    }
    if (!result.ok) { await result.body?.cancel(); throw new Error(`Download failed: HTTP ${result.status} from ${new URL(url).hostname}. Check connectivity or API rate limits and rerun.`); }
    return result;
  }
  throw new Error('Too many download redirects.');
}

async function text(url) {
  const res = await response(url); let result = ''; let count = 0;
  for await (const chunk of res.body) { count += chunk.length; if (count > 8 * 1024 * 1024) throw new Error('Download metadata exceeded its safety limit.'); result += Buffer.from(chunk).toString('utf8'); }
  return result;
}

export async function download(url, file, expected, { fetchResponse = response } = {}) {
  if (!/^[a-f\d]{64}$/iu.test(expected)) throw new Error('Missing or invalid download checksum.');
  const res = await fetchResponse(url); const hash = createHash('sha256'); let bytes = 0; let last = Date.now();
  console.log(`Downloading ${basename(file)}...`);
  await pipeline(Readable.fromWeb(res.body), new Transform({ transform(chunk, _encoding, callback) {
    bytes += chunk.length;
    if (bytes > 512 * 1024 * 1024) { callback(new Error('Runtime archive exceeds 512 MiB.')); return; }
    hash.update(chunk);
    if (Date.now() - last > 5000) { console.log(`  ${Math.round(bytes / 1024 / 1024)} MiB downloaded`); last = Date.now(); }
    callback(null, chunk);
  } }), createWriteStream(file, { flags: 'wx', mode: 0o600 }));
  if (hash.digest('hex') !== expected.toLowerCase()) throw new Error('Archive checksum mismatch; refusing to extract or execute.');
}

async function extract(file, destination, env) {
  await mkdir(destination);
  if (file.endsWith('.zip') && process.platform === 'win32') {
    await run('powershell.exe', ['-NoProfile', '-Command', 'Expand-Archive -LiteralPath $env:MANDALIN_ARCHIVE -DestinationPath $env:MANDALIN_EXTRACT -ErrorAction Stop'], {
      env: { ...env, MANDALIN_ARCHIVE: file, MANDALIN_EXTRACT: destination },
    });
  } else if (file.endsWith('.zip')) await run('unzip', ['-q', file, '-d', destination], { env });
  else await run('tar', ['-xzf', file, '-C', destination], { env });
}

async function findFile(directory, suffix, depth = 5) {
  const direct = join(directory, ...suffix); if (await exists(direct)) return direct;
  if (depth <= 0) return null;
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    if (entry.isDirectory()) { const found = await findFile(join(directory, entry.name), suffix, depth - 1); if (found) return found; }
  }
  return null;
}

export async function verifyCheckout(root, { invoke = run, repository = REPOSITORY_URL } = {}) {
  if (!await exists(root)) return false;
  if (!await exists(join(root, '.git'))) throw new Error(`Install directory already exists and is not a Git checkout: ${root}. Nothing was overwritten.`);
  const origin = (await invoke('git', ['-C', root, 'remote', 'get-url', 'origin'], { capture: true })).stdout.trim();
  if (origin !== repository) throw new Error('Existing checkout belongs to another repository. Nothing was overwritten.');
  const dirty = (await invoke('git', ['-C', root, 'status', '--porcelain'], { capture: true })).stdout.trim();
  if (dirty) throw new Error('Existing checkout has local changes. Commit or move them yourself before rerunning; the installer will not discard them.');
  return true;
}

export async function configureUnixShell({ home, appHome, prefix = join(appHome, 'cli'), nodeBin, javaHome, ghBin, shell = process.env.SHELL ?? '', ask }) {
  const paths = [...new Set([join(prefix, 'bin'), nodeBin, join(javaHome, 'bin'), ...(ghBin ? [ghBin] : [])])];
  const envPath = join(appHome, 'env.sh');
  const envText = `# Generated by Mandalin setup. Remove its source line from your shell profile to undo.\nexport MANDALIN_HOME=${shellQuote(appHome)}\nexport JAVA_HOME=${shellQuote(javaHome)}\nexport PATH=${shellQuote(paths.join(':'))}:"$PATH"\n`;
  await writeFile(envPath, envText, { mode: 0o600 });
  const shellName = basename(shell);
  const profiles = shellName === 'zsh' ? ['.zshrc'] : shellName === 'bash' ? ['.bashrc', '.bash_profile'] : shellName === 'fish' ? ['.config/fish/config.fish'] : ['.profile'];
  let sourceLine = `. ${shellQuote(envPath)}`;
  if (shellName === 'fish') {
    const fishPath = join(appHome, 'env.fish');
    await writeFile(fishPath, `# Generated by Mandalin setup\nset -gx MANDALIN_HOME ${shellQuote(appHome)}\nset -gx JAVA_HOME ${shellQuote(javaHome)}\nfish_add_path ${paths.map(shellQuote).join(' ')}\n`, { mode: 0o600 });
    sourceLine = `source ${shellQuote(fishPath)}`;
  }
  if (await ask(`Add Mandalin's Node/Java/CLI paths to ${profiles.join(' and ')}? Existing settings will be preserved.`)) {
    for (const profile of profiles) {
      const file = join(home, profile); const before = await exists(file) ? await readFile(file, 'utf8') : '';
      if (before.split(/\r?\n/u).includes(sourceLine)) continue;
      await mkdir(dirname(file), { recursive: true });
      if (await exists(file)) await writeFile(`${file}.mandalin-backup-${Date.now()}`, before, { flag: 'wx', mode: 0o600 });
      await appendFile(file, `\n# Mandalin user-local tools\n${sourceLine}\n`, { mode: 0o600 });
    }
  }
  console.log(`For this terminal (or if you declined persistence), run: ${sourceLine}`);
}

async function main() {
  const spec = platformSpec();
  if (!process.stdin.isTTY && process.env.MANDALIN_BOOTSTRAP_INTERACTIVE !== '1') throw new Error('Use an interactive terminal for setup. Login and approvals cannot be answered through the download pipe.');
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  const ask = async message => {
    const answer = await rl.question(`${message} [y/N] `);
    rl.pause(); // Do not steal terminal input from gh login, sudo, or other children.
    return /^(y|yes)$/iu.test(answer.trim());
  };
  const home = homedir(); const appHome = resolve(process.env.MANDALIN_HOME ?? join(home, '.mandalin'));
  const root = join(appHome, 'app'); const runtimes = join(appHome, 'runtimes');
  const prefix = resolve(process.env.MANDALIN_PREFIX ?? join(appHome, 'cli'));
  const env = { ...process.env, MANDALIN_HOME: appHome, PATH: `${dirname(process.execPath)}${delimiter}${process.env.PATH ?? process.env.Path ?? ''}` };
  // Windows environment names are case-insensitive; avoid sending two PATH entries.
  if (spec.windows) for (const key of Object.keys(env)) if (key !== 'PATH' && key.toUpperCase() === 'PATH') delete env[key];
  const invoke = (command, args, options = {}) => run(command, args, { env, ...options });
  const capture = (command, args, options = {}) => invoke(command, args, { capture: true, allowFailure: true, ...options });
  const addPath = value => { env.PATH = `${value}${delimiter}${env.PATH}`; };
  try {
    console.log(`Mandalin guided setup (${spec.platform}/${spec.arch})\nApplication and optional runtimes: ${appHome}\nGitHub access and model-provider login are separate. No credentials are shipped.`);
    if (!await ask('Install Mandalin here? Runtime downloads are checksum-verified; optional research tools are not installed.')) return;
    await mkdir(runtimes, { recursive: true, mode: 0o700 });
    const foundGit = await executable('git', env);
    const appleStub = spec.platform === 'darwin' && foundGit === '/usr/bin/git' && (await capture('/usr/bin/xcode-select', ['-p'])).code !== 0;
    if (!foundGit || appleStub || (await capture('git', ['--version'])).code !== 0) {
      const managers = [];
      for (const manager of ['winget', 'apt-get', 'dnf', 'pacman', 'zypper']) if (await executable(manager, env)) managers.push(manager);
      const plan = gitInstallPlan(spec.platform, managers);
      if (!await ask(`Install ${plan.label}?`)) throw new Error('Git is required. Setup cancelled without cloning.');
      if (spec.platform === 'linux' && process.getuid?.() !== 0) await invoke('sudo', [plan.command, ...plan.args]);
      else await invoke(plan.command, plan.args, { allowFailure: Boolean(plan.wait) });
      if (plan.wait) { await rl.question('Finish Apple’s Command Line Tools installer, then press Enter: '); rl.pause(); }
      if (spec.windows) for (const candidate of [join(env.ProgramFiles ?? 'C:\\Program Files', 'Git', 'cmd'), join(env.LOCALAPPDATA ?? join(home, 'AppData', 'Local'), 'Programs', 'Git', 'cmd')]) if (await exists(candidate)) addPath(candidate);
      if ((await capture('git', ['--version'])).code !== 0) throw new Error('Git is not ready. Complete its installation and rerun setup.');
    }

    const remoteOptions = { env: { ...env, GIT_TERMINAL_PROMPT: '0', GCM_INTERACTIVE: 'never' }, capture: true, allowFailure: true, timeout: 30_000 };
    let ghBin;
    const refs = await repositoryRefs({
      readRefs: () => invoke('git', ['ls-remote', '--tags', '--refs', REPOSITORY_URL], { ...remoteOptions, env: { ...env, GIT_TERMINAL_PROMPT: '0', GCM_INTERACTIVE: 'never' } }),
      signIn: async () => {
      let gh = await executable('gh', env);
      if (!gh) {
        if (!await ask('Git cannot access the private repository. Download GitHub CLI locally to start browser/device login?')) throw new Error('GitHub authentication is required.');
        const release = JSON.parse(await text('https://api.github.com/repos/cli/cli/releases/latest'));
        const asset = release.assets.find(item => item.name.endsWith(`_${spec.ghOs}_${spec.ghArch}.${spec.ghExtension}`));
        const checksums = release.assets.find(item => item.name.endsWith('_checksums.txt'));
        if (!asset || !checksums) throw new Error('No GitHub CLI archive/checksum for this platform.');
        const work = await mkdtemp(join(runtimes, 'gh-'));
        const archive = join(work, basename(asset.name));
        await download(asset.browser_download_url, archive, checksumFor(await text(checksums.browser_download_url), asset.name));
        await extract(archive, join(work, 'extracted'), env);
        gh = await findFile(join(work, 'extracted'), ['bin', spec.windows ? 'gh.exe' : 'gh']);
        if (!gh) throw new Error('GitHub CLI executable missing from verified archive.');
      }
      ghBin = dirname(gh); addPath(ghBin);
      if (!await ask('Sign in if needed and configure Git’s GitHub credential helper for your user account?')) throw new Error('GitHub setup cancelled.');
      if ((await capture(gh, ['auth', 'status', '--hostname', 'github.com'])).code !== 0) {
        await invoke(gh, ['auth', 'login', '--hostname', 'github.com', '--git-protocol', 'https', '--web'], { timeout: 900_000 });
      }
      await invoke(gh, ['auth', 'setup-git', '--hostname', 'github.com']);
      },
    });
    let ref = stableTag(refs.stdout);
    if (!ref) {
      if (!await ask('No stable release tag exists yet. Install the main-branch team pilot instead?')) throw new Error('No stable release available; no application checkout created.');
      ref = 'main';
    }
    console.log(`Selected ${REPOSITORY} ${ref}. Stable discovery follows Git tags, not completed GitHub release uploads.`);

    let javaHome = env.JAVA_HOME;
    if (!javaHome && spec.platform === 'darwin') {
      const found = await capture('/usr/libexec/java_home', ['-v', '21']); if (found.code === 0) javaHome = found.stdout.trim();
    }
    if (!javaHome) {
      const java = await executable('java', env);
      if (java) javaHome = dirname(dirname(await realpath(java)));
    }
    const javaName = spec.windows ? 'java.exe' : 'java';
    const javaResult = javaHome && await exists(join(javaHome, 'bin', javaName)) ? await capture(join(javaHome, 'bin', javaName), ['-version']) : null;
    if (!javaResult || javaResult.code !== 0 || !/version\s+"21[."]/u.test(javaResult.stderr + javaResult.stdout)) {
      if (!await ask('Install Eclipse Temurin JDK 21 in Mandalin’s user folder to build the Burp extension? No system Java will be replaced.')) throw new Error('JDK 21 is required by this installer.');
      const releases = JSON.parse(await text(`https://api.adoptium.net/v3/assets/latest/21/hotspot?architecture=${spec.javaArch}&image_type=jdk&os=${spec.javaOs}`));
      const asset = releases[0]?.binary?.package;
      if (!asset?.name || !asset.link || !asset.checksum) throw new Error('No Temurin JDK archive for this platform.');
      const work = await mkdtemp(join(runtimes, 'jdk21-')); const archive = join(work, basename(asset.name));
      await download(asset.link, archive, asset.checksum);
      await extract(archive, join(work, 'extracted'), env);
      const java = await findFile(join(work, 'extracted'), ['bin', javaName]);
      if (!java) throw new Error('Java executable missing from verified archive.');
      javaHome = dirname(dirname(java));
    }
    env.JAVA_HOME = javaHome; addPath(join(javaHome, 'bin'));
    console.log('Preparing the application checkout...');
    if (await verifyCheckout(root, { invoke })) {
      await invoke('git', ['-C', root, 'fetch', 'origin', ref === 'main' ? 'refs/heads/main' : `refs/tags/${ref}`]);
      await invoke('git', ['-C', root, 'merge', '--ff-only', 'FETCH_HEAD']);
    } else await invoke('git', ['clone', '--branch', ref, '--single-branch', REPOSITORY_URL, root]);
    // The app installer runs npm ci/build/doctor and owns the CLI registration.
    await invoke(process.execPath, [join(root, 'installer', 'install.mjs')], { cwd: root, timeout: 1_800_000 });

    if (spec.windows) {
      const additions = [prefix, dirname(process.execPath), join(javaHome, 'bin'), ...(ghBin ? [ghBin] : [])];
      if (await ask('Add Mandalin, Node and Java to your user PATH and set user JAVA_HOME/MANDALIN_HOME? No machine-wide settings are changed.')) {
        const before = await invoke('powershell.exe', ['-NoProfile', '-Command', '$ErrorActionPreference = "Stop"; @{ Path = [Environment]::GetEnvironmentVariable("Path","User"); JAVA_HOME = [Environment]::GetEnvironmentVariable("JAVA_HOME","User"); MANDALIN_HOME = [Environment]::GetEnvironmentVariable("MANDALIN_HOME","User") } | ConvertTo-Json -Compress'], { capture: true });
        const snapshot = JSON.parse(before.stdout.trim());
        await writeFile(join(appHome, `windows-env-backup-${Date.now()}.json`), JSON.stringify(snapshot, null, 2), { mode: 0o600 });
        const path = mergeUserPath(snapshot.Path, additions);
        await invoke('powershell.exe', ['-NoProfile', '-Command', '[Environment]::SetEnvironmentVariable("Path",$env:MANDALIN_NEW_PATH,"User"); [Environment]::SetEnvironmentVariable("JAVA_HOME",$env:JAVA_HOME,"User"); [Environment]::SetEnvironmentVariable("MANDALIN_HOME",$env:MANDALIN_HOME,"User")'], { env: { ...env, MANDALIN_NEW_PATH: path } });
      }
      console.log('Open a new terminal for user PATH changes.');
    } else await configureUnixShell({ home, appHome, prefix, nodeBin: dirname(process.execPath), javaHome, ghBin, ask });
    console.log(`\nInstalled. Burp Suite is separate: load ${join(root, 'mandalin-burp.jar')} under Extensions > Installed > Add.\nOptional integrations/tools are installed later through guided setup, never silently here.`);
    if (await ask('Open Mandalin now to connect your model providers?')) {
      const target = join(appHome, 'welcome'); await mkdir(target, { recursive: true });
      const cli = join(root, 'dist', 'apps', 'mandalin', 'src', 'cli.js');
      const supportsSetup = (await capture(process.execPath, [cli, '--help'])).stdout.includes('mandalin setup');
      rl.close();
      console.log(`${supportsSetup ? 'Sign in through Connections' : 'Press c for Connections and sign in'}, then press Esc and n for a chat. Run mandalin from your own target folder for investigations.`);
      await invoke(process.execPath, [cli, ...(supportsSetup ? ['setup'] : [])], { cwd: target, timeout: 0 });
    }
  } finally { rl.close(); }
}

// ESM canonicalizes symlinked paths (e.g. macOS /var -> /private/var), but argv
// keeps the original spelling. Compare real paths so temporary-folder launches run.
if (process.argv[1] && await realpath(process.argv[1]).catch(() => null) === await realpath(fileURLToPath(import.meta.url))) {
  main().catch(error => { console.error(`\nSetup stopped: ${error.message}\nExisting research data and local checkout edits were not removed. Fix the issue and rerun the installer.`); process.exitCode = 1; });
}
