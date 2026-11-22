#!/usr/bin/env python3
"""Release-mode benchmarks against SwiftPM libraries, using synthetic data only."""
import argparse
import json
import pathlib
import subprocess
import sys
import tarfile
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
from Scripts.swiftpm_support import build_tool

# Compatibility for source archives made before the SwiftPM migration.
LEGACY_SOURCES = ['MetricsCore.swift', 'CodexMetrics.swift', 'KimiMetrics.swift', 'Product.swift',
                  'SessionTitle.swift', 'ProjectCatalog.swift', 'StatsSnapshot.swift', 'IncrementalLog.swift',
                  'SessionLogStore.swift', 'SessionAggregation.swift', 'CodexSessionReader.swift',
                  'KimiSessionReader.swift', 'SessionReader.swift', 'ParseCache.swift', 'UsageAccounting.swift']


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--baseline', type=pathlib.Path, help='Source archive captured before refactoring')
    parser.add_argument('--output', type=pathlib.Path, default=ROOT / '.build/benchmarks/current.json')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='agent-stats-benchmark-') as temporary:
        work = pathlib.Path(temporary)
        binary = work / 'benchmark'
        if not args.baseline:
            build_tool(ROOT / 'Tools/MetricsBenchmarks.swift', binary, configuration='release')
        else:
            source = work / 'baseline'
            source.mkdir()
            with tarfile.open(args.baseline) as archive:
                names = set(archive.getnames())
                if 'Package.swift' in names:
                    for member in archive.getmembers():
                        name = pathlib.PurePosixPath(member.name)
                        if not member.isfile() or name.is_absolute() or '..' in name.parts:
                            continue
                        if member.name not in {'Package.swift', 'products.json'} and not (name.parts[0] in {'Sources', 'Tests', 'Tools'} and name.suffix == '.swift'):
                            continue
                        destination = source / member.name
                        destination.parent.mkdir(parents=True, exist_ok=True)
                        destination.write_bytes(archive.extractfile(member).read())
                    build_tool(source / 'Tools/MetricsBenchmarks.swift', binary, configuration='release', root=source)
                else:
                    sources = [name for name in LEGACY_SOURCES if name in names]
                    for name in sources + ['products.json']:
                        (source / name).write_bytes(archive.extractfile(name).read())
                    driver = (ROOT / 'Tools/MetricsBenchmarks.swift').read_text().replace('import StatsCore\n', '').replace('import StatsAdapters\n', '')
                    (source / 'Benchmark.swift').write_text(driver)
                    flags = [] if 'StatsSnapshot.swift' in sources else ['-D', 'LEGACY_COLLECTION']
                    subprocess.run(['swiftc', '-O', '-module-cache-path', str(work / 'module-cache'), *flags,
                                    *[str(source / name) for name in sources], str(source / 'Benchmark.swift'),
                                    '-o', str(binary), '-lsqlite3'], check=True)
        result = subprocess.run([str(binary), str(work / 'fixtures')], check=True, capture_output=True, text=True)
        measurements = [json.loads(line) for line in result.stdout.splitlines()]
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps({'optimization': '-O', 'synthetic': True, 'samples': 3,
                                          'measurements': measurements}, indent=2) + '\n')
        print(result.stdout, end='')
        print('Saved:', args.output)


if __name__ == '__main__':
    main()
