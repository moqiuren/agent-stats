#!/usr/bin/env python3
"""Run the original native assertions through real SwiftPM module imports."""
import os
import pathlib
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(root))
from Scripts.swiftpm_support import swift_arguments

with tempfile.TemporaryDirectory(prefix='stats-swiftpm-tests-') as folder:
    environment = dict(os.environ)
    # All synthetic readers, including XCTest, use a cache isolated from the app.
    environment['STATS_CACHE_DIR'] = str(pathlib.Path(folder) / 'cache')
    subprocess.run(['swift', 'test', *swift_arguments(root, 'debug'),
                    '--explicit-target-dependency-import-check', 'error', *sys.argv[1:]], check=True, env=environment)
