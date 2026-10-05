import errno
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'lib'))
from projection import MARKER, Projection, UNAVAILABLE


class ProjectionTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name).resolve()
        self.root = self.base / 'share'
        self.root.mkdir()
        self.project = self.base / 'private-parent' / 'selected'
        self.project.mkdir(parents=True)
        (self.project / 'file').write_text('original')
        (self.project.parent / 'secret').write_text('not shared')
        (self.root / 'project').symlink_to(self.project)
        self.fs = Projection(str(self.root))

    def tearDown(self):
        self.fs.close()
        self.temp.cleanup()

    def read(self, path):
        fd = self.fs.open(path, os.O_RDONLY)
        try:
            return self.fs.read(path, 1000, 0, fd)
        finally:
            self.fs.release(path, fd)

    def write(self, path, data, create=False):
        fd = self.fs.create(path, 0o644) if create else self.fs.open(path, os.O_WRONLY | os.O_TRUNC)
        try:
            self.fs.write(path, data, 0, fd)
            self.fs.fsync(path, False, fd)
        finally:
            self.fs.release(path, fd)

    def test_live_export_and_private_path_not_returned(self):
        self.assertTrue(stat.S_ISDIR(self.fs.getattr('/project')['st_mode']))
        self.write('/project/file', b'live')
        self.assertEqual((self.project / 'file').read_bytes(), b'live')
        self.assertEqual(self.read('/project/file'), b'live')
        with self.assertRaises(OSError):
            self.fs.readlink('/project')
        with self.assertRaises(OSError):
            self.read('/project/../secret')

    def test_internal_absolute_and_relative_host_links(self):
        (self.root / 'file').write_text('inside')
        (self.root / 'relative').symlink_to('file')
        (self.root / 'absolute').symlink_to(self.root / 'file')
        (self.project / 'inside-link').symlink_to(self.project / 'file')
        self.assertEqual(self.fs.readlink('/relative'), 'file')
        self.assertEqual(self.fs.readlink('/absolute'), 'file')
        self.assertEqual(self.fs.readlink('/project/inside-link'), 'file')
        fd = self.fs.open('/absolute', os.O_SYMLINK)
        try:
            with self.assertRaises(OSError):
                self.fs.read('/absolute', 4096, 0, fd)
        finally:
            self.fs.release('/absolute', fd)

    def test_dangling_cyclic_and_unavailable_exports(self):
        (self.root / 'dangling').symlink_to('later')
        (self.root / 'cycle-a').symlink_to('cycle-b')
        (self.root / 'cycle-b').symlink_to('cycle-a')
        (self.root / 'missing-export').symlink_to(self.base / 'not-yet')
        self.assertEqual(self.fs.readlink('/dangling'), 'later')
        self.assertEqual(self.fs.readlink('/cycle-a'), 'cycle-b')
        self.assertEqual(self.fs.readlink('/missing-export'), UNAVAILABLE)
        (self.base / 'not-yet').write_text('arrived')
        self.assertEqual(self.read('/missing-export'), b'arrived')

    def test_nested_escape_and_disabled_external_sharing(self):
        (self.project / 'escape').symlink_to('../secret')
        self.assertEqual(self.fs.readlink('/project/escape'), UNAVAILABLE)
        with self.assertRaises(OSError):
            self.read('/project/escape')
        self.fs.external_links = False
        self.assertEqual(self.fs.readlink('/project'), UNAVAILABLE)
        self.fs.symlink('/ordinary', 'relative-target')
        self.assertEqual(self.fs.readlink('/ordinary'), 'relative-target')

    def test_guest_links_cannot_grant_or_launder_host_access(self):
        self.fs.symlink('/guest-link', str(self.project.parent / 'secret'))
        self.assertEqual(self.fs.readlink('/guest-link'), str(self.project.parent / 'secret'))
        with self.assertRaises(OSError):
            self.read('/guest-link')
        (self.root / 'host-indirection').symlink_to('guest-link')
        self.assertEqual(self.fs.readlink('/host-indirection'), 'guest-link')
        self.fs.symlink('/project/guest-link', str(self.project.parent / 'secret'))
        (self.root / 'external-indirection').symlink_to(self.project / 'guest-link')
        self.assertEqual(self.fs.readlink('/external-indirection'), UNAVAILABLE)
        for action in (lambda: self.fs.removexattr('/guest-link', MARKER),
                       lambda: self.fs.setxattr('/guest-link', MARKER, b'', 0)):
            with self.assertRaises(OSError):
                action()
        self.assertNotIn(MARKER, self.fs.listxattr('/guest-link'))

    def test_guest_symlinks_survive_restart_and_rename(self):
        self.fs.symlink('/python', '/Users/developer/tools/python/bin/python')
        self.fs.rename('/python', '/python3')
        self.fs.close()
        self.fs = Projection(str(self.root))
        self.assertEqual(self.fs.readlink('/python3'), '/Users/developer/tools/python/bin/python')
        self.assertEqual(os.readlink(self.root / 'python3'), '/Users/developer/tools/python/bin/python')
        fd = self.fs.open('/python3', os.O_SYMLINK)
        try:
            self.assertTrue(stat.S_ISLNK(os.fstat(fd).st_mode))
        finally:
            self.fs.release('/python3', fd)

    def test_backend_that_follows_symlink_metadata_handles_is_rejected(self):
        referent = os.open(self.project / 'file', os.O_RDONLY)
        with mock.patch('projection.os.open', return_value=referent), \
             mock.patch('projection.xattr.getxattr') as get_attribute:
            with self.assertRaises(OSError) as error:
                self.fs.marked(self.fs.root_fd, 'unsafe-backend-link')
            self.assertEqual(error.exception.errno, errno.ENOTSUP)
            get_attribute.assert_not_called()
        with self.assertRaises(OSError) as error:
            os.fstat(referent)
        self.assertEqual(error.exception.errno, errno.EBADF)

    def test_atomic_save_keeps_file_export_and_removal_keeps_original(self):
        (self.root / 'file-export').symlink_to(self.project / 'file')
        self.write('/temporary', b'replacement', create=True)
        self.fs.rename('/temporary', '/file-export')
        self.assertTrue((self.root / 'file-export').is_symlink())
        self.assertEqual((self.project / 'file').read_bytes(), b'replacement')
        self.fs.unlink('/file-export')
        self.assertTrue((self.project / 'file').exists())

    def test_no_guest_rename_promotion(self):
        (self.root / 'folder').mkdir()
        (self.root / 'folder' / 'host-link').symlink_to('../../private-parent/selected')
        with self.assertRaises(OSError):
            self.fs.rename('/folder', '/moved')
        with self.assertRaises(OSError):
            self.fs.rename('/project', '/moved')

    def test_development_primitives(self):
        self.fs.mkdir('/build', 0o755)
        self.write('/build/run', b'#!/bin/sh\nexit 0\n', create=True)
        self.fs.chmod('/build/run', 0o755)
        self.assertEqual(self.fs.getattr('/build/run')['st_mode'] & 0o777, 0o755)
        self.fs.link('/build/hard', '/build/run')
        self.assertEqual(self.read('/build/hard'), b'#!/bin/sh\nexit 0\n')
        self.fs.symlink('/build/soft', 'run')
        self.assertEqual(self.fs.readlink('/build/soft'), 'run')
        self.fs.setxattr('/build/run', 'com.example.test', b'value', 0)
        self.assertEqual(self.fs.getxattr('/build/run', 'com.example.test'), b'value')
        self.fs.removexattr('/build/run', 'com.example.test')
        fd = self.fs.open('/build/run', os.O_RDONLY)
        self.fs.unlink('/build/run')
        try:
            self.assertEqual(self.fs.read('/build/run', 100, 0, fd), b'#!/bin/sh\nexit 0\n')
        finally:
            self.fs.release('/build/run', fd)


if __name__ == '__main__':
    unittest.main()
