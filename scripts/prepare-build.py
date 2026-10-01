#!/usr/bin/env python3
"""Generate shared Xcode project/workspace metadata; no build artifacts are reused."""
from pathlib import Path
import subprocess
import shutil
import xml.etree.ElementTree as ET
root = Path(__file__).resolve().parent.parent
subprocess.run(['python3', str(root / 'scripts/generate-xcode-project.py')], cwd=root, check=True)
workspace = root / '.build/Mox.xcworkspace'
workspace.mkdir(parents=True, exist_ok=True)
xml = ET.Element('Workspace', version='1.0')
ET.SubElement(xml, 'FileRef', location='absolute:' + str(root))
ET.ElementTree(xml).write(workspace / 'contents.xcworkspacedata', encoding='utf-8', xml_declaration=True)

# Xcode projects maintain their own resolved file even for a local package.
resolved = root / "Mox.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
resolved.parent.mkdir(parents=True, exist_ok=True)
shutil.copyfile(root / "Package.resolved", resolved)
