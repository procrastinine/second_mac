#!/usr/bin/env python3
"""Mount the private host projection and exit when its Tart process exits."""
import errno
import json
import logging
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time

# Do not accidentally pick an unrelated FUSE-T library from an old installation.
os.environ['FUSE_LIBRARY_PATH'] = '/usr/local/lib/libfuse.2.dylib'
from fuse import FUSE, Operations
from projection import Projection


class Filesystem(Operations):
    def __init__(self, projection, on_mount):
        self.projection = projection
        self.on_mount = on_mount

    def __call__(self, operation, *args):
        if operation == 'init':
            self.on_mount()
            return None
        method = getattr(self.projection, operation, None)
        if method is None:
            if operation in ('init', 'destroy'):
                return None
            raise OSError(errno.ENOSYS, 'Unsupported operation')
        # Reads/writes use independent pread/pwrite offsets on pinned descriptors.
        # Serialize namespace changes, including symlink classification, against
        # other guest mutations. Host-side changes remain host-authorized.
        if operation in ('read', 'write', 'fsync', 'flush', 'release'):
            return method(*args)
        with self.projection.lock:
            return method(*args)

    def __getattribute__(self, name):
        # fusepy registers callbacks with hasattr before using __call__.
        if name not in ('projection', 'on_mount', '__call__', '__class__', '__getattribute__'):
            projection = object.__getattribute__(self, 'projection')
            if hasattr(projection, name):
                return getattr(projection, name)
        return super().__getattribute__(name)


def main():
    state = Path(sys.argv[1])
    generation = sys.argv[2]
    config = json.loads((state / 'config.json').read_text())
    mount = state / 'shared-view'
    mount.mkdir(mode=0o700, exist_ok=True)
    root = config['linked_share'] if config.get('sharing') == 'hybrid' else config['share']
    projection = Projection(root, config.get('external_links', True))
    # No request paths or tracebacks should appear in filesystem error output.
    logging.getLogger('fuse').disabled = True
    stopped = threading.Event()

    def watch():
        started = time.monotonic()
        while not stopped.wait(1):
            try:
                owner_info = json.loads((state / 'share-owner.json').read_text())
                if owner_info.get('generation') != generation:
                    return
                owner = int(owner_info['pid'])
                if owner == 0:
                    if time.monotonic() - started < 45:
                        continue
                    raise ProcessLookupError
                os.kill(owner, 0)
            except PermissionError:
                continue
            except (ProcessLookupError, FileNotFoundError, ValueError, KeyError):
                subprocess.run(['/sbin/umount', '-f', str(mount)],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                return

    # Start the watcher only after FUSE's mount setup; foreground avoids forking
    # a multithreaded process. Kernel mounting is explicit, with no FSKit fallback.
    watcher = threading.Thread(target=watch, daemon=True)
    try:
        FUSE(Filesystem(projection, watcher.start), str(mount), foreground=True, nothreads=False,
             fsname='agent-files', volname='agent-files', nobrowse=True,
             nosuid=True, nodev=True, auto_cache=True, attr_timeout=0,
             entry_timeout=0, negative_timeout=0, hard_remove=True, quiet=True)
    finally:
        stopped.set()
        projection.close()


if __name__ == '__main__':
    try:
        main()
    except (OSError, RuntimeError, ValueError):
        print('Shared filesystem could not mount; check macFUSE installation and host permissions.', file=sys.stderr)
        sys.exit(1)
