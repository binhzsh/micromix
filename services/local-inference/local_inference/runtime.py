"""Durable local job store and serial, disposable subprocess dispatcher."""
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
import fcntl
import hashlib
import io
import json
import logging
import os
from pathlib import Path
import shutil
import signal
import sqlite3
import subprocess
import sys
import threading
import time
import uuid


TERMINAL = ('succeeded', 'failed', 'cancelled')


def _now():
    return datetime.now(timezone.utc).isoformat()


class Runtime:
    def __init__(self, root: Path, command_factory=None, *, maintenance_interval=3600):
        if maintenance_interval <= 0:
            raise ValueError("maintenance_interval must be positive")
        self.maintenance_interval = maintenance_interval
        self.root = Path(root).resolve()
        self.root.mkdir(parents=True, exist_ok=True)
        self.asset_root = self.root / 'assets'
        self.work_root = self.root / 'work'
        self.asset_root.mkdir(exist_ok=True)
        self.work_root.mkdir(exist_ok=True)
        self.database = self.root / 'runtime.sqlite3'
        self._lock = threading.RLock()
        self._wake = threading.Event()
        self._stop = threading.Event()
        self._thread = None
        self._process = None
        self._process_job = None
        self._closed = False
        self.command_factory = command_factory or (
            lambda manifest: [sys.executable, '-m', 'local_inference.worker', str(manifest)]
        )
        self._lease = (self.root / 'runtime.lock').open('a+')
        try:
            fcntl.flock(self._lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            self._lease.close()
            raise RuntimeError('Another local runtime already owns this data directory') from None
        with self._db() as db:
            db.executescript('''
                PRAGMA journal_mode=WAL;
                CREATE TABLE IF NOT EXISTS assets (
                    id TEXT PRIMARY KEY, record TEXT NOT NULL, path TEXT NOT NULL,
                    created_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS jobs (
                    id TEXT PRIMARY KEY, record TEXT NOT NULL,
                    worker_parameters TEXT NOT NULL, pid INTEGER, manifest TEXT
                );
                CREATE TABLE IF NOT EXISTS links (
                    job_id TEXT REFERENCES jobs(id) ON DELETE CASCADE,
                    asset_id TEXT REFERENCES assets(id), direction TEXT,
                    name TEXT, position INTEGER,
                    PRIMARY KEY(job_id,direction,position)
                );
            ''')
            interrupted = db.execute('SELECT id,record,pid,manifest FROM jobs').fetchall()
            for row in interrupted:
                record = json.loads(row['record'])
                if row['pid'] and row['manifest']:
                    # Verify identity before signalling a PID that may have been reused.
                    command = subprocess.run(
                        ['ps', '-p', str(row['pid']), '-o', 'command='],
                        capture_output=True, text=True, check=False,
                    ).stdout
                    if row['manifest'] in command:
                        self._kill_group(row['pid'], signal.SIGKILL)
                if record['state'] == 'running':
                    record.update(state='queued', updated_at=_now(), progress=None,
                                  progress_detail='Recovered after local service restart')
                    db.execute('UPDATE jobs SET record=?,pid=NULL,manifest=NULL WHERE id=?',
                               (json.dumps(record), row['id']))
        # Previous process workspaces contain no published assets.
        for path in self.work_root.iterdir():
            if path.is_dir():
                shutil.rmtree(path)

    @contextmanager
    def _db(self):
        with self._lock:
            db = sqlite3.connect(self.database)
            db.row_factory = sqlite3.Row
            db.execute('PRAGMA foreign_keys=ON')
            try:
                with db:
                    yield db
            finally:
                db.close()

    def _write_asset_stream(self, source, filename, media_type):
        asset_id = uuid.uuid4().hex
        path = self.asset_root / asset_id
        temporary = self.asset_root / (asset_id + '.tmp')
        digest = hashlib.sha256()
        size = 0
        try:
            with temporary.open('wb') as output:
                while chunk := source.read(1024 * 1024):
                    output.write(chunk)
                    digest.update(chunk)
                    size += len(chunk)
                output.flush()
                os.fsync(output.fileno())
            temporary.replace(path)
        except Exception:
            temporary.unlink(missing_ok=True)
            raise
        record = dict(id=asset_id, filename=Path(filename).name or 'asset',
                      media_type=media_type, size_bytes=size,
                      sha256=digest.hexdigest(),
                      download_url=f'/v1/assets/{asset_id}')
        return record, path

    def _write_asset(self, data, filename, media_type):
        return self._write_asset_stream(io.BytesIO(data), filename, media_type)

    def _add_asset_stream(self, source, filename, media_type):
        with self._lock:
            record, path = self._write_asset_stream(source, filename, media_type)
            try:
                with self._db() as db:
                    db.execute('INSERT INTO assets VALUES (?,?,?,?)',
                               (record['id'], json.dumps(record), str(path), _now()))
            except Exception:
                path.unlink(missing_ok=True)
                raise
            return record

    def add_asset(self, data: bytes, filename: str, media_type: str):
        return self._add_asset_stream(io.BytesIO(data), filename, media_type)

    def add_asset_file(self, path: Path, filename: str, media_type: str):
        """Copy and hash an upload in bounded chunks; the caller owns its source."""
        with Path(path).open('rb') as source:
            return self._add_asset_stream(source, filename, media_type)

    def get_asset(self, asset_id):
        with self._db() as db:
            row = db.execute('SELECT record FROM assets WHERE id=?', (asset_id,)).fetchone()
            if row is None:
                raise KeyError(asset_id)
            return json.loads(row['record'])

    def asset_path(self, asset_id):
        with self._db() as db:
            row = db.execute('SELECT path FROM assets WHERE id=?', (asset_id,)).fetchone()
            if row is None:
                raise KeyError(asset_id)
            return Path(row['path'])

    def submit(self, kind: str, parameters: dict, inputs: list, worker_parameters=None):
        job_id = uuid.uuid4().hex
        timestamp = _now()
        record = dict(id=job_id, kind=kind, state='queued', parameters=parameters,
                      progress=None, progress_detail=None, error=None,
                      created_at=timestamp, updated_at=timestamp,
                      inputs=[], outputs=[], asset=None, provenance={})
        with self._db() as db:
            db.execute('INSERT INTO jobs (id,record,worker_parameters) VALUES (?,?,?)',
                       (job_id, json.dumps(record), json.dumps(worker_parameters or {})))
            for link in inputs:
                asset_id = link['asset']['id']
                if db.execute('SELECT id FROM assets WHERE id=?', (asset_id,)).fetchone() is None:
                    raise KeyError(asset_id)
                db.execute('INSERT INTO links VALUES (?,?,?,?,?)',
                           (job_id, asset_id, 'inputs', link['name'], link['position']))
        self._wake.set()
        return self.get_job(job_id)

    def _job(self, db, job_id):
        row = db.execute('SELECT record FROM jobs WHERE id=?', (job_id,)).fetchone()
        if row is None:
            raise KeyError(job_id)
        record = json.loads(row['record'])
        for direction in ('inputs', 'outputs'):
            links = db.execute('''SELECT links.name,links.position,assets.record FROM links
                JOIN assets ON links.asset_id=assets.id WHERE job_id=? AND direction=?
                ORDER BY position''', (job_id, direction)).fetchall()
            record[direction] = [dict(name=link['name'], position=link['position'],
                                      asset=json.loads(link['record'])) for link in links]
        record['asset'] = record['outputs'][0]['asset'] if record['outputs'] else None
        return record

    def get_job(self, job_id):
        with self._db() as db:
            return self._job(db, job_id)

    def list_jobs(self):
        with self._db() as db:
            return [self._job(db, row['id']) for row in db.execute('SELECT id FROM jobs ORDER BY rowid DESC').fetchall()]

    def _update(self, db, job_id, **fields):
        record = self._job(db, job_id)
        record.update(fields, updated_at=_now())
        db.execute('UPDATE jobs SET record=? WHERE id=?', (json.dumps(record), job_id))

    def cancel(self, job_id):
        with self._lock:
            with self._db() as db:
                job = self._job(db, job_id)
                if job['state'] not in TERMINAL:
                    self._update(db, job_id, state='cancelled', progress_detail='Cancelled')
            process = self._process if self._process_job == job_id else None
        if process is not None:
            self._terminate(process)
        self._wake.set()
        return self.get_job(job_id)

    @staticmethod
    def _kill_group(pid, sig):
        try:
            os.killpg(pid, sig)
        except ProcessLookupError:
            pass

    def _terminate(self, process):
        self._kill_group(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            pass
        # Kill descendants even when the immediate worker already exited.
        self._kill_group(process.pid, signal.SIGKILL)
        process.wait(timeout=5)

    def start(self):
        with self._lock:
            if self._closed:
                raise RuntimeError('Runtime is closed')
            if self._thread is None:
                self._thread = threading.Thread(target=self._dispatch, name='local-inference', daemon=True)
                self._thread.start()

    def _dispatch(self):
        next_maintenance = time.monotonic() + self.maintenance_interval
        while not self._stop.is_set():
            self._wake.clear()
            if time.monotonic() >= next_maintenance:
                try:
                    self.prune()
                except Exception:
                    logging.getLogger(__name__).exception('Local runtime retention maintenance failed')
                finally:
                    next_maintenance = time.monotonic() + self.maintenance_interval
            with self._db() as db:
                queued = next((row['id'] for row in db.execute('SELECT id,record FROM jobs ORDER BY rowid')
                               if json.loads(row['record'])['state'] == 'queued'), None)
            if queued is None:
                self._wake.wait(min(.5, max(0, next_maintenance - time.monotonic())))
                continue
            self._execute(queued)

    def _execute(self, job_id):
        workspace = self.work_root / job_id
        staged = []
        lifetime_fd = None
        try:
            with self._lock:
                if self._stop.is_set():
                    return
                with self._db() as db:
                    job = self._job(db, job_id)
                    if job['state'] != 'queued':
                        return
                    workspace.mkdir(exist_ok=True)
                    output_dir = workspace / 'outputs'
                    output_dir.mkdir(exist_ok=True)
                    private = json.loads(db.execute('SELECT worker_parameters FROM jobs WHERE id=?', (job_id,)).fetchone()[0])
                    manifest = dict(operation=job['kind'], parameters={**job['parameters'], **private},
                                    inputs=[dict(name=link['name'], position=link['position'],
                                                 path=str(self.asset_path(link['asset']['id']))) for link in job['inputs']],
                                    output_dir=str(output_dir))
                    manifest_path = workspace / 'manifest.json'
                    manifest_path.write_text(json.dumps(manifest))
                    command = self.command_factory(manifest_path)
                    read_fd, lifetime_fd = os.pipe()
                    try:
                        with (workspace / 'worker.log').open('wb') as log:
                            process = subprocess.Popen(
                                [sys.executable, str(Path(__file__).with_name('supervisor.py')),
                                 str(read_fd), json.dumps(command)],
                                stdout=log, stderr=log, start_new_session=True,
                                pass_fds=(read_fd,),
                            )
                    finally:
                        os.close(read_fd)
                    self._process, self._process_job = process, job_id
                    db.execute('UPDATE jobs SET pid=?,manifest=? WHERE id=?', (process.pid, str(manifest_path), job_id))
                    self._update(db, job_id, state='running', progress_detail='Running locally')
            code = process.wait()
            self._kill_group(process.pid, signal.SIGKILL)
            with self._lock:
                if self._stop.is_set() or self.get_job(job_id)['state'] == 'cancelled':
                    return
                if code:
                    detail = (workspace / 'worker.log').read_text(errors='replace')[-4000:]
                    raise RuntimeError(f'Local worker exited with status {code}: {detail}')
                result = json.loads((output_dir / 'result.json').read_text())
                outputs = result['outputs']
                if not outputs:
                    raise ValueError('Local worker produced no outputs')
                for item in outputs:
                    source = Path(item['path'])
                    if not source.is_absolute():
                        source = output_dir / source
                    source = source.resolve()
                    if not source.is_relative_to(output_dir.resolve()):
                        raise ValueError('Worker output escaped its output directory')
                    record, path = self._write_asset(source.read_bytes(), item['filename'], item['media_type'])
                    staged.append((record, path, item['name']))
                with self._db() as db:
                    for position, (record, path, name) in enumerate(staged):
                        db.execute('INSERT INTO assets VALUES (?,?,?,?)', (record['id'], json.dumps(record), str(path), _now()))
                        db.execute('INSERT INTO links VALUES (?,?,?,?,?)', (job_id, record['id'], 'outputs', name, position))
                    provenance = result.get('provenance', {})
                    parameters = {**job['parameters'], 'runtime_provenance': provenance}
                    self._update(db, job_id, state='succeeded', progress=1.0, progress_detail='Complete',
                                 parameters=parameters, provenance=provenance)
                staged.clear()
        except Exception as exc:
            with self._db() as db:
                if self._job(db, job_id)['state'] not in TERMINAL and not self._stop.is_set():
                    self._update(db, job_id, state='failed', error=str(exc), progress_detail='Failed')
        finally:
            if lifetime_fd is not None:
                os.close(lifetime_fd)
            for _, path, _ in staged:
                path.unlink(missing_ok=True)
            with self._lock:
                self._process = self._process_job = None
                with self._db() as db:
                    db.execute('UPDATE jobs SET pid=NULL,manifest=NULL WHERE id=?', (job_id,))
            shutil.rmtree(workspace, ignore_errors=True)

    def close(self):
        with self._lock:
            if self._closed:
                return
            self._closed = True
            self._stop.set()
            self._wake.set()
            process = self._process
        if process is not None:
            self._terminate(process)
        if self._thread is not None:
            self._thread.join(timeout=10)
            if self._thread.is_alive():
                raise RuntimeError('Local inference dispatcher did not stop')
        fcntl.flock(self._lease, fcntl.LOCK_UN)
        self._lease.close()

    def prune(self, retention_days=7):
        cutoff = (datetime.now(timezone.utc) - timedelta(days=retention_days)).isoformat()
        with self._db() as db:
            deleted = 0
            for row in db.execute('SELECT id,record FROM jobs').fetchall():
                if deleted >= 1000:
                    break
                job = json.loads(row['record'])
                if job['state'] in TERMINAL and job['updated_at'] < cutoff:
                    db.execute('DELETE FROM jobs WHERE id=?', (row['id'],))
                    deleted += 1
            expired = db.execute('''SELECT id,path FROM assets WHERE created_at<?
                AND NOT EXISTS (SELECT 1 FROM links WHERE links.asset_id=assets.id) LIMIT 1000''', (cutoff,)).fetchall()
            for row in expired:
                Path(row['path']).unlink(missing_ok=True)
                db.execute('DELETE FROM assets WHERE id=?', (row['id'],))
            known = {row['path'] for row in db.execute('SELECT path FROM assets')}
            cutoff_timestamp = datetime.fromisoformat(cutoff).timestamp()
            removed = 0
            for path in self.asset_root.iterdir():
                if removed >= 1000:
                    break
                if str(path) not in known and path.is_file() and path.stat().st_mtime < cutoff_timestamp:
                    path.unlink(missing_ok=True)
                    removed += 1
