"""Kill an inference process group if the owning service disappears.

The parent alone holds the pipe writer. This protects even the interval between
Popen and the SQLite PID commit. This module intentionally uses only stdlib.
"""
import json
import os
import signal
import subprocess
import sys
import threading


def main():
    lifetime_fd = int(sys.argv[1])
    command = json.loads(sys.argv[2])

    def watch_parent():
        try:
            while os.read(lifetime_fd, 1):
                pass
        finally:
            os.killpg(os.getpgrp(), signal.SIGKILL)

    threading.Thread(target=watch_parent, daemon=True).start()
    child = subprocess.Popen(command)
    return_code = child.wait()
    return return_code if return_code >= 0 else 128 - return_code


if __name__ == '__main__':
    sys.exit(main())
