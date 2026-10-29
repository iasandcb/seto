import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import select
import stat
import subprocess
import tempfile
import unittest
import uuid
from unittest.mock import patch

HELPER = Path(__file__).resolve().parents[1] / 'seto'
loader = importlib.machinery.SourceFileLoader('seto', str(HELPER))
spec = importlib.util.spec_from_loader(loader.name, loader)
seto = importlib.util.module_from_spec(spec)
loader.exec_module(seto)


class Files(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def document(self, path):
        doc = seto.Document(str(path))
        self.addCleanup(doc.close)
        return doc

    def test_new_unicode_space_name_only_created_on_save(self):
        path = self.root / "새 문서 ' $(touch NEVER).md"
        doc = self.document(path)
        self.assertEqual((doc.content, doc.version), ('', 'missing'))
        self.assertFalse(path.exists())
        version = doc.save('missing', '한글\r\nwithout final newline')
        self.assertNotEqual(version, 'missing')
        self.assertEqual(path.read_bytes(), '한글\r\nwithout final newline'.encode())
        self.assertEqual(list(self.root.iterdir()), [path])

    def test_empty_new_file_is_created_and_cooperating_writers_are_locked(self):
        path = self.root / 'empty'
        doc = self.document(path)
        other = self.document(path)
        seto.fcntl.flock(doc.dirfd, seto.fcntl.LOCK_EX | seto.fcntl.LOCK_NB)
        try:
            with self.assertRaises(seto.FileError) as caught:
                other.save('missing', 'other')
            self.assertEqual(caught.exception.code, 'busy')
        finally:
            seto.fcntl.flock(doc.dirfd, seto.fcntl.LOCK_UN)
        doc.save('missing', '')
        self.assertEqual(path.read_bytes(), b'')
        with self.assertRaises(seto.FileError):
            other.save('missing', 'other')

    def test_mode_and_xattr_preserved_and_file_replaced(self):
        path = self.root / 'existing'
        path.write_text('old')
        path.chmod(0o640)
        has_xattr = hasattr(os, 'setxattr')
        if has_xattr:
            try:
                os.setxattr(path, 'user.seto-test', b'metadata')
            except OSError:
                has_xattr = False
        doc = self.document(path)
        inode = path.stat().st_ino
        doc.save(doc.version, 'new')
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o640)
        self.assertNotEqual(inode, path.stat().st_ino)
        if has_xattr:
            self.assertEqual(os.getxattr(path, 'user.seto-test'), b'metadata')

    def test_external_change_delete_and_same_content_replacement_conflict(self):
        for change in ('edit', 'delete', 'replace'):
            path = self.root / change
            path.write_text('original')
            doc = self.document(path)
            if change == 'edit':
                path.write_text('external')
            elif change == 'delete':
                path.unlink()
            else:
                temp = self.root / 'other'
                temp.write_text('original')
                temp.replace(path)
            with self.assertRaises(seto.FileError) as caught:
                doc.save(doc.version, 'mine')
            self.assertEqual(caught.exception.code, 'conflict')
            self.assertFalse(path.exists() and path.read_text() == 'mine')

    def test_new_file_created_by_other_writer_is_never_replaced(self):
        path = self.root / 'new'
        doc = self.document(path)
        real_link = os.link
        def racing_link(*args, **kwargs):
            path.write_text('created elsewhere')
            return real_link(*args, **kwargs)
        with patch.object(os, 'link', racing_link), self.assertRaises(seto.FileError):
            doc.save('missing', 'mine')
        self.assertEqual(path.read_text(), 'created elsewhere')
        self.assertEqual(list(self.root.iterdir()), [path])

    def test_change_while_writing_temporary_file_is_detected(self):
        path = self.root / 'existing'
        path.write_text('before')
        doc = self.document(path)
        real_fsync = os.fsync
        def mutate(fd):
            path.write_text('elsewhere')
            return real_fsync(fd)
        with patch.object(os, 'fsync', mutate), self.assertRaises(seto.FileError):
            doc.save(doc.version, 'mine')
        self.assertEqual(path.read_text(), 'elsewhere')

    def test_no_ack_on_fsync_failure_and_original_preserved(self):
        path = self.root / 'existing'
        path.write_text('before')
        doc = self.document(path)
        with patch.object(os, 'fsync', side_effect=OSError('disk error')), self.assertRaises(OSError):
            doc.save(doc.version, 'mine')
        self.assertEqual(path.read_text(), 'before')
        self.assertEqual(list(self.root.iterdir()), [path])

    def test_non_utf8_nul_large_and_non_regular_files_rejected(self):
        for name, raw in [('invalid', b'\xff'), ('binary', b'a\0b'), ('large', b'a' * (seto.LIMIT + 1))]:
            path = self.root / name
            path.write_bytes(raw)
            with self.assertRaises(seto.FileError):
                self.document(path)
        path = self.root / 'directory'
        path.mkdir()
        with self.assertRaises(seto.FileError):
            self.document(path)
        fifo = self.root / 'fifo'
        os.mkfifo(fifo)
        with self.assertRaises(seto.FileError):
            self.document(fifo)

    def test_links_rejected_parent_symlink_resolved(self):
        real = self.root / 'real'
        real.write_text('a')
        link = self.root / 'symbolic'
        link.symlink_to(real)
        with self.assertRaises(seto.FileError):
            self.document(link)
        hard = self.root / 'hard'
        os.link(real, hard)
        with self.assertRaises(seto.FileError):
            self.document(hard)
        hard.unlink()
        parent = self.root / 'parent'
        parent.symlink_to(self.root, target_is_directory=True)
        self.assertEqual(self.document(parent / 'real').path, str(real.resolve()))

    def test_missing_parent_and_readonly(self):
        with self.assertRaises(FileNotFoundError):
            self.document(self.root / 'missing' / 'file')
        path = self.root / 'readonly'
        path.write_text('old')
        for mode in (0o400, 0o460):
            path.chmod(mode)
            doc = self.document(path)
            with self.assertRaises(PermissionError):
                doc.save(doc.version, 'new')
        self.assertEqual(path.read_text(), 'old')

    def test_parent_path_replacement_rejected(self):
        parent = self.root / 'dir'
        parent.mkdir()
        path = parent / 'file'
        path.write_text('old')
        doc = self.document(path)
        parent.rename(self.root / 'moved')
        parent.mkdir()
        with self.assertRaises(seto.FileError):
            doc.save(doc.version, 'mine')
        self.assertEqual((self.root / 'moved' / 'file').read_text(), 'old')


class Bridge(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.env = dict(os.environ, SSH_CONNECTION='test-' + uuid.uuid4().hex)
        self.session = uuid.uuid4().hex
        self.process = subprocess.Popen([str(HELPER), '--bridge'], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=self.env)
        self.addCleanup(self.shutdown)
        self.process.stdin.write(seto.encode({'session': self.session}))
        self.process.stdin.flush()
        self.assertEqual(self.receive()['type'], 'ready')

    def shutdown(self):
        if self.process.poll() is None:
            self.process.stdin.close()
            self.process.wait(timeout=5)
        self.process.stdin.close()
        self.process.stdout.close()
        self.process.stderr.close()

    def receive(self):
        self.assertTrue(select.select([self.process.stdout], [], [], 5)[0], 'bridge response timed out')
        message = json.loads(self.process.stdout.readline())
        self.assertEqual(message['session'], self.session)
        self.assertEqual(message['v'], 1)
        return message

    def send(self, message):
        message.update(v=1, session=self.session)
        raw = seto.encode(message)
        # Deliberately split a JSON record across writes.
        for chunk in (raw[:4], raw[4:]):
            self.process.stdin.write(chunk)
            self.process.stdin.flush()

    def cli(self, name, env=None):
        return subprocess.run([str(HELPER), '--', name], cwd=self.temp.name,
                              env=env or self.env, capture_output=True, timeout=5)

    def test_end_to_end_relative_path_new_save_ack_conflict_close_and_reopen(self):
        result = self.cli('공백 있는 $(echo unsafe).md')
        self.assertEqual(result.returncode, 0, result.stderr)
        opened = self.receive()
        self.assertEqual(opened['type'], 'open')
        self.assertEqual(opened['version'], 'missing')
        self.assertEqual(Path(opened['path']).parent, Path(self.temp.name).resolve())
        self.assertFalse(Path(opened['path']).exists())
        self.assertNotEqual(self.cli('busy.md').returncode, 0)
        self.send(dict(type='save', id='one', path=opened['path'], version='missing', content='각\n'))
        ack = self.receive()
        self.assertEqual((ack['type'], ack['id']), ('saved', 'one'))
        self.assertEqual(Path(opened['path']).read_text(), '각\n')
        Path(opened['path']).write_text('external')
        self.send(dict(type='save', id='two', path=opened['path'], version=ack['version'], content='mine'))
        self.assertEqual(self.receive()['code'], 'conflict')
        self.assertEqual(Path(opened['path']).read_text(), 'external')
        self.send(dict(type='close', id='three'))
        self.assertEqual(self.receive()['type'], 'closed')
        self.assertEqual(self.cli('busy.md').returncode, 0)
        self.assertEqual(self.receive()['type'], 'open')

    def test_double_dash_allows_option_like_filename(self):
        self.assertEqual(self.cli('--help').returncode, 0)
        self.assertEqual(Path(self.receive()['path']).name, '--help')

    def test_relative_dotdot_after_symlink_uses_filesystem_semantics(self):
        root = Path(self.temp.name)
        (root / 'physical' / 'nested').mkdir(parents=True)
        (root / 'link').symlink_to(root / 'physical' / 'nested', target_is_directory=True)
        (root / 'physical' / 'target').write_text('correct')
        (root / 'target').write_text('incorrect lexical normalization')
        self.assertEqual(self.cli('link/../target').returncode, 0)
        opened = self.receive()
        self.assertEqual(opened['content'], 'correct')
        self.assertEqual(opened['path'], str((root / 'physical' / 'target').resolve()))

    def test_different_transport_cannot_route_request(self):
        other = dict(self.env, SSH_CONNECTION='other-' + uuid.uuid4().hex)
        self.assertNotEqual(self.cli('test.md', env=other).returncode, 0)
        self.assertFalse(select.select([self.process.stdout], [], [], 0.1)[0])

    def test_wrong_session_cannot_save(self):
        self.assertEqual(self.cli('new').returncode, 0)
        opened = self.receive()
        self.process.stdin.write(seto.encode(dict(v=1, session=uuid.uuid4().hex, type='save',
                                                   path=opened['path'], version='missing', content='bad')))
        self.process.stdin.flush()
        self.process.wait(timeout=5)
        self.assertNotEqual(self.process.returncode, 0)
        self.assertFalse(Path(opened['path']).exists())

    def test_disconnect_removes_socket_and_stale_cli_fails(self):
        with patch.dict(os.environ, self.env):
            record = Path(seto.connection_record())
            path = Path(seto.socket_path(self.session))
        self.assertTrue(record.exists())
        self.shutdown()
        self.assertFalse(record.exists())
        self.assertFalse(path.exists())
        self.assertNotEqual(self.cli('new').returncode, 0)


if __name__ == '__main__':
    unittest.main()
