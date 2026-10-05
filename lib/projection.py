"""A descriptor-confined, writable view of an explicitly shared host directory.

Only host-created links can introduce exports. Guest links carry a private xattr
and are resolved by the guest kernel, never by a host open(2). No network server
or privileged filesystem process is involved.
"""
import contextlib
import errno
import os
import posixpath
import stat
import threading
import uuid
from dataclasses import dataclass

import xattr

MARKER = 'com.agent-vm.guest-link'
PRIVATE_PREFIX = '.agent-vm-link-'
UNAVAILABLE = '/.agent-vm/unavailable'
DIRECTORY = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


@dataclass
class Node:
    parent: int
    name: str
    st: object
    boundary: str
    virtual_root: str
    kind: str = 'normal'
    target: str = ''
    alias_parent: int = -1
    alias_name: str = ''


class Projection:
    def __init__(self, root, external_links=True):
        self.root = os.path.realpath(root)
        self.root_fd = os.open(self.root, DIRECTORY)
        self.external_links = external_links
        self.lock = threading.RLock()

    def close(self):
        os.close(self.root_fd)

    @staticmethod
    def inside(path, root):
        return path == root or path.startswith(root.rstrip('/') + '/')

    @staticmethod
    def components(path):
        parts = path.split('/')
        if any(p in ('.', '..') or p.startswith(PRIVATE_PREFIX) for p in parts):
            raise OSError(errno.EACCES, 'Path is outside the share')
        return [p for p in parts if p]

    @staticmethod
    def symlink_fd(parent, name, flags=os.O_SYMLINK):
        fd = os.open(name, flags & ~os.O_NOFOLLOW, dir_fd=parent)
        # Some remote/FUSE backends ignore O_SYMLINK and open the referent.
        # Never read attributes, mark provenance, or return that descriptor.
        try:
            if not stat.S_ISLNK(os.fstat(fd).st_mode):
                raise OSError(errno.ENOTSUP, 'Backend cannot open symlink metadata safely')
            return fd
        except BaseException:
            os.close(fd)
            raise

    @classmethod
    def marked(cls, parent, name):
        fd = cls.symlink_fd(parent, name)
        try:
            try:
                return xattr.getxattr(fd, MARKER) == b'1'
            except OSError as e:
                if e.errno != errno.ENOATTR:
                    raise
                return False
        finally:
            os.close(fd)

    def trusted_target(self, path):
        """Resolve a host grant without following any guest-authored symlink."""
        pending = os.path.abspath(path).split('/')
        current, links = '/', 0
        while pending:
            name = pending.pop(0)
            if not name or name == '.':
                continue
            if name == '..':
                current = os.path.dirname(current)
                continue
            candidate = os.path.join(current, name)
            info = os.lstat(candidate)
            if stat.S_ISLNK(info.st_mode):
                links += 1
                if links > 40:
                    raise OSError(errno.ELOOP, 'Cyclic host link')
                fd = os.open(current, DIRECTORY)
                try:
                    if self.marked(fd, name):
                        raise OSError(errno.EACCES, 'Guest links cannot grant host access')
                    raw = os.readlink(name, dir_fd=fd)
                finally:
                    os.close(fd)
                if raw.startswith('/'):
                    current = '/'
                pending = raw.split('/') + pending
            else:
                current = candidate
        return current

    @contextlib.contextmanager
    def node(self, path, missing=False):
        """All untrusted traversal uses dirfds and O_NOFOLLOW, including leaves."""
        parts = self.components(path)
        opened = [os.dup(self.root_fd)]
        parent, boundary, vroot = opened[0], self.root, '/'
        host_parent = self.root
        try:
            for index, name in enumerate(parts or ['.']):
                last = index == len(parts) - 1 or not parts
                try:
                    info = os.stat(name, dir_fd=parent, follow_symlinks=False)
                except FileNotFoundError:
                    if last and missing:
                        yield Node(parent, name, None, boundary, vroot)
                        return
                    raise
                node = Node(parent, name, info, boundary, vroot)
                if stat.S_ISLNK(info.st_mode):
                    raw = os.readlink(name, dir_fd=parent)
                    if self.marked(parent, name):
                        node.kind, node.target = 'link', raw
                    else:
                        # Translate internal links lexically, so an ordinary
                        # host link cannot launder a guest-created link into a
                        # new host export through realpath().
                        target = os.path.normpath(os.path.join(host_parent, raw))
                        virtual = '/' + '/'.join(parts[:index + 1])
                        if self.inside(target, boundary):
                            relative = os.path.relpath(target, boundary)
                            translated = posixpath.join(vroot, relative)
                            node.kind = 'link'
                            node.target = posixpath.relpath(translated, posixpath.dirname(virtual))
                        elif boundary == self.root and self.external_links:
                            try:
                                target = self.trusted_target(target)
                                target_parent, target_name = os.path.split(target)
                                fd = os.open(target_parent or '/', DIRECTORY)
                                opened.append(fd)
                                info = os.stat(target_name or '.', dir_fd=fd, follow_symlinks=False)
                                if not (stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode)):
                                    raise OSError(errno.EACCES, 'Unsupported export')
                                node = Node(fd, target_name or '.', info, target, virtual,
                                            'export', '', parent, name)
                            except OSError:
                                node.kind, node.target = 'blocked', UNAVAILABLE
                        else:
                            node.kind, node.target = 'blocked', UNAVAILABLE
                if last:
                    yield node
                    return
                if node.kind in ('link', 'blocked'):
                    raise OSError(errno.ELOOP, 'Resolve this link within the guest')
                if not stat.S_ISDIR(node.st.st_mode):
                    raise OSError(errno.ENOTDIR, 'Not a directory')
                fd = os.open(node.name, DIRECTORY, dir_fd=node.parent)
                opened.append(fd)
                parent = fd
                if node.kind == 'export':
                    boundary, vroot, host_parent = node.boundary, node.virtual_root, node.boundary
                else:
                    host_parent = os.path.join(host_parent, name)
        finally:
            for fd in reversed(opened):
                os.close(fd)

    @staticmethod
    def ordinary(node):
        if node.kind in ('link', 'blocked'):
            raise OSError(errno.ELOOP, 'Resolve this link within the guest')

    def getattr(self, path, fh=None):
        def attributes(s):
            return {k: getattr(s, k) for k in ('st_atime', 'st_ctime', 'st_mtime', 'st_size',
                    'st_mode', 'st_uid', 'st_gid', 'st_nlink')}
        if fh is not None:
            result = attributes(os.fstat(fh))
            result['st_mode'] &= ~(stat.S_ISUID | stat.S_ISGID)
            return result
        with self.node(path) as n:
            result = attributes(n.st)
            # Setuid/setgid bits never cross the shared boundary.
            result['st_mode'] &= ~(stat.S_ISUID | stat.S_ISGID)
            if n.kind in ('link', 'blocked'):
                result.update(st_mode=stat.S_IFLNK | 0o777, st_size=len(os.fsencode(n.target)))
            return result

    def opendir(self, path):
        with self.node(path) as n:
            self.ordinary(n)
            return os.open(n.name, DIRECTORY, dir_fd=n.parent)

    def releasedir(self, path, fh):
        os.close(fh)
        return 0

    def fsyncdir(self, path, datasync, fh):
        os.fsync(fh)
        return 0

    def readdir(self, path, fh=None):
        with self.node(path) as n:
            self.ordinary(n)
            fd = os.open(n.name, DIRECTORY, dir_fd=n.parent)
            try:
                return ['.', '..'] + [s for s in os.listdir(fd) if not s.startswith(PRIVATE_PREFIX)]
            finally:
                os.close(fd)

    def readlink(self, path):
        with self.node(path) as n:
            if n.kind not in ('link', 'blocked'):
                raise OSError(errno.EINVAL, 'Not a symbolic link')
            return n.target

    def open(self, path, flags):
        with self.node(path) as n:
            if flags & os.O_SYMLINK and n.kind in ('link', 'blocked'):
                # Darwin rejects O_SYMLINK combined with O_NOFOLLOW. O_SYMLINK
                # itself opens the link inode, which VirtioFS uses for lstat.
                return self.symlink_fd(n.parent, n.name, flags)
            self.ordinary(n)
            return os.open(n.name, flags | os.O_NOFOLLOW, dir_fd=n.parent)

    def create(self, path, mode, fi=None):
        with self.node(path, missing=True) as n:
            self.ordinary(n)
            return os.open(n.name, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                           mode & 0o777, dir_fd=n.parent)

    def read(self, path, size, offset, fh):
        # O_SYMLINK handles serve lstat only. Never let a raw descriptor read
        # reveal an absolute host link instead of its translated guest target.
        if stat.S_ISLNK(os.fstat(fh).st_mode):
            raise OSError(errno.EINVAL, 'Use readlink for symbolic links')
        return os.pread(fh, size, offset)

    def write(self, path, data, offset, fh):
        if stat.S_ISLNK(os.fstat(fh).st_mode):
            raise OSError(errno.EINVAL, 'Cannot write a symbolic link inode')
        return os.pwrite(fh, data, offset)

    def flush(self, path, fh):
        # close(2) alone does not promise durability; explicit fsync does.
        return 0

    def fsync(self, path, datasync, fh):
        os.fsync(fh)
        return 0

    def release(self, path, fh):
        os.close(fh)
        return 0

    def truncate(self, path, length, fh=None):
        if fh is not None:
            os.ftruncate(fh, length)
        else:
            fd = self.open(path, os.O_WRONLY)
            try:
                os.ftruncate(fd, length)
            finally:
                os.close(fd)
        return 0

    def chmod(self, path, mode):
        fd = self.open(path, os.O_RDONLY)
        try:
            os.fchmod(fd, mode & 0o777)
        finally:
            os.close(fd)
        return 0

    def chown(self, path, uid, gid):
        # The unprivileged host process cannot grant ownership to guest root.
        if uid not in (-1, os.getuid()) or gid not in (-1, os.getgid()):
            raise OSError(errno.EPERM, 'Host ownership is retained')
        return 0

    def utimens(self, path, times=None):
        with self.node(path) as n:
            os.utime(n.name, times, dir_fd=n.parent, follow_symlinks=False)
        return 0

    def mkdir(self, path, mode):
        with self.node(path, missing=True) as n:
            os.mkdir(n.name, mode & 0o777, dir_fd=n.parent)
        return 0

    def unlink(self, path):
        with self.node(path) as n:
            if n.kind == 'export':
                os.unlink(n.alias_name, dir_fd=n.alias_parent)
            else:
                os.unlink(n.name, dir_fd=n.parent)
        return 0

    def rmdir(self, path):
        with self.node(path) as n:
            if n.kind == 'export':
                # Removing an export removes the alias, never its host target.
                os.unlink(n.alias_name, dir_fd=n.alias_parent)
            else:
                os.rmdir(n.name, dir_fd=n.parent)
        return 0

    def symlink(self, target, source):
        # fusepy uses (new path, link contents), unlike os.symlink.
        with self.node(target, missing=True) as n:
            temp = PRIVATE_PREFIX + uuid.uuid4().hex
            os.symlink(source, temp, dir_fd=n.parent)
            try:
                fd = self.symlink_fd(n.parent, temp)
                try:
                    xattr.setxattr(fd, MARKER, b'1')
                finally:
                    os.close(fd)
                # linkat without following creates a second name for the marked
                # symlink and fails if destination exists; publication is atomic.
                os.link(temp, n.name, src_dir_fd=n.parent, dst_dir_fd=n.parent, follow_symlinks=False)
            finally:
                os.unlink(temp, dir_fd=n.parent)
        return 0

    def _has_host_links(self, parent, name):
        info = os.stat(name, dir_fd=parent, follow_symlinks=False)
        if stat.S_ISLNK(info.st_mode):
            return not self.marked(parent, name)
        if stat.S_ISDIR(info.st_mode):
            fd = os.open(name, DIRECTORY, dir_fd=parent)
            try:
                return any(self._has_host_links(fd, s) for s in os.listdir(fd))
            finally:
                os.close(fd)
        return False

    def rename(self, old, new):
        with self.node(old) as src, self.node(new, missing=True) as dst:
            # Moving a host-created relative link (or its parent tree) could
            # accidentally authorize a different target. Host export management
            # belongs to the host; normal guest-created links can move freely.
            if src.kind == 'export' or self._has_host_links(src.parent, src.name):
                raise OSError(errno.EPERM, 'Move host-created links on the host')
            if src.boundary != dst.boundary and stat.S_ISDIR(src.st.st_mode):
                raise OSError(errno.EXDEV, 'Cannot move directories between exports')
            if dst.kind == 'export':
                if not stat.S_ISREG(src.st.st_mode) or not stat.S_ISREG(dst.st.st_mode):
                    raise OSError(errno.EPERM, 'Cannot replace a directory export')
                # An editor's atomic-save rename replaces the selected file,
                # preserving the host symlink that grants access to it.
            os.rename(src.name, dst.name, src_dir_fd=src.parent, dst_dir_fd=dst.parent)
        return 0

    def link(self, target, source):
        with self.node(source) as src, self.node(target, missing=True) as dst:
            if src.kind != 'normal' or not stat.S_ISREG(src.st.st_mode):
                raise OSError(errno.EPERM, 'Only regular shared files can be hard linked')
            if src.boundary != dst.boundary:
                raise OSError(errno.EXDEV, 'Cannot hard link between exports')
            os.link(src.name, dst.name, src_dir_fd=src.parent, dst_dir_fd=dst.parent, follow_symlinks=False)
        return 0

    @contextlib.contextmanager
    def attribute_fd(self, path):
        with self.node(path) as n:
            if stat.S_ISLNK(n.st.st_mode):
                fd = self.symlink_fd(n.parent, n.name)
            else:
                fd = os.open(n.name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=n.parent)
            try:
                yield fd
            finally:
                os.close(fd)

    def listxattr(self, path):
        with self.attribute_fd(path) as fd:
            return [key for key in xattr.listxattr(fd) if key != MARKER]

    def getxattr(self, path, name, position=0):
        if name == MARKER:
            raise OSError(errno.ENOATTR, 'Attribute not found')
        with self.attribute_fd(path) as fd:
            return xattr.getxattr(fd, name)[position:]

    def setxattr(self, path, name, value, options, position=0):
        if name == MARKER or position:
            raise OSError(errno.EPERM, 'Reserved attribute')
        with self.attribute_fd(path) as fd:
            xattr.setxattr(fd, name, value, options=options)
        return 0

    def removexattr(self, path, name):
        if name == MARKER:
            raise OSError(errno.EPERM, 'Reserved attribute')
        with self.attribute_fd(path) as fd:
            xattr.removexattr(fd, name)
        return 0

    def statfs(self, path):
        s = os.fstatvfs(self.root_fd)
        return {key: getattr(s, key) for key in ('f_bsize', 'f_frsize', 'f_blocks', 'f_bfree',
                'f_bavail', 'f_files', 'f_ffree', 'f_favail', 'f_flag', 'f_namemax')}

    def access(self, path, mode):
        self.getattr(path)
        return 0
