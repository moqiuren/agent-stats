"""Package signed Agent Stats .app into .dmg and .zip release archives."""
import pathlib
import shutil
import subprocess
import tempfile
from Scripts.packaging_support import BUILD, PRODUCTS


def _copy_clean(source, target):
    shutil.copyfile(source, target)
    shutil.copymode(source, target)
    return target


def strip_finder_xattrs(path):
    for attribute in ('com.apple.FinderInfo', 'com.apple.ResourceFork'):
        subprocess.run(['/usr/bin/xattr', '-dr', attribute, str(path)], capture_output=True)


def release_paths(version, output_dir=BUILD / 'releases'):
    folder = pathlib.Path(output_dir)
    return (
        folder / f'Agent-Stats-{version}.dmg',
        folder / f'Agent-Stats-{version}-macos-arm64.zip',
    )


def package_release(app_path, version=None, signing_identity=None, output_dir=BUILD / 'releases'):
    app_source = pathlib.Path(app_path)
    if not app_source.exists():
        raise RuntimeError(f'找不到待打包的应用包：{app_source}')
    resolved_version = version or PRODUCTS['agent']['version']
    target_dir = pathlib.Path(output_dir)
    target_dir.mkdir(parents=True, exist_ok=True)
    dmg_path, zip_path = release_paths(resolved_version, target_dir)

    with tempfile.TemporaryDirectory(prefix='agent-stats-release-') as folder:
        stage = pathlib.Path(folder)
        staged_app = stage / app_source.name
        shutil.copytree(app_source, staged_app, symlinks=True, copy_function=_copy_clean)
        strip_finder_xattrs(staged_app)
        subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(staged_app)], check=True)

        temp_zip = target_dir / ('.' + zip_path.name + '.incoming')
        temp_zip.unlink(missing_ok=True)
        subprocess.run(
            ['/usr/bin/ditto', '-c', '-k', '--norsrc', '--keepParent', str(staged_app), str(temp_zip)],
            check=True,
        )
        temp_zip.replace(zip_path)

        dmg_stage = stage / 'dmg'
        dmg_stage.mkdir()
        dmg_app = dmg_stage / app_source.name
        shutil.copytree(staged_app, dmg_app, symlinks=True, copy_function=_copy_clean)
        (dmg_stage / 'Applications').symlink_to('/Applications')

        temp_dmg = target_dir / ('.' + dmg_path.name + '.incoming.dmg')
        temp_dmg.unlink(missing_ok=True)
        subprocess.run(
            ['/usr/bin/hdiutil', 'create', '-volname', PRODUCTS['agent']['name'],
             '-srcfolder', str(dmg_stage), '-ov', '-format', 'UDZO', str(temp_dmg)],
            check=True,
        )
        strip_finder_xattrs(temp_dmg)
        if signing_identity:
            subprocess.run(
                ['/usr/bin/codesign', '--force', '--sign', signing_identity, '--timestamp=none', str(temp_dmg)],
                check=True,
            )
            subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(temp_dmg)], check=True)
        temp_dmg.replace(dmg_path)

    return dmg_path, zip_path
