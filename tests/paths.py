"""Locations used by the test suite. Defaults keep everything inside the source folder:
<source>/build/OpenNTFS.app, <source>/build/test-images and <source>/build/validation.
Override with OPENNTFS_APP / OPENNTFS_BUILD (build.sh and run_tests.sh set them)."""
import os
from pathlib import Path
SOURCE_PATH = Path(__file__).resolve().parents[1]
BUILD_PATH = Path(os.environ.get('OPENNTFS_BUILD', SOURCE_PATH / 'build')).resolve()
APP_PATH = Path(os.environ.get('OPENNTFS_APP', BUILD_PATH / 'OpenNTFS.app')).resolve()
IMAGES_PATH = BUILD_PATH / 'test-images'
REPORTS_PATH = BUILD_PATH / 'validation'
IMAGES_PATH.mkdir(parents=True, exist_ok=True)
REPORTS_PATH.mkdir(parents=True, exist_ok=True)
