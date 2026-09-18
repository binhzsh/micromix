import hashlib
import json
import subprocess
from pathlib import Path
import sys
import tempfile
import threading
from unittest.mock import patch
import time
import unittest

from local_inference.runtime import Runtime

WORKER = '''import json, pathlib, sys, time
m=json.loads(pathlib.Path(sys.argv[1]).read_text())
p=m['parameters']
if p.get('sleep'): time.sleep(p['sleep'])
out=pathlib.Path(m['output_dir'])
f=out/'audio.wav'; f.write_bytes(b'audio')
outputs=[dict(path=str(f),filename='audio.wav',media_type='audio/wav',name='audio')]
if p.get('bad_output'): outputs.append(dict(path=str(out/'missing'),filename='bad',media_type='audio/wav',name='bad'))
(out/'result.json').write_text(json.dumps(dict(outputs=outputs,provenance={'seed':p.get('seed')})))
'''


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.runtime = Runtime(self.root, lambda manifest: [sys.executable, '-c', WORKER, str(manifest)])

    def tearDown(self):
        self.runtime.close()
        self.temp.cleanup()

    def wait(self, job_id, states=('succeeded', 'failed', 'cancelled')):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            job = self.runtime.get_job(job_id)
            if job['state'] in states:
                return job
            time.sleep(.02)
        self.fail(f'Job never reached {states}: {job}')

    def test_persists_assets_links_and_seed_across_reopen(self):
        asset = self.runtime.add_asset(b'source', '../source.wav', 'audio/wav')
        job = self.runtime.submit('generate', {'seed': 42}, [{'name': 'source', 'position': 0, 'asset': asset}])
        self.runtime.close()
        self.runtime = Runtime(self.root)
        restored = self.runtime.get_job(job['id'])
        self.assertEqual(restored['parameters']['seed'], 42)
        self.assertEqual(restored['inputs'][0]['asset']['sha256'], hashlib.sha256(b'source').hexdigest())
        self.assertEqual(self.runtime.asset_path(asset['id']).read_bytes(), b'source')
        self.assertEqual(self.runtime.get_asset(asset['id']), asset)
        self.assertEqual(len(self.runtime.list_jobs()), 1)

    def test_serial_execution_and_queued_cancel(self):
        first = self.runtime.submit('generate', {'seed': 1, 'sleep': .3}, [])
        second = self.runtime.submit('generate', {'seed': 2}, [])
        self.runtime.start()
        self.wait(first['id'], ('running',))
        self.assertEqual(self.runtime.get_job(second['id'])['state'], 'queued')
        self.runtime.cancel(second['id'])
        self.assertEqual(self.wait(first['id'])['state'], 'succeeded')
        self.assertEqual(self.runtime.get_job(second['id'])['state'], 'cancelled')
        self.assertEqual(self.runtime.get_job(second['id'])['outputs'], [])

    def test_running_cancel_is_stable(self):
        job = self.runtime.submit('generate', {'sleep': 30}, [])
        self.runtime.start()
        self.wait(job['id'], ('running',))
        self.runtime.cancel(job['id'])
        self.runtime.close()
        self.assertEqual(self.runtime.get_job(job['id'])['state'], 'cancelled')

    def test_outputs_and_provenance_published_together(self):
        job = self.runtime.submit('generate', {'seed': 12}, [])
        self.runtime.start()
        result = self.wait(job['id'])
        self.assertEqual(result['state'], 'succeeded')
        self.assertEqual(result['asset'], result['outputs'][0]['asset'])
        self.assertEqual(result['provenance'], {'seed': 12})
        self.assertEqual(result['parameters'], {'seed': 12, 'runtime_provenance': {'seed': 12}})
        self.runtime.close()
        self.runtime = Runtime(self.root)
        self.assertEqual(self.runtime.get_job(job['id'])['parameters'], result['parameters'])
        self.assertEqual(self.runtime.asset_path(result['asset']['id']).read_bytes(), b'audio')

    def test_invalid_second_output_publishes_nothing(self):
        job = self.runtime.submit('generate', {'bad_output': True}, [])
        self.runtime.start()
        result = self.wait(job['id'])
        self.assertEqual(result['state'], 'failed')
        self.assertEqual(result['outputs'], [])

    def test_interrupted_fixed_seed_job_recovers(self):
        job = self.runtime.submit('generate', {'seed': 42, 'sleep': 30}, [])
        self.runtime.start()
        self.wait(job['id'], ('running',))
        self.runtime.close()
        self.runtime = Runtime(self.root)
        self.assertEqual(self.runtime.get_job(job['id'])['state'], 'queued')
        self.assertEqual(self.runtime.get_job(job['id'])['parameters']['seed'], 42)

    def test_cancel_terminates_signal_resistant_process_group(self):
        marker = self.root / 'ready'
        script = ("import signal,pathlib,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); "
                  f"pathlib.Path({str(marker)!r}).touch(); time.sleep(30)")
        self.runtime.command_factory = lambda manifest: [sys.executable, '-c', script, str(manifest)]
        job = self.runtime.submit('generate', {}, [])
        self.runtime.start()
        deadline = time.monotonic() + 3
        while not marker.exists() and time.monotonic() < deadline:
            time.sleep(.02)
        self.assertTrue(marker.exists())
        process = self.runtime._process
        self.runtime.cancel(job['id'])
        self.assertIsNotNone(process.poll())
        self.assertEqual(self.runtime.get_job(job['id'])['state'], 'cancelled')

    def test_actual_service_crash_recovers_fixed_seed_and_kills_worker(self):
        self.runtime.close()
        script = """import os,sys,time,json
from pathlib import Path
from local_inference.runtime import Runtime
root=Path(sys.argv[1])
worker="import time; from pathlib import Path; Path("+repr(str(root/'worker-ready'))+").touch(); time.sleep(30)"
r=Runtime(root,lambda m:[sys.executable,'-c',worker,str(m)])
j=r.submit('generate',{'seed':123},[])
r.start()
while r.get_job(j['id'])['state']!='running': time.sleep(.01)
while not (root/'worker-ready').exists(): time.sleep(.01)
(root/'crashed.json').write_text(json.dumps({'job':j['id'],'pid':r._process.pid}))
os._exit(0)
"""
        subprocess.run([sys.executable, '-c', script, str(self.root)], check=True, timeout=5)
        crashed = json.loads((self.root / 'crashed.json').read_text())
        self.runtime = Runtime(self.root)
        self.assertEqual(self.runtime.get_job(crashed['job'])['state'], 'queued')
        self.assertEqual(self.runtime.get_job(crashed['job'])['parameters']['seed'], 123)
        # ps may briefly show a zombie awaiting adoption/reaping; it cannot execute.
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            state = subprocess.run(['ps', '-p', str(crashed['pid']), '-o', 'stat='],
                                   capture_output=True, text=True).stdout.strip()
            if not state or state.startswith('Z'):
                break
            time.sleep(.02)
        self.assertTrue(not state or state.startswith('Z'), state)

    def test_service_crash_before_pid_commit_does_not_orphan_worker(self):
        self.runtime.close()
        marker = self.root / 'orphan-ran'
        worker = f"import time,pathlib; time.sleep(.4); pathlib.Path({str(marker)!r}).touch()"
        script = """import os,sys,time
from pathlib import Path
from local_inference.runtime import Runtime
r=Runtime(Path(sys.argv[1]),lambda m:[sys.executable,'-c',sys.argv[2],str(m)])
j=r.submit('generate',{'seed':123},[])
original=r._update
def crash(db,job_id,**fields):
    if fields.get('state')=='running': os._exit(0)
    return original(db,job_id,**fields)
r._update=crash
r.start()
time.sleep(10)
"""
        subprocess.run([sys.executable, '-c', script, str(self.root), worker], check=True, timeout=3)
        self.runtime = Runtime(self.root)
        time.sleep(.6)
        self.assertFalse(marker.exists(), 'Uncommitted worker survived its service')
        self.assertEqual(self.runtime.list_jobs()[0]['state'], 'queued')

    def test_add_asset_file_streams_and_persists_checksum(self):
        source = self.root / 'upload.tmp'
        source.write_bytes(b'0123456789' * 200000)
        expected_hash = hashlib.sha256(source.read_bytes()).hexdigest()
        with patch.object(Path, 'read_bytes', side_effect=AssertionError('must stream')):
            asset = self.runtime.add_asset_file(source, '../upload.wav', 'audio/wav')
        self.assertEqual(asset['size_bytes'], 2000000)
        self.assertEqual(asset['sha256'], expected_hash)
        self.assertEqual(asset['filename'], 'upload.wav')
        self.assertEqual(self.runtime.asset_path(asset['id']).stat().st_size, 2000000)
        self.assertEqual(self.runtime.get_asset(asset['id']), asset)

    def test_terminal_success_cannot_be_cancelled(self):
        job = self.runtime.submit('generate', {}, [])
        self.runtime.start()
        result = self.wait(job['id'])
        self.assertEqual(self.runtime.cancel(job['id']), result)

    def test_success_kills_leftover_worker_descendants(self):
        marker = self.root / 'descendant-ran'
        child = f"import time,pathlib; time.sleep(.4); pathlib.Path({str(marker)!r}).touch()"
        script = "import subprocess,sys; subprocess.Popen([sys.executable,'-c'," + repr(child) + "]);" + WORKER
        self.runtime.command_factory = lambda manifest: [sys.executable, '-c', script, str(manifest)]
        job = self.runtime.submit('generate', {}, [])
        self.runtime.start()
        self.assertEqual(self.wait(job['id'])['state'], 'succeeded')
        time.sleep(.5)
        self.assertFalse(marker.exists())

    def test_prunes_crash_orphaned_files(self):
        orphan = self.runtime.asset_root / 'unregistered'
        orphan.write_bytes(b'orphan')
        self.runtime.prune(retention_days=-1)
        self.assertFalse(orphan.exists())

    def test_dispatcher_periodically_prunes_without_restart(self):
        self.runtime.close()
        self.runtime = Runtime(self.root, maintenance_interval=.02)
        self.runtime.command_factory = lambda manifest: [sys.executable, '-c', WORKER, str(manifest)]
        expired = self.runtime.submit('generate', {}, [])
        self.runtime.cancel(expired['id'])
        with self.runtime._db() as db:
            record = self.runtime._job(db, expired['id'])
            record['updated_at'] = '2000-01-01T00:00:00+00:00'
            db.execute('UPDATE jobs SET record=? WHERE id=?', (json.dumps(record), expired['id']))
        first = self.runtime.submit('generate', {'sleep': .1}, [])
        asset = self.runtime.add_asset(b'active', 'source.wav', 'audio/wav')
        active = self.runtime.submit('generate', {'sleep': .1},
                                     [{'name': 'source', 'position': 0, 'asset': asset}])
        with self.runtime._db() as db:
            db.execute('UPDATE assets SET created_at=? WHERE id=?',
                       ('2000-01-01T00:00:00+00:00', asset['id']))
        completed = threading.Event()
        original = self.runtime.prune

        def maintenance(*args, **kwargs):
            original(*args, **kwargs)
            completed.set()

        with patch.object(self.runtime, 'prune', side_effect=maintenance):
            self.runtime.start()
            self.assertTrue(completed.wait(timeout=3), 'Dispatcher never ran maintenance')
            with self.assertRaises(KeyError):
                self.runtime.get_job(expired['id'])
            self.assertEqual(self.runtime.asset_path(asset['id']).read_bytes(), b'active')
            self.assertIn(self.runtime.get_job(active['id'])['state'], ('queued', 'running'))

    def test_maintenance_failure_does_not_stop_dispatcher(self):
        self.runtime.close()
        self.runtime = Runtime(self.root, maintenance_interval=.01)
        self.runtime.command_factory = lambda manifest: [sys.executable, '-c', WORKER, str(manifest)]
        first = self.runtime.submit('generate', {'sleep': .05}, [])
        second = self.runtime.submit('generate', {}, [])
        with patch.object(self.runtime, 'prune', side_effect=OSError('maintenance unavailable')):
            with self.assertLogs('local_inference.runtime', level='ERROR'):
                self.runtime.start()
                self.assertEqual(self.wait(second['id'])['state'], 'succeeded')

    def test_pruning_keeps_active_assets(self):
        asset = self.runtime.add_asset(b'active', 'source.wav', 'audio/wav')
        orphan = self.runtime.add_asset(b'orphan', 'orphan.wav', 'audio/wav')
        job = self.runtime.submit('generate', {'seed': 1}, [{'name': 'source', 'position': 0, 'asset': asset}])
        self.runtime.prune(retention_days=-1)
        self.assertTrue(self.runtime.asset_path(asset['id']).exists())
        with self.assertRaises(KeyError):
            self.runtime.asset_path(orphan['id'])
        self.runtime.cancel(job['id'])
        self.runtime.prune(retention_days=-1)
        with self.assertRaises(KeyError):
            self.runtime.get_job(job['id'])


if __name__ == '__main__':
    unittest.main()
