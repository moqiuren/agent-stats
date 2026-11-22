import json
import os
import pathlib
import plistlib
import re
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))
import install
import build
import uninstall
from Scripts import icon_support, package_dmg, signing_support
from Scripts.packaging_support import PRODUCTS, plugin_manifest

PRODUCT = PRODUCTS['agent']


class DeploymentTests(unittest.TestCase):
    def test_swiftpm_production_graph_and_core_boundary(self):
        from Scripts.packaging_support import ROOT
        result = subprocess.run(['swift', 'package', '--scratch-path', str(ROOT / '.build/swiftpm'), 'describe', '--type', 'json'], cwd=ROOT,
                                check=True, capture_output=True, text=True)
        targets = {target['name']: target for target in json.loads(result.stdout)['targets']}
        production = {name: target for name, target in targets.items() if target['type'] != 'test'}
        # CZstd is the vendored decoder, a support target outside the production
        # Swift graph; everything else stays exactly the three production modules.
        self.assertEqual(set(production), {'StatsCore', 'StatsAdapters', 'AgentStatsApp', 'CZstd'})
        self.assertEqual(production['StatsCore'].get('target_dependencies', []), [])
        self.assertEqual(set(production['StatsAdapters']['target_dependencies']), {'StatsCore', 'CZstd'})
        self.assertEqual(set(production['AgentStatsApp']['target_dependencies']), {'StatsCore', 'StatsAdapters'})
        self.assertEqual(production['CZstd'].get('target_dependencies', []), [], 'the decoder depends on nothing')
        self.assertNotIn('swift', {source.rsplit('.', 1)[-1] for source in production['CZstd']['sources']},
                         'the decoder stays plain C so no Swift module depends on its API')
        for path in (ROOT / 'Sources/StatsCore').glob('*.swift'):
            self.assertNotRegex(path.read_text(), r'(?m)^import (StatsAdapters|AgentStatsApp|AppKit|SQLite3|Network|ApplicationServices)\b')
            self.assertNotRegex(path.read_text(), r'\b(FileManager|UserDefaults|DispatchQueue|Timer)\b')

    def test_install_freshness_tracks_manifest_and_source_removal(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            directory = root / 'Sources/StatsCore'; directory.mkdir(parents=True)
            source = root / 'Agent Stats.app'; source.mkdir()
            code = directory / 'Model.swift'; code.write_text('// model')
            manifest = root / 'Package.swift'; manifest.write_text('// package')
            for path in (code, manifest, directory): os.utime(path, (900000, 900000))
            os.utime(source, (1000000, 1000000))
            with mock.patch.object(install, 'ROOT', root), \
                 mock.patch.object(install, 'APP_SOURCES', ['Sources/StatsCore/Model.swift']), \
                 mock.patch.object(install, 'BUILD_INPUTS', ['Package.swift', 'Sources/StatsCore']):
                self.assertFalse(install.stale_build(source, 'agent'))
                os.utime(manifest, (1100000, 1100000))
                self.assertTrue(install.stale_build(source, 'agent'))
                os.utime(manifest, (900000, 900000)); code.unlink()
                self.assertTrue(install.stale_build(source, 'agent'), 'removing a discovered source invalidates the bundle')

    def test_signing_requires_a_stable_available_identity(self):
        first, second = 'A' * 40, 'B' * 40
        one = f'  1) {first} "Apple Development: Test"\n 1 valid identities found\n'
        self.assertEqual(build.choose_signing_identity(one), first)
        self.assertEqual(build.choose_signing_identity(one, 'Apple Development: Test'), first)
        for requested in [None, '-', second]:
            with self.assertRaises(RuntimeError):
                build.choose_signing_identity('0 valid identities found', requested)
        two = one + f'  2) {second} "Developer ID Application: Test"\n'
        with self.assertRaises(RuntimeError):
            build.choose_signing_identity(two)
        self.assertEqual(build.choose_signing_identity(two, first), first)
        with self.assertRaises(RuntimeError):
            build.choose_signing_identity(one, second)

    def test_one_native_app_contains_all_providers_and_stable_signature(self):
        self.assertEqual(list(PRODUCTS), ['agent'])
        self.assertEqual(set(PRODUCT['providers']), {'codex', 'kimi'})
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            apps = root / 'apps'
            (root / 'LICENSE').write_text('project license')
            (root / 'LICENSE-DSH.txt').write_text('license')
            czstd = root / 'Sources' / 'CZstd'
            czstd.mkdir(parents=True)
            (czstd / 'LICENSE-ZSTD.txt').write_text('bsd decoder license')
            binary_dir = root / 'swiftpm-release'
            binary_dir.mkdir()
            (binary_dir / 'AgentStats').write_bytes(b'native')
            with mock.patch.object(build, 'ROOT', root), mock.patch.object(build, 'APP_OUTPUT', apps), \
                 mock.patch.object(build, 'build_product', return_value=binary_dir) as compile_package, \
                 mock.patch.object(build.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)) as calls:
                build.build('agent', 'A' * 40)
            compile_package.assert_called_once_with('AgentStats', configuration='release', root=root)
            self.assertEqual([p.name for p in apps.iterdir()], [PRODUCT['name'] + '.app'])
            app = apps / (PRODUCT['name'] + '.app')
            info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
            self.assertEqual(info['CFBundleExecutable'], 'AgentStats')
            self.assertEqual(info['CFBundleIconFile'], 'AppIcon')
            self.assertEqual(info['StatsProviders'], PRODUCT['providers'])
            self.assertEqual(info['StatsLegacyProducts'], PRODUCT['legacy_products'])
            self.assertEqual([p.name for p in (app / 'Contents/MacOS').iterdir()], ['AgentStats'])
            self.assertTrue((app / 'Contents/Resources/AppIcon.icns').read_bytes().startswith(b'icns'))
            self.assertEqual((app / 'Contents/Resources/LICENSE').read_text(), 'project license')
            self.assertEqual((app / 'Contents/Resources/LICENSE-DSH.txt').read_text(), 'license')
            self.assertEqual((app / 'Contents/Resources/LICENSE-ZSTD.txt').read_text(), 'bsd decoder license')
            commands = [call.args[0] for call in calls.call_args_list]
            self.assertEqual(commands[0][commands[0].index('--sign') + 1], 'A' * 40)
            self.assertEqual((app / 'Contents/MacOS/AgentStats').read_bytes(), b'native')

    def test_ordinary_updates_never_patch_the_host(self):
        with mock.patch('Scripts.bridge_manager.install') as add, mock.patch('Scripts.bridge_manager.uninstall') as remove:
            install.configure_kimi_bridge('keep', pathlib.Path('/not-a-host'), pathlib.Path('/not-support'))
        add.assert_not_called()
        remove.assert_not_called()

    def test_bridge_migration_preserves_original_and_is_not_repeated_after_removal(self):
        with tempfile.TemporaryDirectory() as folder:
            home = pathlib.Path(folder)
            legacy = home / 'Library/Application Support/Kimi Stats'
            old_bridge = legacy / 'kimi-bridge'
            old_bridge.mkdir(parents=True)
            payload = {'port': 12345, 'key': 'local-secret'}
            (old_bridge / 'connection.json').write_text(json.dumps(payload))
            (old_bridge / 'original-index.html').write_text('unchanged original')
            (legacy / 'hook-context.json').write_text('{"sessionId":"session-old"}')
            support = home / 'Library/Application Support/Agent Stats'
            support.mkdir()
            install.migrate_runtime(home, support, PRODUCT)
            self.assertEqual((old_bridge / 'connection.json').read_bytes(), (support / 'kimi-bridge/connection.json').read_bytes())
            self.assertEqual((support / 'kimi-bridge/original-index.html').read_text(), 'unchanged original')
            self.assertTrue((old_bridge / 'original-index.html').exists())
            # A later explicit bridge removal must not be undone by an update.
            (support / 'kimi-bridge').rename(support / 'removed-bridge')
            install.migrate_runtime(home, support, PRODUCT)
            self.assertFalse((support / 'kimi-bridge').exists())

    def test_migration_preserves_existing_unified_runtime(self):
        with tempfile.TemporaryDirectory() as folder:
            home = pathlib.Path(folder)
            legacy = home / 'Library/Application Support/Kimi Stats/kimi-bridge'
            legacy.mkdir(parents=True)
            (legacy / 'connection.json').write_text('old')
            support = home / 'Library/Application Support/Agent Stats'
            (support / 'kimi-bridge').mkdir(parents=True)
            (support / 'kimi-bridge/connection.json').write_text('current')
            install.migrate_runtime(home, support, PRODUCT)
            self.assertEqual((support / 'kimi-bridge/connection.json').read_text(), 'current')

    def test_plugin_launches_unified_app_without_machine_path(self):
        with tempfile.TemporaryDirectory() as folder:
            path = pathlib.Path(folder) / 'kimi.plugin.json'
            manifest = plugin_manifest(path)
            self.assertEqual(manifest['version'], PRODUCT['version'])
            command = manifest['hooks'][0]['command']
            self.assertIn('--record-session', command)
            self.assertIn('$HOME', command)
            self.assertIn('/AgentStats', command)
            self.assertNotIn('/Users/', command)
            self.assertEqual(manifest['name'], 'kimi-stats-hud')
            events = [hook['event'] for hook in manifest['hooks']]
            self.assertEqual(events[0], 'SessionStart')
            self.assertEqual(len(events), len(set(events)), 'no lifecycle event is registered twice')
            self.assertEqual(events, ['SessionStart', 'Stop', 'StopFailure', 'SessionEnd', 'SubagentStart', 'SubagentStop', 'PreCompact', 'PostCompact'])
            for hook in manifest['hooks'][1:]:
                self.assertIn('--record-session', hook['command'])
                self.assertNotIn('/Users/', hook['command'])
                self.assertNotIn('open -g', hook['command'], 'a per-turn report must not launch the app again')
                self.assertLessEqual(hook['timeout'], 5)

    def test_kimi_upgrade_preserves_disabled_plugin_and_other_entries(self):
        with tempfile.TemporaryDirectory() as folder:
            home = pathlib.Path(folder)
            plugins = home / '.kimi-code/plugins'
            plugins.mkdir(parents=True)
            registry = plugins / 'installed.json'
            registry.write_text(json.dumps({'version': 1, 'plugins': [
                {'id': 'other', 'enabled': True},
                {'id': 'kimi-stats-hud', 'enabled': False, 'installedAt': 'prior'}]}))
            support = home / 'support'
            support.mkdir()
            with mock.patch.dict('os.environ', {}, clear=True):
                install.register_kimi(home, support, home / 'Agent Stats.app')
            entries = json.loads(registry.read_text())['plugins']
            self.assertEqual(entries[0], {'id': 'other', 'enabled': True})
            self.assertFalse(entries[1]['enabled'])
            self.assertEqual(entries[1]['installedAt'], 'prior')
            manifest = json.loads((plugins / 'managed/kimi-stats-hud/kimi.plugin.json').read_text())
            self.assertIn('AgentStats', manifest['hooks'][0]['command'])

    def test_incompatible_registry_does_not_rewrite_plugin(self):
        with tempfile.TemporaryDirectory() as folder:
            home = pathlib.Path(folder)
            plugins = home / '.kimi-code/plugins'
            managed = plugins / 'managed/kimi-stats-hud'
            managed.mkdir(parents=True)
            manifest = managed / 'kimi.plugin.json'
            manifest.write_text('old')
            (plugins / 'installed.json').write_text('{"version":2,"plugins":[]}')
            with mock.patch.dict('os.environ', {}, clear=True), self.assertRaises(RuntimeError):
                install.register_kimi(home, home, home / 'Agent Stats.app')
            self.assertEqual(manifest.read_text(), 'old')

    def fixture(self, home):
        apps = home / 'build'
        source = apps / 'Agent Stats.app'
        (source / 'Contents/MacOS').mkdir(parents=True)
        (source / 'Contents/MacOS/AgentStats').write_bytes(b'new')
        info = {key: PRODUCT[value] for key, value in [
            ('CFBundleIdentifier', 'bundle_id'), ('CFBundleName', 'name'), ('CFBundleExecutable', 'executable'),
            ('CFBundleShortVersionString', 'version'), ('CFBundleVersion', 'build'),
            ('StatsProviders', 'providers'), ('StatsLegacyProducts', 'legacy_products')]}
        (source / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        launch_dir = home / 'Library/LaunchAgents'
        launch_dir.mkdir(parents=True)
        for legacy in PRODUCT['legacy_products']:
            launch = launch_dir / (legacy['bundle_id'] + '.plist')
            key = 'CODEX_HOME' if legacy['executable'] == 'CodexStats' else 'KIMI_CODE_HOME'
            launch.write_bytes(plistlib.dumps({'EnvironmentVariables': {key: str(home / legacy['executable'])}}))
            app = home / 'Library/Application Support' / legacy['name'] / (legacy['name'] + '.app')
            app.mkdir(parents=True)
        return apps, launch_dir

    def install_process(self, bootstrapped):
        # A real install sees no matching process until the replacement is
        # bootstrapped; the mock must not let a dying process satisfy the start check.
        def run(command, **kwargs):
            if command[:2] == ['/bin/launchctl', 'print']:
                return subprocess.CompletedProcess(command, 113, b'', b'not found')
            if command[0] == '/usr/bin/pgrep':
                return subprocess.CompletedProcess(command, 0, b'123\n', b'') if bootstrapped[0] else subprocess.CompletedProcess(command, 113, b'', b'')
            if command[:2] == ['/bin/launchctl', 'bootstrap']:
                bootstrapped[0] = True
            return subprocess.CompletedProcess(command, 0, b'', b'')
        return run

    def test_install_starts_unified_before_retiring_legacy_and_preserves_apps(self):
        with tempfile.TemporaryDirectory() as folder:
            home = pathlib.Path(folder)
            apps, launch_dir = self.fixture(home)
            with mock.patch.object(pathlib.Path, 'home', return_value=home), mock.patch.object(install, 'APP_OUTPUT', apps), mock.patch.dict('os.environ', {}, clear=True), mock.patch.object(install.subprocess, 'run', side_effect=self.install_process([False])) as calls:
                install.install()
            settings = plistlib.loads((launch_dir / 'local.agent.stats.plist').read_bytes())
            self.assertEqual(settings['Label'], 'local.agent.stats')
            self.assertEqual(settings['EnvironmentVariables']['CODEX_HOME'], str(home / 'CodexStats'))
            self.assertEqual(settings['EnvironmentVariables']['KIMI_CODE_HOME'], str(home / 'KimiStats'))
            self.assertTrue((home / 'KimiStats/plugins/installed.json').exists())
            commands = [call.args[0] for call in calls.call_args_list]
            started = next(i for i, cmd in enumerate(commands) if cmd[0] == '/usr/bin/pgrep')
            for legacy in PRODUCT['legacy_products']:
                stopped = next(i for i, cmd in enumerate(commands) if cmd[:2] == ['/bin/launchctl', 'bootout'] and cmd[-1].endswith('/' + legacy['bundle_id']))
                self.assertLess(started, stopped)
                self.assertFalse((launch_dir / (legacy['bundle_id'] + '.plist')).exists())
                self.assertTrue((home / 'Library/Application Support' / legacy['name'] / (legacy['name'] + '.app')).exists())
            self.assertEqual(len(list(launch_dir.iterdir())), 1)
            self.assertEqual(len(list((home / '.Trash').glob('*/*.plist'))), 2)
            installed_app = home / 'Applications/Agent Stats.app'
            self.assertTrue((installed_app / 'Contents/MacOS/AgentStats').exists())
            self.assertEqual(settings['ProgramArguments'], [str(installed_app / 'Contents/MacOS/AgentStats')])
            self.assertFalse(any(cmd[0].startswith('/Applications/') or '/Applications/' == cmd[-1][:14] for cmd in commands))

    def test_failed_start_restores_prior_unified_app_and_keeps_legacy_login_items(self):
        with tempfile.TemporaryDirectory() as folder:
            home = pathlib.Path(folder)
            apps, launch_dir = self.fixture(home)
            installed = home / 'Applications/Agent Stats.app'
            installed.mkdir(parents=True)
            (installed / 'prior').write_text('old app')
            launch = launch_dir / 'local.agent.stats.plist'
            previous = plistlib.dumps({'Label': 'local.agent.stats', 'EnvironmentVariables': {'CODEX_HOME': '/custom/codex'}})
            launch.write_bytes(previous)
            with mock.patch.object(pathlib.Path, 'home', return_value=home), mock.patch.object(install, 'APP_OUTPUT', apps), mock.patch.dict('os.environ', {}, clear=True), mock.patch.object(install.subprocess, 'run', return_value=subprocess.CompletedProcess([], 113)) as calls, mock.patch.object(install, 'wait_for_start', side_effect=RuntimeError('start failed')), self.assertRaises(RuntimeError):
                install.install()
            self.assertEqual((installed / 'prior').read_text(), 'old app')
            self.assertEqual(launch.read_bytes(), previous)
            commands = [call.args[0] for call in calls.call_args_list]
            for legacy in PRODUCT['legacy_products']:
                self.assertTrue((launch_dir / (legacy['bundle_id'] + '.plist')).exists())
                self.assertFalse(any(cmd[-1].endswith('/' + legacy['bundle_id']) for cmd in commands))
            self.assertFalse((home / 'KimiStats/plugins/installed.json').exists())

    def test_restart_waits_for_sigtermed_job_to_disappear(self):
        responses = [subprocess.CompletedProcess([], 0, b'state = SIGTERMed'),
                     subprocess.CompletedProcess([], 0, b'state = SIGTERMed'),
                     subprocess.CompletedProcess([], 113, b'')]
        with mock.patch.object(install.subprocess, 'run', side_effect=responses) as calls, mock.patch.object(install.time, 'sleep') as sleep:
            install.wait_for_unload(PRODUCT, 'gui/test')
        self.assertEqual(calls.call_count, 3)
        self.assertEqual(sleep.call_count, 2)
        self.assertTrue(all(call.args[0] == ['/bin/launchctl', 'print', 'gui/test/' + PRODUCT['bundle_id']] for call in calls.call_args_list))

    def test_restart_stops_if_the_old_job_does_not_exit(self):
        with mock.patch.object(install.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)), self.assertRaisesRegex(RuntimeError, '尚未退出'):
            install.wait_for_unload(PRODUCT, 'gui/test', timeout=0)

    def test_replacement_waits_until_the_old_process_is_gone(self):
        responses = [subprocess.CompletedProcess([], 0, b'123'),
                     subprocess.CompletedProcess([], 0, b'123'),
                     subprocess.CompletedProcess([], 113, b'')]
        with mock.patch.object(install.subprocess, 'run', side_effect=responses) as calls, mock.patch.object(install.time, 'sleep') as sleep:
            install.wait_for_exit(pathlib.Path('/installed/Agent Stats.app'), PRODUCT)
        self.assertEqual(calls.call_count, 3)
        self.assertEqual(sleep.call_count, 2)
        pattern = calls.call_args_list[0].args[0][2]
        executable = '/installed/Agent Stats.app/Contents/MacOS/AgentStats'
        self.assertIsNotNone(re.fullmatch(pattern, executable))
        self.assertIsNone(re.fullmatch(pattern, executable + ' Helper'))

    def test_replacement_stops_when_the_old_process_lingers(self):
        with mock.patch.object(install.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)), self.assertRaisesRegex(RuntimeError, '旧进程尚未退出'):
            install.wait_for_exit(pathlib.Path('/installed/Agent Stats.app'), PRODUCT, timeout=0)

    def test_install_refuses_to_replace_an_app_whose_process_never_exits(self):
        with tempfile.TemporaryDirectory() as folder:
            home = pathlib.Path(folder)
            apps, launch_dir = self.fixture(home)
            installed = home / 'Applications/Agent Stats.app'
            installed.mkdir(parents=True)
            (installed / 'prior').write_text('old app')
            real = install.wait_for_exit
            def run(command, **kwargs):
                if command[0] == '/usr/bin/pgrep':
                    return subprocess.CompletedProcess(command, 0, b'123\n', b'')
                return subprocess.CompletedProcess(command, 113, b'')
            with mock.patch.object(pathlib.Path, 'home', return_value=home), mock.patch.object(install, 'APP_OUTPUT', apps), mock.patch.dict('os.environ', {}, clear=True), mock.patch.object(install.subprocess, 'run', side_effect=run) as calls, mock.patch.object(install, 'wait_for_exit', side_effect=lambda destination, product, timeout=5: real(destination, product, timeout=0)), self.assertRaisesRegex(RuntimeError, '旧进程尚未退出'):
                install.install()
            # A dying process may not stand in for a started replacement, and legacy
            # login items stay active until the new app is confirmed running.
            self.assertEqual((installed / 'prior').read_text(), 'old app')
            commands = [call.args[0] for call in calls.call_args_list]
            for legacy in PRODUCT['legacy_products']:
                self.assertTrue((launch_dir / (legacy['bundle_id'] + '.plist')).exists())
                self.assertFalse(any(cmd[-1].endswith('/' + legacy['bundle_id']) for cmd in commands))
            self.assertFalse((launch_dir / 'local.agent.stats.plist').exists())

    def test_failed_install_removes_the_plugin_registration_it_added(self):
        with tempfile.TemporaryDirectory() as folder:
            home = pathlib.Path(folder)
            apps, _ = self.fixture(home)
            plugins = home / 'KimiStats/plugins'
            plugins.mkdir(parents=True)
            registry = plugins / 'installed.json'
            registry.write_text(json.dumps({'version': 1, 'plugins': [{'id': 'other', 'enabled': True}]}))
            manifest = plugins / 'managed/kimi-stats-hud/kimi.plugin.json'
            with mock.patch.object(pathlib.Path, 'home', return_value=home), mock.patch.object(install, 'APP_OUTPUT', apps), mock.patch.dict('os.environ', {}, clear=True), mock.patch.object(install.subprocess, 'run', side_effect=self.install_process([False])), mock.patch.object(install, 'record_installation', side_effect=RuntimeError('state write failed')), self.assertRaises(RuntimeError):
                install.install()
            # The host must not keep pointing at the app the rollback just retired.
            self.assertEqual(json.loads(registry.read_text())['plugins'], [{'id': 'other', 'enabled': True}])
            self.assertFalse(manifest.exists())
            self.assertFalse((home / 'Applications/Agent Stats.app').exists())

    def test_failed_upgrade_restores_the_previous_plugin_record_and_manifest(self):
        with tempfile.TemporaryDirectory() as folder:
            home = pathlib.Path(folder)
            apps, _ = self.fixture(home)
            plugins = home / 'KimiStats/plugins'
            managed = plugins / 'managed/kimi-stats-hud'
            managed.mkdir(parents=True)
            registry = plugins / 'installed.json'
            previous = {'version': 1, 'plugins': [{'id': 'kimi-stats-hud', 'enabled': False, 'installedAt': 'prior'}]}
            registry.write_text(json.dumps(previous))
            manifest = managed / 'kimi.plugin.json'
            manifest.write_text('previous manifest')
            with mock.patch.object(pathlib.Path, 'home', return_value=home), mock.patch.object(install, 'APP_OUTPUT', apps), mock.patch.dict('os.environ', {}, clear=True), mock.patch.object(install.subprocess, 'run', side_effect=self.install_process([False])), mock.patch.object(install, 'record_installation', side_effect=RuntimeError('state write failed')), self.assertRaises(RuntimeError):
                install.install()
            self.assertEqual(json.loads(registry.read_text()), previous)
            self.assertEqual(manifest.read_text(), 'previous manifest')

    def test_bridge_removal_waits_until_the_replacement_is_running(self):
        with tempfile.TemporaryDirectory() as folder:
            home = pathlib.Path(folder)
            apps, _ = self.fixture(home)
            bridge = home / 'Library/Application Support/Agent Stats/kimi-bridge'
            bridge.mkdir(parents=True)
            (bridge / 'original-index.html').write_text('backup')
            installed = home / 'Applications/Agent Stats.app'
            state = {}

            def remove(support):
                state['app_was_running'] = installed.exists()

            with mock.patch.object(pathlib.Path, 'home', return_value=home), mock.patch.object(install, 'APP_OUTPUT', apps), mock.patch.dict('os.environ', {}, clear=True), mock.patch.object(install.subprocess, 'run', side_effect=self.install_process([False])), mock.patch('Scripts.bridge_manager.uninstall', side_effect=remove):
                install.install(kimi_bridge='remove')
            self.assertTrue(state['app_was_running'], 'the bridge survives until the new app is confirmed running')
            self.assertFalse(bridge.exists())
            self.assertTrue(list((home / '.Trash').glob('Kimi-bridge-retired-*/original-index.html')),
                            'the retired bridge backup moves to the Trash')

    def test_failed_install_never_removes_the_compatibility_bridge(self):
        with tempfile.TemporaryDirectory() as folder:
            home = pathlib.Path(folder)
            apps, _ = self.fixture(home)
            bridge = home / 'Library/Application Support/Agent Stats/kimi-bridge'
            bridge.mkdir(parents=True)
            (bridge / 'original-index.html').write_text('backup')
            with mock.patch.object(pathlib.Path, 'home', return_value=home), mock.patch.object(install, 'APP_OUTPUT', apps), mock.patch.dict('os.environ', {}, clear=True), mock.patch.object(install.subprocess, 'run', side_effect=self.install_process([False])), mock.patch('Scripts.bridge_manager.uninstall') as remove, mock.patch.object(install, 'record_installation', side_effect=RuntimeError('state write failed')), self.assertRaises(RuntimeError):
                install.install(kimi_bridge='remove')
            remove.assert_not_called()
            self.assertTrue((bridge / 'original-index.html').exists(), 'a rolled back install leaves the bridge untouched')

    def test_rollback_keeps_restoring_when_the_unload_check_fails(self):
        with tempfile.TemporaryDirectory() as folder:
            home = pathlib.Path(folder)
            apps, launch_dir = self.fixture(home)
            installed = home / 'Applications/Agent Stats.app'
            installed.mkdir(parents=True)
            (installed / 'prior').write_text('old app')
            launch = launch_dir / 'local.agent.stats.plist'
            previous = plistlib.dumps({'Label': 'local.agent.stats'})
            launch.write_bytes(previous)
            with mock.patch.object(pathlib.Path, 'home', return_value=home), mock.patch.object(install, 'APP_OUTPUT', apps), mock.patch.dict('os.environ', {}, clear=True), mock.patch.object(install.subprocess, 'run', side_effect=self.install_process([False])), mock.patch.object(install, 'wait_for_unload', side_effect=[None, RuntimeError('unload stuck')]), mock.patch.object(install, 'record_installation', side_effect=RuntimeError('state write failed')), self.assertRaisesRegex(RuntimeError, 'state write failed'):
                install.install()
            self.assertEqual((installed / 'prior').read_text(), 'old app', 'the previous app returns even when a rollback step fails')
            self.assertEqual(launch.read_bytes(), previous)

    def test_registry_backups_are_bounded(self):
        with tempfile.TemporaryDirectory() as folder:
            support = pathlib.Path(folder)
            trash = pathlib.Path(folder) / 'trash'
            for index in range(9):
                (support / f'installed-2026101{index}-000000-000000.json.backup').write_text(f'{{"n":{index}}}')
            install.prune_registry_backups(support, keep=5, trash=trash)
            self.assertEqual([p.name for p in sorted(support.glob('installed-*.json.backup'))],
                             [f'installed-2026101{index}-000000-000000.json.backup' for index in range(4, 9)])
            # Retired snapshots move to the Trash instead of being deleted outright.
            retired = [p.name for folder in trash.iterdir() for p in sorted(folder.iterdir())]
            self.assertEqual(retired, [f'installed-2026101{index}-000000-000000.json.backup' for index in range(4)])
            install.prune_registry_backups(support, keep=5, trash=trash)
            self.assertEqual(len(list(trash.iterdir())), 1, 'a second prune retires nothing new')

    def test_a_source_edit_marks_the_built_bundle_stale(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            source = root / 'Agent Stats.app'
            source.mkdir()
            (root / 'products.json').write_text('{}')
            (root / 'MetricsCore.swift').write_text('// metrics')
            with mock.patch.object(install, 'ROOT', root), mock.patch.object(install, 'APP_SOURCES', ['MetricsCore.swift']):
                os.utime(source, (1_000_000, 1_000_000))
                os.utime(root / 'products.json', (900_000, 900_000))
                os.utime(root / 'MetricsCore.swift', (900_000, 900_000))
                self.assertFalse(install.stale_build(source, 'agent'), 'an untouched source must not force a rebuild')
                os.utime(root / 'MetricsCore.swift', (1_100_000, 1_100_000))
                self.assertTrue(install.stale_build(source, 'agent'), 'a newer source must force a rebuild')
                self.assertTrue(install.stale_build(root / 'Missing.app', 'agent'), 'a missing bundle must be built')

    def test_explicit_root_overrides_existing_login_root(self):
        with tempfile.TemporaryDirectory() as folder:
            home = pathlib.Path(folder)
            self.fixture(home)
            old_launch = plistlib.dumps({'EnvironmentVariables': {'CODEX_HOME': '/unified/codex', 'KIMI_CODE_HOME': '/unified/kimi'}})
            with mock.patch.dict('os.environ', {'CODEX_HOME': '/explicit/codex'}, clear=True):
                env = install.login_environment(home, PRODUCT, old_launch)
            self.assertEqual(env, {'CODEX_HOME': '/explicit/codex', 'KIMI_CODE_HOME': '/unified/kimi'})

    def test_upgrade_moves_legacy_support_app_to_trash_and_keeps_runtime_data(self):
        with tempfile.TemporaryDirectory() as folder:
            home = pathlib.Path(folder)
            apps, _ = self.fixture(home)
            support = home / 'Library/Application Support/Agent Stats'
            legacy_app = support / 'Agent Stats.app'
            (legacy_app / 'Contents/MacOS').mkdir(parents=True)
            (legacy_app / 'Contents/MacOS/AgentStats').write_bytes(b'old-v351')
            (support / 'parse-cache-codex.json').write_text('cached-data')
            (support / 'hook-context.json').write_text('{"sessionId":"session_1"}')
            with mock.patch.object(pathlib.Path, 'home', return_value=home), \
                 mock.patch.object(install, 'APP_OUTPUT', apps), \
                 mock.patch.dict('os.environ', {}, clear=True), \
                 mock.patch.object(install.subprocess, 'run', side_effect=self.install_process([False])):
                install.install()
            self.assertTrue((home / 'Applications/Agent Stats.app/Contents/MacOS/AgentStats').exists())
            self.assertFalse(legacy_app.exists(), 'old support app bundle is moved to Trash after upgrade')
            self.assertTrue(list((home / '.Trash').glob('Agent-Stats-legacy-app-*/Agent Stats.app')))
            self.assertEqual((support / 'parse-cache-codex.json').read_text(), 'cached-data')
            self.assertEqual((support / 'hook-context.json').read_text(), '{"sessionId":"session_1"}')
            record = json.loads((support / 'installation.json').read_text())
            self.assertEqual(record['appPath'], str(home / 'Applications/Agent Stats.app'))

    def test_icon_support_generates_valid_icns(self):
        with tempfile.TemporaryDirectory() as folder:
            target = pathlib.Path(folder) / 'AppIcon.icns'
            icon_support.write_app_icon(target)
            raw = target.read_bytes()
            self.assertEqual(raw[:4], b'icns')
            total_size = struct.unpack('>I', raw[4:8])[0]
            self.assertEqual(total_size, len(raw))
            offset = 8
            chunks = {}
            while offset < len(raw):
                tag = raw[offset:offset + 4]
                length = struct.unpack('>I', raw[offset + 4:offset + 8])[0]
                chunks[tag] = raw[offset + 8:offset + length]
                offset += length
            self.assertEqual(set(chunks), {b'ic08', b'ic09'})
            for tag, expected_dim in ((b'ic08', 256), (b'ic09', 512)):
                png = chunks[tag]
                self.assertEqual(png[:8], b'\x89PNG\r\n\x1a\n')
                width, height = struct.unpack('>II', png[16:24])
                self.assertEqual((width, height), (expected_dim, expected_dim))

    def test_signing_support_selects_and_persists_identities(self):
        dev = ('D' * 40, 'Developer ID Application: Example (TEAM)')
        local = ('L' * 40, signing_support.DEFAULT_CERT_NAME)
        apple = ('A' * 40, 'Apple Development: user@example.com')
        self.assertEqual(signing_support.select_preferred_identity([apple, local, dev]), dev[0])
        self.assertEqual(signing_support.select_preferred_identity([apple, local]), local[0])
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder) / 'repo'
            home = pathlib.Path(folder) / 'home'
            root.mkdir()
            home.mkdir()
            with self.assertRaises(RuntimeError):
                signing_support.ensure_signing_identity(requested='-', root=root, home=home)
            with mock.patch.object(signing_support, 'find_valid_identities', return_value=[apple, local]):
                chosen = signing_support.ensure_signing_identity(root=root, home=home, auto_create=True)
            self.assertEqual(chosen, local[0])
            self.assertEqual((root / '.build/signing-identity.txt').read_text().strip(), local[0])
            self.assertEqual((home / 'Library/Application Support/Agent Stats/signing-identity.txt').read_text().strip(), local[0])
            with mock.patch.object(signing_support, 'find_valid_identities', return_value=[apple, dev]):
                # Saved local[0] is no longer valid -> falls back to preferred dev[0]
                reselected = signing_support.ensure_signing_identity(root=root, home=home, auto_create=True)
            self.assertEqual(reselected, dev[0])
            with mock.patch.object(signing_support, 'find_valid_identities', return_value=[apple]), \
                 mock.patch.object(signing_support, 'create_local_codesign_certificate', return_value=local[0]) as create_local:
                explicit_local = signing_support.ensure_signing_identity(
                    requested=signing_support.DEFAULT_CERT_NAME, root=root, home=home, auto_create=True)
            create_local.assert_called_once()
            self.assertEqual(explicit_local, local[0])
            self.assertEqual((root / '.build/signing-identity.txt').read_text().strip(), local[0])
            with mock.patch.object(signing_support, 'find_valid_identities', return_value=[]), \
                 mock.patch.object(signing_support, 'create_local_codesign_certificate', return_value=local[0]) as create_cert:
                created = signing_support.ensure_signing_identity(root=root, home=home, auto_create=True)
            create_cert.assert_called_once()
            self.assertEqual(created, local[0])

    def test_package_dmg_creates_zip_and_signed_dmg(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            app = root / 'Agent Stats.app'
            (app / 'Contents/MacOS').mkdir(parents=True)
            (app / 'Contents/MacOS/AgentStats').write_bytes(b'bin')
            out = root / 'releases'
            seen = {}

            def fake_run(cmd, **kwargs):
                if cmd[0] == '/usr/bin/ditto':
                    seen['ditto'] = list(cmd)
                    pathlib.Path(cmd[-1]).write_bytes(b'zip-data')
                elif cmd[0] == '/usr/bin/hdiutil' and cmd[1] == 'create':
                    src = pathlib.Path(cmd[cmd.index('-srcfolder') + 1])
                    seen['symlink'] = (src / 'Applications').is_symlink() and os.readlink(src / 'Applications') == '/Applications'
                    seen['app_present'] = (src / 'Agent Stats.app/Contents/MacOS/AgentStats').exists()
                    pathlib.Path(cmd[-1]).write_bytes(b'dmg-data')
                return subprocess.CompletedProcess(cmd, 0)

            with mock.patch.object(package_dmg.subprocess, 'run', side_effect=fake_run) as calls:
                dmg_path, zip_path = package_dmg.package_release(app, version='1.0.0', signing_identity='A' * 40, output_dir=out)
            self.assertTrue(dmg_path.exists() and zip_path.exists())
            self.assertEqual(dmg_path.name, 'Agent-Stats-1.0.0.dmg')
            self.assertEqual(zip_path.name, 'Agent-Stats-1.0.0-macos-arm64.zip')
            self.assertIn('--norsrc', seen['ditto'])
            self.assertNotIn('--sequesterRsrc', seen['ditto'])
            self.assertTrue(seen.get('symlink'))
            self.assertTrue(seen.get('app_present'))
            commands = [call.args[0] for call in calls.call_args_list]
            self.assertTrue(any(cmd[:3] == ['/usr/bin/codesign', '--force', '--sign'] and str(dmg_path.name) in cmd[-1] for cmd in commands))

    def test_uninstall_wrapper_locates_installed_executable(self):
        with tempfile.TemporaryDirectory() as folder:
            home = pathlib.Path(folder)
            support = home / 'Library/Application Support/Agent Stats'
            support.mkdir(parents=True)
            custom = home / 'CustomApps/Agent Stats.app/Contents/MacOS/AgentStats'
            custom.parent.mkdir(parents=True)
            custom.write_bytes(b'exe')
            (support / 'installation.json').write_text(json.dumps({'version': 1, 'appPath': str(home / 'CustomApps/Agent Stats.app')}))
            self.assertEqual(uninstall.find_installed_executable(PRODUCT, home=home), custom)


if __name__ == '__main__':
    unittest.main()
