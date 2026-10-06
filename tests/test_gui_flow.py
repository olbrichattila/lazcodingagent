import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
from test_agent_loops import Handler
import http.server

with tempfile.TemporaryDirectory(prefix='coding-agent-gui-fixtures-') as temporary:
    root=Path(temporary)/'project'; root.mkdir(); (root/'unit.pas').write_text('old\n')
    server=http.server.ThreadingHTTPServer(('127.0.0.1',0), Handler)
    thread=threading.Thread(target=server.serve_forever,daemon=True); thread.start()
    try:
        env={**os.environ, 'XDG_CONFIG_HOME':str(Path(temporary)/'config'), 'XDG_RUNTIME_DIR':str(Path(temporary)/'runtime')}
        Path(env['XDG_RUNTIME_DIR']).mkdir(mode=0o700)
        endpoint=f'http://127.0.0.1:{server.server_port}/v1/chat/completions'
        p=subprocess.run([sys.argv[1],str(root),endpoint],text=True,encoding='utf-8',capture_output=True,env=env,timeout=90)
        assert p.returncode==0, (p.stdout,p.stderr, [m for request in Handler.requests for m in request['messages'] if m['role']=='tool'])
        result=json.loads(p.stdout)
        assert result['previewed'] and result['main_thread_refresh'] and result['clear_cancelled'] and result['project_switched']
        assert result['commands_displayed']
        assert (root/'unit.pas').read_text()=='built\n'
        assert (root/'shell-created').read_text()=='shell\n'
        print('GUI flow tests passed (automatic saved/text plan previews, clarification/save failure/cancellation, Build, completion/file lists, shell tracking warnings, run isolation, IDE refresh, project switch).')
    finally:
        server.shutdown(); server.server_close(); thread.join()
