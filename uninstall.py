#!/usr/bin/env python3
"""Developer wrapper for the single native application's explicit uninstall."""
import argparse
import json
import pathlib
import subprocess
from Scripts.packaging_support import PRODUCTS


def find_installed_executable(product, home=None):
    user_home = pathlib.Path(home) if home is not None else pathlib.Path.home()
    support = user_home / 'Library/Application Support' / product['name']
    candidates = []
    state = support / 'installation.json'
    if state.exists():
        try:
            app_path = json.loads(state.read_text()).get('appPath')
            if isinstance(app_path, str) and app_path.startswith('/'):
                candidates.append(pathlib.Path(app_path))
        except Exception:
            pass
    bundle_name = product['name'] + '.app'
    candidates += [
        pathlib.Path('/Applications') / bundle_name,
        user_home / 'Applications' / bundle_name,
        support / bundle_name,
    ]
    for app in candidates:
        executable = app / 'Contents/MacOS' / product['executable']
        if executable.exists():
            return executable
    return None


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='卸载统一 Agent Stats；保留宿主和会话数据。')
    parser.add_argument('--app', choices=['agent'], required=True)
    args = parser.parse_args()
    product = PRODUCTS[args.app]
    executable = find_installed_executable(product)
    if executable is None:
        print(product['name'] + ' 未安装。')
    else:
        subprocess.run([str(executable), '--uninstall'], check=True)
