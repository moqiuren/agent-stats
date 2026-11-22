#!/usr/bin/env python3
"""Install Agent Stats into Applications; preserve runtime data and retire legacy login items."""
import argparse
import datetime
import errno
import json
import os
import pathlib
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
from Scripts.packaging_support import PRODUCTS, ROOT, APP_OUTPUT, APP_SOURCES, BUILD_INPUTS, plugin_manifest


def timestamp():
    return datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')


def default_applications_dir(home=None):
    user_home = pathlib.Path(home) if home is not None else pathlib.Path.home()
    real_home = pathlib.Path(os.path.expanduser('~'))
    try:
        same_home = user_home.resolve() == real_home.resolve()
    except OSError:
        same_home = str(user_home) == str(real_home)
    system_apps = pathlib.Path('/Applications')
    if same_home and os.access(system_apps, os.W_OK):
        return system_apps
    return user_home / 'Applications'


def _move_path(source, target):
    target.parent.mkdir(parents=True, exist_ok=True)
    try:
        source.rename(target)
    except OSError as exc:
        if exc.errno != errno.EXDEV:
            raise
        shutil.move(str(source), str(target))


def stale_build(source, product):
    # Reusing a bundle whose version still matches products.json would silently
    # install an old binary after a source edit, so compare the newest input.
    if not source.exists():
        return True
    try:
        built = source.stat().st_mtime
    except OSError:
        return True
    inputs = [ROOT / name for name in set(APP_SOURCES + BUILD_INPUTS)]
    inputs += [ROOT / 'products.json', ROOT / 'Scripts/packaging_support.py', ROOT / 'LICENSE', ROOT / 'LICENSE-DSH.txt']
    for path in inputs:
        try:
            if path.stat().st_mtime > built:
                return True
        except OSError:
            continue
    return False


def prune_registry_backups(support, keep=5, trash=None):
    # Each install writes a registry snapshot; without a bound they accumulate
    # forever in the support directory and are never read back. Retired snapshots
    # move to the Trash like every other backup cleanup in this project.
    backups = sorted(support.glob('installed-*.json.backup'))
    stale = backups[:max(0, len(backups) - keep)]
    if not stale:
        return
    folder = (pathlib.Path(trash) if trash else pathlib.Path.home() / '.Trash') / ('Agent-Stats-registry-backups-' + timestamp())
    folder.mkdir(parents=True, exist_ok=True)
    for backup in stale:
        _move_path(backup, folder / backup.name)


def stop_product(product, destination, domain):
    subprocess.run(['/bin/launchctl', 'bootout', f'{domain}/{product["bundle_id"]}'], capture_output=True)
    executable = destination / 'Contents/MacOS' / product['executable']
    subprocess.run(['/usr/bin/pkill', '-f', '^' + re.escape(str(executable)) + '$'], capture_output=True)
    if product.get('provider') == 'kimi':
        reader = destination / 'Contents/Resources/reader.mjs'
        subprocess.run(['/usr/bin/pkill', '-f', re.escape(str(reader)) + '( |$)'], capture_output=True)


def wait_for_unload(product, domain, timeout=5):
    # bootout may return while launchd still reports the old job as SIGTERMed.
    # Re-registering the same label in this interval fails with EIO (5).
    deadline = time.monotonic() + timeout
    while True:
        result = subprocess.run(['/bin/launchctl', 'print', f'{domain}/{product["bundle_id"]}'], capture_output=True)
        if result.returncode != 0:
            return
        if time.monotonic() >= deadline:
            raise RuntimeError('旧登录项尚未退出，未替换现有应用；请稍后重试。')
        time.sleep(0.05)


def wait_for_exit(destination, product, timeout=5):
    # pkill only asks the old process to stop. The replacement is installed at the
    # same executable path, so a process that is still dying would satisfy
    # wait_for_start and let legacy login items be retired for an app that never ran.
    executable = destination / 'Contents/MacOS' / product['executable']
    deadline = time.monotonic() + timeout
    while True:
        result = subprocess.run(['/usr/bin/pgrep', '-f', '^' + re.escape(str(executable)) + '$'], capture_output=True)
        if result.returncode != 0:
            return
        if time.monotonic() >= deadline:
            raise RuntimeError('旧进程尚未退出，未替换现有应用；请稍后重试。')
        time.sleep(0.1)


def wait_for_start(destination, product, timeout=10):
    executable = destination / 'Contents/MacOS' / product['executable']
    deadline = time.monotonic() + timeout
    while True:
        result = subprocess.run(['/usr/bin/pgrep', '-f', '^' + re.escape(str(executable)) + '$'], capture_output=True)
        if result.returncode == 0:
            return
        if time.monotonic() >= deadline:
            raise RuntimeError('Agent Stats 未成功启动；已保留旧应用和登录项。')
        time.sleep(0.2)


def migrate_runtime(home, support, product):
    marker = support / '.legacy-runtime-migration-v3.json'
    if marker.exists():
        return
    kimi = next(p for p in product['legacy_products'] if p['provider'] == 'kimi')
    legacy = home / 'Library/Application Support' / kimi['name']
    for name in ('kimi-bridge', 'hook-context.json'):
        source, destination = legacy / name, support / name
        if not source.exists() or destination.exists():
            continue
        with tempfile.TemporaryDirectory(prefix='.migration-', dir=support) as stage:
            incoming = pathlib.Path(stage) / name
            if source.is_dir():
                shutil.copytree(source, incoming)
            else:
                shutil.copy2(source, incoming)
            incoming.rename(destination)
    marker.write_text(json.dumps({'version': 3, 'source': str(legacy), 'completedAt': timestamp()}) + '\n')


def login_environment(home, product, old_launch):
    keys = ('CODEX_HOME', 'KIMI_CODE_HOME')
    env = {}
    for legacy in product['legacy_products']:
        launch = home / 'Library/LaunchAgents' / (legacy['bundle_id'] + '.plist')
        if launch.exists():
            previous = plistlib.loads(launch.read_bytes()).get('EnvironmentVariables', {})
            env.update({key: previous[key] for key in keys if key in previous})
    if old_launch:
        previous = plistlib.loads(old_launch).get('EnvironmentVariables', {})
        env.update({key: previous[key] for key in keys if key in previous})
    env.update({key: os.environ[key] for key in keys if key in os.environ})
    return env


def retire_legacy(home, product, domain):
    trash = home / '.Trash' / ('Agent-Stats-legacy-login-items-' + timestamp())
    retired = []
    for legacy in product['legacy_products']:
        support = home / 'Library/Application Support' / legacy['name']
        stop_product(legacy, support / (legacy['name'] + '.app'), domain)
        launch = home / 'Library/LaunchAgents' / (legacy['bundle_id'] + '.plist')
        if launch.exists():
            trash.mkdir(parents=True, exist_ok=True)
            _move_path(launch, trash / launch.name)
            retired.append(launch.name)
    return retired


def register_kimi(home, support, destination, data_root=None):
    plugins = pathlib.Path(data_root or os.environ.get('KIMI_CODE_HOME', str(home / '.kimi-code'))) / 'plugins'
    registry = plugins / 'installed.json'
    original = registry.read_bytes() if registry.exists() else None
    obj = json.loads(original) if original else {'version': 1, 'plugins': []}
    if obj.get('version') != 1 or not isinstance(obj.get('plugins'), list) or not all(isinstance(p, dict) for p in obj['plugins']):
        raise RuntimeError('插件注册表格式不兼容，未覆盖。')
    managed = plugins / 'managed/kimi-stats-hud'
    managed.mkdir(parents=True, exist_ok=True)
    manifest_path = managed / 'kimi.plugin.json'
    previous_manifest = manifest_path.read_bytes() if manifest_path.exists() else None
    now = datetime.datetime.now(datetime.timezone.utc).isoformat()
    prior = next((p for p in obj['plugins'] if p.get('id') == 'kimi-stats-hud'), {})
    record = {'id': 'kimi-stats-hud', 'root': str(managed), 'source': 'local-path',
              'enabled': prior.get('enabled', True), 'installedAt': prior.get('installedAt', now),
              'updatedAt': now, 'originalSource': str(ROOT)}
    obj['plugins'] = [p for p in obj['plugins'] if p.get('id') != 'kimi-stats-hud'] + [record]
    if original:
        (support / ('installed-' + timestamp() + '.json.backup')).write_bytes(original)
        prune_registry_backups(support)
    if (registry.read_bytes() if registry.exists() else None) != original:
        raise RuntimeError('插件列表刚被其他进程修改，请重试。')
    temporary = registry.with_suffix('.stats-tmp')
    try:
        plugin_manifest(manifest_path, destination)
        temporary.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + '\n')
        temporary.replace(registry)
    except Exception:
        if previous_manifest is not None:
            manifest_path.write_bytes(previous_manifest)
        elif manifest_path.exists():
            manifest_path.unlink()
        if temporary.exists():
            temporary.unlink()
        raise


def plugin_state(home, data_root=None):
    plugins = pathlib.Path(data_root or os.environ.get('KIMI_CODE_HOME', str(home / '.kimi-code'))) / 'plugins'
    registry = plugins / 'installed.json'
    manifest = plugins / 'managed/kimi-stats-hud/kimi.plugin.json'
    return registry, manifest, (registry.read_bytes() if registry.exists() else None), (manifest.read_bytes() if manifest.exists() else None)


def restore_plugin_state(registry, manifest, registry_bytes, manifest_bytes):
    # register_kimi rewrites the host registry and the managed manifest. If a later
    # step fails, the app bundle is rolled back, so the host must not keep a record
    # that points at the retired app.
    for path, original in ((registry, registry_bytes), (manifest, manifest_bytes)):
        if original is None:
            if path.exists():
                path.unlink()
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(original)


def record_installation(support, home, env, destination=None):
    state = support / 'installation.json'
    temporary_state = support / '.installation.json.incoming'
    payload = {
        'version': 1,
        'kimiDataRoot': env.get('KIMI_CODE_HOME', str(home / '.kimi-code')),
    }
    if destination is not None:
        payload['appPath'] = str(destination)
    temporary_state.write_text(json.dumps(payload) + '\n')
    temporary_state.chmod(0o600)
    temporary_state.replace(state)


def configure_kimi_bridge(action, renderer, support):
    if action == 'keep':
        return
    from Scripts.bridge_manager import install as install_bridge, uninstall as remove_bridge
    if action == 'install':
        if not (renderer / 'index.html').exists():
            raise RuntimeError('没有找到 Kimi 页面，未安装兼容桥接。')
        install_bridge(renderer, support, ROOT / 'Scripts/kimi-bridge-client.js')
    elif action == 'remove':
        remove_bridge(support)
        folder = support / 'kimi-bridge'
        if folder.exists():
            trash = pathlib.Path.home() / '.Trash' / ('Kimi-bridge-retired-' + timestamp())
            trash.parent.mkdir(parents=True, exist_ok=True)
            _move_path(folder, trash)


def install(provider='agent', kimi_bridge='keep', applications_dir=None):
    product = PRODUCTS[provider]
    source = APP_OUTPUT / (product['name'] + '.app')
    if stale_build(source, provider):
        subprocess.run([sys.executable, str(ROOT / 'build.py'), '--app', provider, '--auto-cert'], check=True)
    info = plistlib.loads((source / 'Contents/Info.plist').read_bytes())
    expected = [('CFBundleIdentifier', 'bundle_id'), ('CFBundleName', 'name'), ('CFBundleExecutable', 'executable'),
                ('CFBundleShortVersionString', 'version'), ('CFBundleVersion', 'build'), ('StatsProviders', 'providers'),
                ('StatsLegacyProducts', 'legacy_products')]
    if any(info.get(key) != product[value] for key, value in expected):
        raise RuntimeError(f'{product["name"]} 产物与 products.json 不一致，请先重新构建。')
    home = pathlib.Path.home()
    support = home / 'Library/Application Support' / product['name']
    support.mkdir(parents=True, exist_ok=True)
    apps_dir = pathlib.Path(applications_dir) if applications_dir is not None else default_applications_dir(home)
    apps_dir.mkdir(parents=True, exist_ok=True)
    domain = f'gui/{os.getuid()}'
    destination = apps_dir / source.name
    legacy_destination = support / source.name
    stage_parent = apps_dir if os.access(apps_dir, os.W_OK) else support
    stage = pathlib.Path(tempfile.mkdtemp(prefix='.install-', dir=stage_parent))
    incoming = stage / source.name
    def copy_clean(src, dst):
        shutil.copyfile(src, dst)
        shutil.copymode(src, dst)
        return dst
    try:
        shutil.copytree(source, incoming, copy_function=copy_clean)
        subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(incoming)], check=True)
        migrate_runtime(home, support, product)
        renderer = pathlib.Path('/Applications/Kimi Code.app/Contents/Resources/desktop-dist')
        if kimi_bridge == 'install':
            configure_kimi_bridge('install', renderer, support)
        stop_product(product, destination, domain)
        if legacy_destination != destination:
            stop_product(product, legacy_destination, domain)
        wait_for_unload(product, domain)
        wait_for_exit(destination, product)
        if legacy_destination != destination:
            wait_for_exit(legacy_destination, product)
        backup = None
        if destination.exists():
            backup = support / ('previous-' + timestamp() + '.app')
            _move_path(destination, backup)
        launch = home / 'Library/LaunchAgents' / (product['bundle_id'] + '.plist')
        old_launch = launch.read_bytes() if launch.exists() else None
        plugin_snapshot = None
        try:
            _move_path(incoming, destination)
            subprocess.run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister', '-f', str(destination)], check=True)
            launch.parent.mkdir(parents=True, exist_ok=True)
            settings = {'Label': product['bundle_id'], 'ProgramArguments': [str(destination / 'Contents/MacOS' / product['executable'])],
                        'RunAtLoad': True, 'ProcessType': 'Interactive', 'LimitLoadToSessionType': 'Aqua',
                        'StandardOutPath': str(support / 'stdout.log'), 'StandardErrorPath': str(support / 'stderr.log')}
            env = login_environment(home, product, old_launch)
            if env:
                settings['EnvironmentVariables'] = env
            launch.write_bytes(plistlib.dumps(settings))
            subprocess.run(['/bin/launchctl', 'bootstrap', domain, str(launch)], check=True)
            wait_for_start(destination, product)
            plugin_snapshot = plugin_state(home, env.get('KIMI_CODE_HOME'))
            register_kimi(home, support, destination, env.get('KIMI_CODE_HOME'))
            record_installation(support, home, env, destination)
        except Exception:
            # Rollback must keep restoring after one step fails: a stuck unload
            # check may not strand the previous app in the backup slot.
            rollback_errors = []

            def attempt(step):
                try:
                    step()
                except Exception as exc:  # noqa: BLE001 - restore the rest anyway
                    rollback_errors.append(exc)

            attempt(lambda: stop_product(product, destination, domain))
            attempt(lambda: wait_for_unload(product, domain))

            def retire_broken():
                trash = home / '.Trash' / ('Agent-Stats-failed-install-' + timestamp())
                trash.mkdir(parents=True, exist_ok=True)
                _move_path(destination, trash / destination.name)

            if destination.exists():
                attempt(retire_broken)
            if backup:
                attempt(lambda: _move_path(backup, destination))

            def restore_launch():
                launch.write_bytes(old_launch)
                subprocess.run(['/bin/launchctl', 'bootstrap', domain, str(launch)], capture_output=True)

            if old_launch:
                attempt(restore_launch)
            elif launch.exists():
                attempt(launch.unlink)
            if plugin_snapshot is not None:
                attempt(lambda: restore_plugin_state(*plugin_snapshot))
            attempt(lambda: (support / '.installation.json.incoming').unlink(missing_ok=True))
            for problem in rollback_errors:
                print('回滚步骤失败（已继续恢复）：', problem, file=sys.stderr)
            raise
        # Removing the compatibility bridge is destructive; it happens only after
        # the replacement is confirmed running and fully registered.
        if kimi_bridge == 'remove':
            configure_kimi_bridge('remove', renderer, support)
        retired = retire_legacy(home, product, domain)
        if legacy_destination != destination and legacy_destination.exists():
            trash = home / '.Trash' / ('Agent-Stats-legacy-app-' + timestamp())
            trash.mkdir(parents=True, exist_ok=True)
            _move_path(legacy_destination, trash / legacy_destination.name)
        if backup:
            trash = home / '.Trash' / ('Agent-Stats-previous-' + timestamp())
            trash.mkdir(parents=True, exist_ok=True)
            _move_path(backup, trash / destination.name)
        print('已安装并启动：', destination)
        print('统一登录项：', launch)
        if retired:
            print('旧登录项已停用并移至废纸篓；旧 App、偏好与会话数据保留。')
    finally:
        shutil.rmtree(stage, ignore_errors=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', choices=['agent'], default='agent')
    parser.add_argument('--kimi-bridge', choices=['keep', 'install', 'remove'], default='keep', help='默认保留现状，不改宿主页面。')
    parser.add_argument('--applications-dir', type=pathlib.Path, default=None, help='覆盖安装目标应用程序目录（默认 /Applications）。')
    args = parser.parse_args()
    install(args.app, kimi_bridge=args.kimi_bridge, applications_dir=args.applications_dir)
