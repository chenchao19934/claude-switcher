"""Isolated desktop-update transactions. No network, installed App or real account access."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import tempfile
import threading
import types
import unittest
from unittest import mock
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("desktop_update", ROOT / "core/desktop-update.py")
UPDATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(UPDATE)
REVISION = "a" * 40
CORE = '\n'.join(key + '="' + value + '"' for key, value in zip(
    UPDATE.CONFIG_KEYS, ("clash-verge", "Example Group", "US", "America/New_York", "en_US"))) + '\n# fixture\n'
AUDIT = '\n'.join(key + '=ok' for key in UPDATE.AUDIT_KEYS)


class FakeProcess:
    def __init__(self, exited=False):
        self.exited = exited
        self.terminated = False

    def poll(self):
        return 0 if self.exited else None

    def terminate(self):
        self.terminated = True
        self.exited = True

    def kill(self):
        self.terminate()

    def wait(self, timeout=None):
        self.exited = True
        return 0


class FakeBackend:
    def __init__(self, fixture):
        self.fixture = fixture
        self.audit_output = AUDIT
        self.audit_rc = 0
        self.audit_calls = 0
        self.audit_records = []
        self.fail_installed_audit = False
        self.build_fails = False
        self.launch_fails = False
        self.acknowledge = True
        self.new_process_exits = False
        self.launches = []
        self.ack_errors = []
        self.processes = []
        self.spawned = []
        self.revision = REVISION

    def fetch(self, work):
        source = work / 'download'
        shutil.copytree(self.fixture.source, source)
        entries = UPDATE.verify_manifest(source, source / 'SHA256SUMS')
        return self.revision, source, entries

    def command(self, args, timeout=None):
        if args[:2] != ['/bin/bash', '-n']:
            raise AssertionError('unexpected external command')

    def build(self, source, output, old_app, revision, entries):
        if self.build_fails:
            raise UPDATE.UpdateError('模拟编译失败')
        resources = output / 'Contents/Resources'
        resources.mkdir(parents=True)
        executable = output / 'Contents/MacOS/ClaudeSwitcher'
        executable.parent.mkdir()
        executable.write_text('new executable')
        executable.chmod(0o700)
        info = {'CFBundleIdentifier': 'local.claude-switcher',
                'CFBundleExecutable': 'ClaudeSwitcher',
                'ClaudeSwitcherSourceRevision': revision,
                'ClaudeSwitcherAppSourceSHA256': entries['app/main.swift'],
                'ClaudeSwitcherIconSourceSHA256': entries['assets/icon-2048.png']}
        (output / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        shutil.copyfile(source / 'core/desktop-update.py', resources / 'desktop-update.py')

    def audit(self, core):
        self.audit_calls += 1
        self.audit_records.append((core, self.fixture.stun.read_text() if self.fixture.stun.exists() else None))
        if self.fail_installed_audit and core == self.fixture.core:
            raise UPDATE.UpdateError('模拟新版探针检查失败')
        if not UPDATE.audit_passed(self.audit_output, self.audit_rc):
            raise UPDATE.UpdateError('模拟完整检查失败')
        UPDATE.config_values(core.read_text())

    def launch(self, app, token=None):
        self.launches.append(token)
        phase = UPDATE.read_json(self.fixture.updater.stage_path(token) / 'receipt.json')['phase'] if token else None
        if self.launch_fails and phase == 'awaiting_ack':
            raise UPDATE.UpdateError('模拟启动失败')
        process = FakeProcess(self.new_process_exits if phase == 'awaiting_ack' else False)
        self.processes.append(process)
        if token and (self.acknowledge or phase == 'rolled_back'):
            try:
                self.fixture.updater.ack(token)
            except UPDATE.UpdateError as error:
                # Swift keeps the restarted old UI alive and displays the returned error.
                self.ack_errors.append(str(error))
        return process

    def spawn_worker(self, helper, app, core, token, pid):
        self.spawned.append((helper, app, core, token, pid))
        UPDATE.write_json(helper.parent / 'worker-ready.json', {'token': token, 'version': self.revision[:12]})


class DesktopUpdateTests(unittest.TestCase):
    def setUp(self):
        (ROOT / '_trash').mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix='desktop-updater-', dir=ROOT / '_trash')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.home = self.root / 'home'
        self.core = self.home / '.local/bin/claude-switch.sh'
        self.core.parent.mkdir(parents=True)
        self.core.write_text(CORE)
        self.core.chmod(0o700)
        self.stun = self.home / '.claude-switcher/stun-probe.py'
        self.stun.parent.mkdir()
        self.stun.write_text('old stun')
        self.app = self.home / 'Desktop/Example.app'
        (self.app / 'Contents/MacOS').mkdir(parents=True)
        (self.app / 'Contents/Resources').mkdir()
        (self.app / 'Contents/MacOS/ClaudeSwitcher').write_text('old executable')
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'local.claude-switcher', 'CFBundleExecutable': 'ClaudeSwitcher'}))
        self.source = self.root / 'source'
        for relative in UPDATE.REQUIRED:
            path = self.source / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(CORE if relative == 'core/claude-switch.sh' else 'new ' + relative)
        self.manifest()
        self.backend = FakeBackend(self)
        self.managed = self.root / 'managed'
        self.updater = UPDATE.Updater(self.app, self.core, home=self.home, backend=self.backend,
                                      managed_directory=self.managed)

    def manifest(self, omit=None):
        present = UPDATE.REQUIRED | {'daemons/' + name for name in UPDATE.DAEMON_FILES
                                     if (self.source / 'daemons' / name).is_file()}
        text = ''.join(UPDATE.digest(self.source / name) + '  ' + name + '\n'
                       for name in sorted(present - ({omit} if omit else set())))
        (self.source / 'SHA256SUMS').write_text(text)

    def installed(self):
        return self.updater.originals()

    def prepare(self):
        result = self.updater.prepare()
        self.assertEqual(result['state'], 'prepared')
        self.assertFalse((self.stun.parent / '.update.lock').exists())
        return result['token']

    def worker(self, token, **kwargs):
        with mock.patch.object(UPDATE, 'alive', return_value=True):
            result = self.updater.apply(token, 54321)
        self.assertEqual(result['state'], 'restarting')
        with mock.patch.object(UPDATE, 'alive', return_value=False):
            self.updater.worker(token, 54321, exit_timeout=.02, ack_timeout=.03, interval=.001, **kwargs)
        return UPDATE.read_json(self.updater.stage_path(token) / 'result.json')

    def test_check_is_read_only(self):
        before = self.installed()
        snapshot = {str(p.relative_to(self.home)): (p.stat().st_mode, p.stat().st_mtime_ns,
                    p.read_bytes() if p.is_file() else None) for p in self.home.rglob('*')}
        result = self.updater.check()
        self.assertEqual(result['state'], 'available')
        self.assertEqual(before, self.installed())
        self.assertEqual(snapshot, {str(p.relative_to(self.home)): (p.stat().st_mode, p.stat().st_mtime_ns,
                    p.read_bytes() if p.is_file() else None) for p in self.home.rglob('*')})

    def test_gui_only_change_is_available(self):
        token = self.prepare()
        self.assertEqual(self.worker(token)['state'], 'updated')
        self.assertEqual(self.updater.check()['state'], 'current')
        (self.source / 'app/main.swift').write_text('GUI only change')
        self.manifest()
        self.assertEqual(self.updater.check()['state'], 'available')

    def test_prepare_keeps_installed_files_and_private_receipt(self):
        before = self.installed()
        token = self.prepare()
        self.assertEqual(self.installed(), before)
        stage = self.updater.stage_path(token)
        self.assertEqual(stat.S_IMODE(stage.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((stage / 'receipt.json').stat().st_mode), 0o600)
        self.assertNotIn('Example Group', (stage / 'receipt.json').read_text())

    def test_successful_transaction_and_backup(self):
        before = self.installed()
        token = self.prepare()
        self.assertEqual(self.worker(token)['state'], 'updated')
        self.assertNotEqual(self.installed(), before)
        stage = self.updater.stage_path(token)
        self.assertEqual(UPDATE.tree_digest(stage / 'previous-app.app'), before['app'])
        self.assertEqual(UPDATE.digest(stage / 'previous-core.sh'), before['core'])
        self.assertEqual(UPDATE.digest(stage / 'previous-stun.py'), before['stun'])
        self.assertEqual(UPDATE.config_values(self.core.read_text()), UPDATE.config_values(CORE))
        self.assertFalse((self.stun.parent / '.update.lock').exists())

    def test_start_failure_rolls_back_all_components(self):
        before = self.installed()
        token = self.prepare()
        self.backend.launch_fails = True
        self.assertEqual(self.worker(token)['state'], 'error')
        self.assertEqual(self.installed(), before)
        self.assertEqual(self.backend.launches, [token, token])
        self.assertEqual(self.backend.ack_errors, ['更新失败，已恢复旧版本'])
        self.assertFalse((self.updater.stage_path(token) / 'ack.json').exists())

    def test_no_ack_rolls_back_and_terminates_new_app(self):
        before = self.installed()
        token = self.prepare()
        self.backend.acknowledge = False
        self.assertEqual(self.worker(token)['state'], 'error')
        self.assertEqual(self.installed(), before)
        self.assertTrue(self.backend.processes[0].terminated)
        with self.assertRaises(UPDATE.UpdateError):
            self.updater.ack(token)

    def test_new_process_exit_rolls_back(self):
        before = self.installed()
        token = self.prepare()
        self.backend.acknowledge = False
        self.backend.new_process_exits = True
        self.assertEqual(self.worker(token)['state'], 'error')
        self.assertEqual(self.installed(), before)

    def test_prepare_build_or_audit_failure_never_replaces(self):
        before = self.installed()
        for kind in ('build', 'audit'):
            with self.subTest(kind=kind):
                self.backend.build_fails = kind == 'build'
                self.backend.audit_rc = 7 if kind == 'audit' else 0
                with self.assertRaises(UPDATE.UpdateError):
                    self.updater.prepare()
                self.assertEqual(self.installed(), before)
                self.assertFalse(list(self.app.parent.glob('.claude-switcher-update-*')))
                self.assertFalse((self.stun.parent / '.update.lock').exists())

    def test_manifest_missing_required_or_modified_file_is_rejected(self):
        for relative in UPDATE.REQUIRED:
            self.manifest(omit=relative)
            with self.assertRaises(UPDATE.UpdateError):
                self.updater.check()
        self.manifest()
        (self.source / 'core/stun-probe.py').write_text('tampered')
        with self.assertRaises(UPDATE.UpdateError):
            self.updater.prepare()

    def test_manifest_rejects_duplicate_and_unsafe_paths(self):
        valid = (self.source / 'SHA256SUMS').read_text()
        for extra in (valid.splitlines()[0], '0' * 64 + '  ../escape', '0' * 64 + '  /absolute'):
            (self.source / 'SHA256SUMS').write_text(valid + extra + '\n')
            with self.assertRaises(UPDATE.UpdateError):
                self.updater.check()

    def test_literal_config_round_trip_with_quotes_backslashes_and_dollars(self):
        values = {'PROXY_GROUP': 'quote " and backslash \\ and literal $HOME `x`'}
        source = CORE
        for key, value in values.items():
            escaped = ''.join('\\' + c if c in '$`"\\' else c for c in value)
            source = source.replace(key + '="Example Group"', key + '="' + escaped + '"')
        self.assertEqual(UPDATE.config_values(source)['PROXY_GROUP'], values['PROXY_GROUP'])
        injected = UPDATE.inject_config(CORE, source)
        self.assertEqual(UPDATE.config_values(injected)['PROXY_GROUP'], values['PROXY_GROUP'])
        self.core.write_text(source)
        token = self.prepare()
        self.assertEqual(self.worker(token)['state'], 'updated')
        self.assertEqual(UPDATE.config_values(self.core.read_text())['PROXY_GROUP'], values['PROXY_GROUP'])

    def test_dynamic_or_duplicate_config_is_rejected(self):
        for source in (CORE.replace('Example Group', '$(touch /no)'), CORE + 'COUNTRY_TARGET="JP"\n'):
            with self.assertRaises(UPDATE.UpdateError):
                UPDATE.inject_config(CORE, source)

    def test_audit_requires_complete_unique_allowed_rows_and_zero_exit(self):
        self.assertTrue(UPDATE.audit_passed(AUDIT, 0))
        for text, rc in ((AUDIT, 1), ('', 0), (AUDIT.rsplit('\n', 1)[0], 0),
                         (AUDIT + '\n代理内核=ok', 0), (AUDIT.replace('TUN网卡=ok', 'TUN网卡=warn:old'), 0),
                         (AUDIT.replace('TUN网卡=ok', 'TUN网卡=skip'), 0),
                         (AUDIT.replace('TUN网卡=ok', 'TUN网卡=fail'), 0),
                         (AUDIT.replace('TUN网卡=ok', 'TUN网卡=unknown'), 0)):
            self.assertFalse(UPDATE.audit_passed(text, rc))
        self.assertTrue(UPDATE.audit_passed(AUDIT.replace('DNS=ok', 'DNS=skip'), 0))

    def test_existing_lock_is_never_removed(self):
        lock = self.stun.parent / '.update.lock'
        lock.mkdir(mode=0o700)
        (lock / 'pid').write_text('999999\n')
        (lock / 'nonce').write_text('someone-else\n')
        with self.assertRaises(UPDATE.UpdateError):
            self.updater.prepare()
        self.assertEqual((lock / 'nonce').read_text(), 'someone-else\n')

    def test_lock_protocol_and_foreign_owner_not_deleted(self):
        lock = UPDATE.UpdateLock(self.home)
        with lock:
            self.assertEqual((lock.path / 'pid').read_text(), str(os.getpid()) + '\n')
            self.assertRegex((lock.path / 'nonce').read_text(), r'^[0-9a-f]{32}\n$')
            (lock.path / 'nonce').write_text('changed\n')
        self.assertTrue(lock.path.exists())

    def test_symlink_targets_rejected(self):
        outside = self.root / 'outside'
        self.core.rename(outside)
        self.core.symlink_to(outside)
        with self.assertRaises(UPDATE.UpdateError):
            self.updater.check()

    def test_archive_traversal_symlink_and_duplicate_rejected(self):
        for name, link, duplicate in (('../escape', False, False), ('/absolute', False, False),
                                      ('root/link', True, False), ('root/file', False, True)):
            archive = self.root / 'archive.zip'
            with zipfile.ZipFile(archive, 'w') as handle:
                info = zipfile.ZipInfo(name)
                if link:
                    info.external_attr = (stat.S_IFLNK | 0o777) << 16
                handle.writestr(info, 'fixture')
                if duplicate:
                    import warnings
                    with warnings.catch_warnings():
                        warnings.simplefilter('ignore')
                        handle.writestr(info, 'duplicate')
            with self.assertRaises(UPDATE.UpdateError):
                UPDATE.safe_extract(archive, self.root / 'extract')
            self.assertFalse((self.root / 'extract').exists())

    def test_prepare_then_changed_install_or_stage_refuses_apply(self):
        token = self.prepare()
        self.core.write_text(CORE + '# user change\n')
        with mock.patch.object(UPDATE, 'alive', return_value=True), self.assertRaises(UPDATE.UpdateError):
            self.updater.apply(token, 54321)
        self.assertFalse(self.backend.spawned)
        self.core.write_text(CORE)
        (self.updater.stage_path(token) / 'new-core.sh').write_text('tampered')
        with mock.patch.object(UPDATE, 'alive', return_value=True), self.assertRaises(UPDATE.UpdateError):
            self.updater.apply(token, 54321)

    def test_duplicate_apply_and_replayed_ack_refused(self):
        token = self.prepare()
        with mock.patch.object(UPDATE, 'alive', return_value=True):
            self.updater.apply(token, 54321)
            with self.assertRaises(UPDATE.UpdateError):
                self.updater.apply(token, 54321)
        with mock.patch.object(UPDATE, 'alive', return_value=False):
            self.updater.worker(token, 54321, interval=.001)
        with self.assertRaises(UPDATE.UpdateError):
            self.updater.ack(token)
        self.assertEqual(len(self.backend.spawned), 1)

    def test_late_ack_and_expired_receipt_refused(self):
        token = self.prepare()
        stage, record = self.updater.receipt(token)
        record['phase'] = 'awaiting_ack'
        record['ackDeadline'] = 0
        UPDATE.write_json(stage / 'receipt.json', record)
        with self.assertRaises(UPDATE.UpdateError):
            self.updater.ack(token)
        record['created'] = 0
        UPDATE.write_json(stage / 'receipt.json', record)
        with self.assertRaises(UPDATE.UpdateError):
            self.updater.receipt(token)

    def test_widget_app_refuses_signature_downgrade(self):
        (self.app / 'Contents/PlugIns').mkdir()
        with self.assertRaises(UPDATE.UpdateError):
            self.updater.check()

    def test_rollback_receipt_reports_failure_without_acknowledging(self):
        token = self.prepare()
        stage, record = self.updater.receipt(token)
        for phase, expected in (('rolled_back', '已恢复旧版本'), ('rollback_failed', '请手动恢复')):
            record['phase'] = phase
            UPDATE.write_json(stage / 'receipt.json', record)
            with self.assertRaises(UPDATE.UpdateError) as raised:
                self.updater.ack(token)
            self.assertIn(expected, str(raised.exception))
            self.assertFalse((stage / 'ack.json').exists())

    def managed_components(self):
        self.managed.mkdir()
        templates = {'claude-bodyguard.sh': 'HOME="__HOME__"\nMODE="__PROXY_MODE__"\n',
                     'tz-watchdog.sh': 'HOME="__HOME__"\nTARGET="__TZ_TARGET__"\n',
                     'bodyguard-settings.py': '# root helper fixture\n'}
        for name, text in templates.items():
            source = self.source / 'daemons' / name
            source.parent.mkdir(exist_ok=True)
            source.write_text(text)
            expected = text.replace('__HOME__', str(self.home)).replace('__PROXY_MODE__', 'clash-verge').replace('__TZ_TARGET__', 'America/New_York')
            (self.managed / name).write_text(expected)
        self.manifest()

    def test_changed_daemons_notice_survives_prepare_and_ack_without_writes(self):
        self.managed_components()
        (self.managed / 'tz-watchdog.sh').write_text('old version\n')
        before = {p.name: (p.read_bytes(), p.stat().st_mtime_ns, p.stat().st_mode) for p in self.managed.iterdir()}
        self.assertIn(UPDATE.DAEMON_CHANGED, self.updater.check()['message'])
        prepared = self.updater.prepare()
        self.assertIn(UPDATE.DAEMON_CHANGED, prepared['message'])
        token = prepared['token']
        _, record = self.updater.receipt(token)
        self.assertEqual(record['notice'], UPDATE.DAEMON_CHANGED)
        self.assertEqual(self.worker(token)['state'], 'updated')
        # Fake launch already called ack; inspect its safe completion message by replaying an awaiting receipt.
        stage, record = self.updater.receipt(token)
        record['phase'] = 'awaiting_ack'
        record['ackDeadline'] = UPDATE.time.time() + 10
        UPDATE.write_json(stage / 'receipt.json', record)
        (stage / 'ack.json').unlink()
        self.assertIn(UPDATE.DAEMON_CHANGED, self.updater.ack(token)['message'])
        self.assertEqual(before, {p.name: (p.read_bytes(), p.stat().st_mtime_ns, p.stat().st_mode) for p in self.managed.iterdir()})
        self.assertNotIn('Example Group', prepared['message'])
        self.assertNotIn(str(self.managed), prepared['message'])

    def test_matching_daemons_have_no_notice_and_missing_manifest_only_warns(self):
        self.managed_components()
        before = {p.name: (p.read_bytes(), p.stat().st_mtime_ns, p.stat().st_mode) for p in self.managed.iterdir()}
        result = self.updater.check()
        self.assertNotIn('系统守护组件', result['message'])
        self.manifest(omit='daemons/bodyguard-settings.py')
        self.assertIn(UPDATE.DAEMON_UNKNOWN, self.updater.check()['message'])
        self.manifest()
        (self.managed / 'claude-bodyguard.sh').unlink()
        self.assertIn(UPDATE.DAEMON_MISSING, self.updater.check()['message'])
        # The deletion above is the fixture's action; updater never recreates it.
        self.assertFalse((self.managed / 'claude-bodyguard.sh').exists())
        for name in ('tz-watchdog.sh', 'bodyguard-settings.py'):
            item = self.managed / name
            self.assertEqual(before[name], (item.read_bytes(), item.stat().st_mtime_ns, item.stat().st_mode))

    def test_missing_stun_is_installed_and_removed_on_rollback(self):
        self.stun.unlink()
        token = self.prepare()
        self.backend.acknowledge = False
        self.assertEqual(self.worker(token)['state'], 'error')
        self.assertFalse(self.stun.exists())

    def test_worker_checks_new_probe_before_launch_and_rolls_back(self):
        before = self.installed()
        token = self.prepare()
        self.backend.fail_installed_audit = True
        self.assertEqual(self.worker(token)['state'], 'error')
        self.assertEqual(self.installed(), before)
        self.assertEqual(self.backend.launches, [token])
        self.assertEqual(self.backend.audit_calls, 2)
        self.assertEqual(self.backend.audit_records[0][0], self.updater.stage_path(token) / 'new-core.sh')
        self.assertEqual(self.backend.audit_records[0][1], 'old stun')
        self.assertEqual(self.backend.audit_records[1], (self.core, 'new core/stun-probe.py'))

    def test_apply_waits_for_real_worker_ready_before_returning(self):
        token = self.prepare()
        exited = threading.Event()
        threads = []
        def spawn(helper, app, core, actual_token, pid):
            worker = threading.Thread(target=self.updater.worker, args=(actual_token, pid),
                                      kwargs={'interval': .001, 'ack_timeout': .1})
            worker.start()
            threads.append(worker)
        self.backend.spawn_worker = spawn
        with mock.patch.object(UPDATE, 'alive', side_effect=lambda _: not exited.is_set()):
            result = self.updater.apply(token, 54321)
            self.assertEqual(result['state'], 'restarting')
            stage, record = self.updater.receipt(token)
            self.assertEqual(record['phase'], 'waiting_for_exit')
            self.assertTrue((stage / 'worker-ready.json').exists())
            self.assertTrue((self.stun.parent / '.update.lock').is_dir())
            exited.set()
            threads[0].join(timeout=2)
            self.assertFalse(threads[0].is_alive())
        self.assertEqual(UPDATE.read_json(stage / 'result.json')['state'], 'updated')

    def test_apply_without_worker_ready_keeps_app_and_marks_cancel(self):
        before = self.installed()
        token = self.prepare()
        self.backend.spawn_worker = lambda *args: None
        with mock.patch.object(UPDATE, 'alive', return_value=True), self.assertRaises(UPDATE.UpdateError):
            self.updater.apply(token, 54321, ready_timeout=.01)
        self.assertEqual(self.installed(), before)
        self.assertTrue((self.updater.stage_path(token) / 'cancel.json').exists())
        self.assertFalse(self.backend.launches)

    def test_swap_failure_rolls_back_prior_core_and_probe(self):
        before = self.installed()
        token = self.prepare()
        replace = UPDATE.os.replace
        def fail_app_swap(source, destination):
            if Path(source).name == 'new-app.app':
                raise OSError('simulated disk failure')
            return replace(source, destination)
        with mock.patch.object(UPDATE.os, 'replace', side_effect=fail_app_swap):
            self.assertEqual(self.worker(token)['state'], 'error')
        self.assertEqual(self.installed(), before)
        self.assertEqual(self.backend.launches, [token])

    def test_worker_validation_failure_reopens_old_app_after_exit(self):
        token = self.prepare()
        with mock.patch.object(UPDATE, 'alive', return_value=True):
            self.updater.apply(token, 54321)
        self.core.write_text(CORE + '# changed after preparation\n')
        with mock.patch.object(UPDATE, 'alive', return_value=False):
            self.updater.worker(token, 54321, interval=.001)
        self.assertEqual(self.backend.launches, [token])
        self.assertTrue(self.core.read_text().endswith('# changed after preparation\n'))
        self.assertFalse((self.stun.parent / '.update.lock').exists())

    def test_cross_volume_install_refused_before_build(self):
        original_stat = UPDATE.Path.stat
        def fake_stat(path, *args, **kwargs):
            value = original_stat(path, *args, **kwargs)
            if path == self.app.parent:
                return types.SimpleNamespace(st_mode=value.st_mode, st_uid=value.st_uid,
                                             st_dev=value.st_dev + 1)
            return value
        with mock.patch.object(UPDATE.Path, 'stat', fake_stat), self.assertRaises(UPDATE.UpdateError):
            self.updater.prepare()
        self.assertFalse(list(self.app.parent.glob('.claude-switcher-update-*')))

    def test_failed_lock_creation_cleans_own_partial_files(self):
        original_open = UPDATE.os.open
        def fail_nonce(path, flags, mode=0o777, *args, **kwargs):
            if str(path).endswith('/nonce'):
                raise OSError('simulated no space')
            return original_open(path, flags, mode, *args, **kwargs)
        with mock.patch.object(UPDATE.os, 'open', side_effect=fail_nonce), self.assertRaises(OSError):
            with UPDATE.UpdateLock(self.home):
                self.fail('should not acquire partially written lock')
        self.assertFalse((self.stun.parent / '.update.lock').exists())

    def test_http_only_environment_proxy_is_used_for_https(self):
        backend = UPDATE.Backend()
        for key in ('http_proxy', 'HTTP_PROXY'):
            with mock.patch.dict(os.environ, {key: 'http://configured'}, clear=True), mock.patch.object(UPDATE.subprocess, 'run') as run:
                self.assertEqual(backend.proxy_environment()['https_proxy'], 'http://configured')
                run.assert_not_called()

    def test_termination_signal_releases_lock(self):
        old_handler = UPDATE.signal.signal(UPDATE.signal.SIGTERM, UPDATE.interrupted)
        try:
            with self.assertRaises(UPDATE.UpdateError):
                with UPDATE.UpdateLock(self.home):
                    os.kill(os.getpid(), UPDATE.signal.SIGTERM)
            self.assertFalse((self.stun.parent / '.update.lock').exists())
        finally:
            UPDATE.signal.signal(UPDATE.signal.SIGTERM, old_handler)

    def test_pending_signal_after_lock_creation_releases_lock(self):
        calls = 0
        original = UPDATE.signal.pthread_sigmask
        def pending_signal(how, signals):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise UPDATE.UpdateError('simulated pending signal')
            return set()
        with mock.patch.object(UPDATE.signal, 'pthread_sigmask', side_effect=pending_signal):
            with self.assertRaises(UPDATE.UpdateError):
                with UPDATE.UpdateLock(self.home):
                    self.fail('pending signal should cancel before context entry')
        self.assertFalse((self.stun.parent / '.update.lock').exists())

    def test_download_classifies_failures_without_raw_details(self):
        backend = UPDATE.Backend()
        target = self.root / 'download'
        for code, status, expected in ((22, b'403', 'HTTP 403'), (35, b'000', 'TLS'),
                                        (6, b'000', '解析失败'), (28, b'000', '超时')):
            result = mock.Mock(returncode=code, stdout=status, stderr=b'203.0.113.10 password=secret')
            with mock.patch.object(backend, 'proxy_environment', return_value={}), mock.patch.object(UPDATE.subprocess, 'run', return_value=result):
                with self.assertRaises(UPDATE.UpdateError) as raised:
                    backend.download('https://example.invalid/source', target, 100)
            self.assertIn(expected, str(raised.exception))
            self.assertNotIn('203.0.113', str(raised.exception))
            self.assertNotIn('secret', str(raised.exception))

    def test_proxy_environment_uses_enabled_system_proxy_without_printing(self):
        backend = UPDATE.Backend()
        output = 'HTTPEnable : 1\nHTTPProxy : localhost\nHTTPPort : 1087\n'
        result = mock.Mock(stdout=output)
        with mock.patch.dict(os.environ, {}, clear=True), mock.patch.object(UPDATE.subprocess, 'run', return_value=result):
            env = backend.proxy_environment()
            self.assertEqual(env['https_proxy'], 'http://localhost:1087')
        with mock.patch.dict(os.environ, {'HTTPS_PROXY': 'http://configured'}, clear=True), mock.patch.object(UPDATE.subprocess, 'run') as run:
            self.assertEqual(backend.proxy_environment()['HTTPS_PROXY'], 'http://configured')
            run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
