#!/usr/bin/env python3
"""Developer build tooling; installed apps need neither Python nor Node."""
import argparse
import os
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
from Scripts.icon_support import write_app_icon
from Scripts.package_dmg import package_release
from Scripts.packaging_support import PRODUCTS, ROOT, APP_OUTPUT, generate_documents, plugin_manifest
from Scripts.signing_support import choose_strict_identity, ensure_signing_identity, save_identity
from Scripts.swiftpm_support import build_product


def choose_signing_identity(output, requested=None):
    return choose_strict_identity(output, requested)


def build(provider, signing_identity):
    product = PRODUCTS[provider]
    with tempfile.TemporaryDirectory(prefix=provider + '-stats-build-') as stage:
        app = pathlib.Path(stage) / (product['name'] + '.app')
        mac, resources = app / 'Contents/MacOS', app / 'Contents/Resources'
        mac.mkdir(parents=True)
        resources.mkdir()
        binary_dir = build_product('AgentStats', configuration='release', root=ROOT)
        shutil.copyfile(binary_dir / 'AgentStats', mac / product['executable'])
        (mac / product['executable']).chmod(0o755)
        shutil.copyfile(ROOT / 'LICENSE', resources / 'LICENSE')
        shutil.copyfile(ROOT / 'LICENSE-DSH.txt', resources / 'LICENSE-DSH.txt')
        shutil.copyfile(ROOT / 'Sources' / 'CZstd' / 'LICENSE-ZSTD.txt', resources / 'LICENSE-ZSTD.txt')
        write_app_icon(resources / 'AppIcon.icns')
        info = {'CFBundleIdentifier': product['bundle_id'], 'CFBundleName': product['name'],
                'CFBundleDisplayName': product['name'], 'CFBundleExecutable': product['executable'],
                'CFBundleIconFile': 'AppIcon',
                'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': product['version'],
                'CFBundleVersion': product['build'], 'StatsProviders': product['providers'],
                'StatsLegacyProducts': product['legacy_products'],
                'StatsGitHubRepo': product.get('github_repo', 'moqiuren/agent-stats'),
                'StatsProvider': provider, 'LSUIElement': True, 'NSHighResolutionCapable': True,
                'LSMinimumSystemVersion': '13.0'}
        with (app / 'Contents/Info.plist').open('wb') as stream:
            plistlib.dump(info, stream)
        subprocess.run(['codesign', '--force', '--sign', signing_identity, '--timestamp=none', str(app)], check=True)
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
        APP_OUTPUT.mkdir(parents=True, exist_ok=True)
        destination = APP_OUTPUT / app.name
        incoming = APP_OUTPUT / ('.' + app.name + '.incoming')
        if incoming.exists():
            shutil.rmtree(incoming)
        def copy_clean(source, target):
            shutil.copyfile(source, target)
            shutil.copymode(source, target)
            return target
        shutil.copytree(app, incoming, copy_function=copy_clean)
        if destination.exists():
            shutil.rmtree(destination)
        incoming.rename(destination)
        # Finder metadata added by File Provider folders is not signed payload.
        # Clean only our build output, then verify the actual deliverable.
        for attribute in ('com.apple.FinderInfo', 'com.apple.ResourceFork'):
            subprocess.run(['/usr/bin/xattr', '-dr', attribute, str(destination)], capture_output=True)
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(destination)], check=True)
        print(destination)
        return destination


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', choices=['agent'], default='agent')
    parser.add_argument('--signing-identity', default=os.environ.get('STATS_SIGNING_IDENTITY'))
    parser.add_argument('--auto-cert', action='store_true', help='无可用证书时自动生成并信任本地代码签名证书，多证书时按优先级自动选择。')
    parser.add_argument('--dmg', action='store_true', help='构建后同步输出 .dmg 与 .zip 分发包至 .build/releases/。')
    args = parser.parse_args()
    if args.auto_cert:
        identity = ensure_signing_identity(requested=args.signing_identity, root=ROOT, auto_create=True)
    else:
        identity_file = ROOT / '.build/signing-identity.txt'
        requested = args.signing_identity or (identity_file.read_text().strip() if identity_file.exists() else None)
        available = subprocess.run(['/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning'], check=True, capture_output=True, text=True)
        identity = choose_signing_identity(available.stdout, requested)
        save_identity(identity, root=ROOT)
    generate_documents()
    plugin_manifest(ROOT / 'kimi.plugin.json')
    app_bundle = build(args.app, identity)
    if args.dmg:
        dmg_path, zip_path = package_release(
            app_bundle, version=PRODUCTS[args.app]['version'], signing_identity=identity)
        print(dmg_path)
        print(zip_path)
