#!/usr/bin/env python3
"""Atomic file writes: write a temp file next to the target, fsync, rename.

A crash, a kill or a full disk while writing can otherwise leave
serverDZ.cfg or a CE XML truncated, and the server will not start from
a half file. With a rename the old file stays intact until the new one
is complete.
"""
import os
import tempfile


def atomic_write(path, write_fn):
    """Call write_fn(binary_file) on a temp file, then move it over `path`.

    The temp file is created in the same directory so os.replace is a
    plain rename on the same filesystem. File permissions of an existing
    target are preserved.
    """
    directory = os.path.dirname(os.path.abspath(path)) or '.'
    fd, tmp_path = tempfile.mkstemp(prefix='.' + os.path.basename(path) + '.', suffix='.tmp', dir=directory)
    try:
        with os.fdopen(fd, 'wb') as f:
            write_fn(f)
            f.flush()
            os.fsync(f.fileno())
        try:
            os.chmod(tmp_path, os.stat(path).st_mode & 0o7777)
        except FileNotFoundError:
            pass  # new file: keep the default mode
        os.replace(tmp_path, path)
    except BaseException:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def atomic_write_text(path, text, encoding='utf-8'):
    """Replace the content of `path` with `text` atomically."""
    atomic_write(path, lambda f: f.write(text.encode(encoding)))


def atomic_write_tree(tree, path, **write_kwargs):
    """ElementTree.write() into a temp file, then rename it over `path`."""
    atomic_write(path, lambda f: tree.write(f, **write_kwargs))
