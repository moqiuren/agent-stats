"""Build real SwiftPM modules; keep developer drivers outside production targets."""
import argparse
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent


def swift_arguments(root, configuration):
    root = pathlib.Path(root)
    return ['--package-path', str(root), '--scratch-path', str(root / '.build/swiftpm'),
            '--configuration', configuration, '--arch', 'arm64']


def binary_directory(configuration='debug', root=ROOT):
    result = subprocess.run(['swift', 'build', *swift_arguments(root, configuration), '--show-bin-path'],
                            check=True, capture_output=True, text=True)
    return pathlib.Path(result.stdout.strip().splitlines()[-1])


def build_product(product, configuration='debug', root=ROOT):
    subprocess.run(['swift', 'build', *swift_arguments(root, configuration), '--product', product,
                    '--explicit-target-dependency-import-check', 'error'], check=True)
    return binary_directory(configuration, root)


def build_tool(source, output, configuration='debug', root=ROOT):
    root = pathlib.Path(root)
    directory = build_product('StatsAdapters', configuration, root)
    # SwiftPM's package-access identity is the canonical local directory name,
    # independent of the display name in Package.swift (AgentStats).
    identity = root.name.lower()
    modules = directory / 'Modules' if (directory / 'Modules').exists() else directory
    flags = ['-O'] if configuration == 'release' else []
    czstd_include = ROOT / 'Sources' / 'CZstd' / 'include'
    subprocess.run(['swiftc', '-parse-as-library', '-package-name', identity, *flags,
                    '-target', 'arm64-apple-macosx13.0', '-I', str(modules), '-L', str(directory),
                    '-Xcc', '-fmodule-map-file=' + str(czstd_include / 'module.modulemap'),
                    '-Xcc', '-I' + str(czstd_include),
                    str(source), '-lStatsAdapters', str(directory / 'CZstd.o'), '-lsqlite3',
                    '-o', str(output)], check=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('tool', choices=['native-driver', 'benchmark'])
    parser.add_argument('--output', required=True, type=pathlib.Path)
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    build_tool(ROOT / 'Tools' / ('NativeTestDriver.swift' if args.tool == 'native-driver' else 'MetricsBenchmarks.swift'),
               args.output, 'debug' if args.tool == 'native-driver' else 'release')
