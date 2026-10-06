"""Run both agent entrypoints against a deterministic local LLM endpoint."""
import http.server
import json
import os
from pathlib import Path
import ssl
import subprocess
import sys
import tempfile
import threading
import time

class Handler(http.server.BaseHTTPRequestHandler):
    requests = []
    def log_message(self, *args): pass
    def do_POST(self):
        payload=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        self.requests.append(payload)
        scenario=next(m['content'] for m in reversed(payload['messages']) if m['role']=='user')
        last_user=max(i for i,m in enumerate(payload['messages']) if m['role']=='user')
        tool_messages=[m for m in payload['messages'][last_user+1:] if m['role']=='tool']
        tool=None
        content='Done'
        if scenario=='readonly': tool=('terminal',{'command':'touch denied'})
        elif scenario=='diagnostic_denied':
            if not tool_messages: tool=('diagnostics',{'action':'build','target':'unit.pas'})
        elif scenario=='fallback':
            if not tool_messages:
                content=json.dumps({'name':'plan','arguments':{'action':'replace','items':[{'id':'one','text':'Verify','status':'pending'}]}})
        elif scenario=='edit':
            if not tool_messages: tool=('edit_file',{'path':'unit.pas','old_text':'old','new_text':'new'})
        elif scenario=='tls_smoke':
            content='TLS transport verified'
        elif scenario=='exhaust': tool=('todo',{'action':'read'})
        elif scenario=='gui_patch':
            if not tool_messages: tool=('apply_patch',{'patch':'--- a/unit.pas\n+++ b/unit.pas\n@@ -1 +1 @@\n-old\n+new\n'})
        elif scenario=='gui_shell':
            if not tool_messages: tool=('shell',{'command':"printf 'shell\\n' > shell-created"})
        elif scenario=='gui_commands':
            if not tool_messages:
                tool=('terminal',{'command': '\n  cat <<\'COMMAND\'\n<script>"quoted" & text</script>\n```\n````\n`literal`\n\nCOMMAND\n'})
            elif len(tool_messages)==1:
                tool=('shell',{'command':'printf "second command"; exit 7'})
        elif scenario=='gui_plan_text':
            content='<proposed_plan>\n# Plan\nUpdate unit.pas to built.\n</proposed_plan>'
        elif scenario=='gui_plan_question':
            content='Which feature should I plan?'
        elif scenario=='gui_empty':
            content=''
        elif scenario=='gui_failure' or (scenario=='gui_plan_failed' and tool_messages):
            self.send_response(500); self.end_headers(); return
        elif scenario=='gui_plan_cancel':
            if not tool_messages: tool=('create_plan_file',{'content':'# Cancelled plan'})
            else: time.sleep(.2)
        elif scenario=='gui_plan_failed':
            tool=('create_plan_file',{'content':'# Failed plan'})
        elif scenario=='gui_fail_after_edit':
            if not tool_messages: tool=('write_file',{'path':'partial.pas','content':'partial'})
            else:
                self.send_response(500); self.end_headers(); return
        elif scenario=='gui_tracking_warning':
            if not tool_messages: tool=('shell',{'command':'mkfifo untrackable; touch tracked'})
        elif scenario=='gui_plan':
            if not tool_messages: tool=('create_plan_file',{'content':'# Plan\nUpdate unit.pas to built.'})
        elif scenario.startswith('Implement the plan saved at '):
            if not tool_messages: tool=('edit_file',{'path':'unit.pas','old_text':'new','new_text':'built'})
        elif scenario=='gui_slow':
            if not tool_messages: tool=('shell',{'command':'touch running; sleep 10'})
        else: raise AssertionError(scenario)
        if tool:
            function={'name':tool[0],'arguments':json.dumps(tool[1])}
            if payload.get('stream'):
                response='data: '+json.dumps({'choices':[{'delta':{'tool_calls':[{'index':0,'id':'call_fixture','function':function}]}}]})+'\n\n'
            else:
                response=json.dumps({'choices':[{'message':{'content':'','tool_calls':[{'id':'call_fixture','type':'function','function':function}]}}]})
        else:
            if payload.get('stream'): response='data: '+json.dumps({'choices':[{'delta':{'content':content}}]})+'\n\n'
            else: response=json.dumps({'choices':[{'message':{'content':content}}]})
        if payload.get('stream'): response+='data: [DONE]\n\n'
        encoded=response.encode()
        self.send_response(200)
        self.send_header('Content-Type','text/event-stream' if payload.get('stream') else 'application/json')
        self.send_header('Content-Length',str(len(encoded)))
        self.end_headers(); self.wfile.write(encoded)

def run(driver):
    server=http.server.ThreadingHTTPServer(('127.0.0.1',0), Handler)
    worker=threading.Thread(target=server.serve_forever,daemon=True); worker.start()
    endpoint=f'http://127.0.0.1:{server.server_port}/v1/chat/completions'
    scenarios=0
    try:
        with tempfile.TemporaryDirectory(prefix='coding-agent-loop-') as temporary:
            root=Path(temporary)/'project'; root.mkdir()
            rules=root/'.rules'; rules.mkdir()
            (rules/'b.md').write_text('Second project rule.')
            (rules/'a.md').write_text('First project rule.')
            env={**os.environ,'XDG_CONFIG_HOME':str(Path(temporary)/'config')}
            for method in ('sync','thread'):
                for mode,scenario in [('Ask','readonly'),('Plan','readonly'),('Ask','diagnostic_denied'),('Plan','fallback'),('Agent','edit'),('Agent','exhaust')]:
                    (root/'unit.pas').write_text('old\n')
                    start=len(Handler.requests)
                    p=subprocess.run([driver,str(root),endpoint,mode,method,scenario],env=env,text=True,encoding='utf-8',capture_output=True,timeout=15)
                    assert p.returncode==0, p.stderr
                    result=json.loads(p.stdout)
                    requests=Handler.requests[start:]
                    assert requests, result
                    readonly = {'read_file','list_directory','glob','search_code','diagnostics','git','todo'}
                    expected = readonly if mode == 'Ask' else readonly | {'create_plan_file'}
                    if mode == 'Agent': expected |= {'write_file','apply_patch','shell'}
                    for request in requests:
                        prompt = request['messages'][0]['content'].replace('\r\n', '\n')
                        assert f'Active Mode: {mode}\n' in prompt
                        assert prompt.index('First project rule.') < prompt.index('Second project rule.')
                        assert 'Project Rules (from .rules/*.md):' in prompt
                        functions = {t['function']['name']: t['function'] for t in request['tools']}
                        guidance = {}
                        for line in prompt.splitlines():
                            if line.startswith('- ') and ' Parameters: ' in line:
                                description, schema = line[2:].split(' Parameters: ', 1)
                                name, description = description.split(': ', 1)
                                guidance[name] = (description, json.loads(schema))
                        assert set(guidance) == set(functions) == expected
                        for name, (description, schema) in guidance.items():
                            assert description == functions[name]['description']
                            assert schema == functions[name]['parameters']
                        if mode == 'Plan':
                            assert f'Only create .md files inside {root / ".plan"}{os.sep}, using create_plan_file.' in prompt
                            assert 'Do not modify other project files.' in prompt
                            assert 'Shell commands and compiler builds are unavailable.' in prompt
                    names={t['function']['name'] for t in requests[0]['tools']}
                    assert 'list_directory' in names and 'list_files' not in names and 'terminal' not in names
                    if mode!='Agent': assert 'shell' not in names
                    if scenario=='readonly':
                        assert not result['success'] and not (root/'denied').exists()
                    elif scenario=='diagnostic_denied':
                        assert result['success'] and 'error' in result['results'][0]['result']
                    elif scenario=='fallback':
                        assert result['success'] and result['tasks'][0]['id']=='one' and result['tasks_after_clear']==[]
                    elif scenario=='edit':
                        assert result['success'] and (root/'unit.pas').read_text()=='new\n'
                        assert result['results'][0]['result']['changed_paths']==[str(root/'unit.pas')]
                        assert result['changes']==[{'path':str(root/'unit.pas'),'completed_tools':0}]
                    elif scenario=='exhaust':
                        assert not result['success'] and 'iteration limit' in result['response'] and len(requests)==50
                    scenarios+=1
            print(f'Agent loop tests passed ({scenarios} synchronous/worker scenarios).')
    finally:
        server.shutdown(); server.server_close(); worker.join()

    if os.environ.get('RUN_TLS_SMOKE') == '1':
        run_tls_smoke(driver)

def run_tls_smoke(driver):
    with tempfile.TemporaryDirectory(prefix='coding-agent-tls-') as temporary:
        cert=Path(temporary)/'localhost.crt'
        key=Path(temporary)/'localhost.key'
        subprocess.run([
            'openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','1',
            '-keyout',str(key),'-out',str(cert),'-subj','/CN=127.0.0.1',
            '-addext','subjectAltName=IP:127.0.0.1'
        ],check=True,capture_output=True,text=True)
        server=http.server.ThreadingHTTPServer(('127.0.0.1',0), Handler)
        context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(certfile=cert,keyfile=key)
        server.socket=context.wrap_socket(server.socket,server_side=True)
        worker=threading.Thread(target=server.serve_forever,daemon=True)
        worker.start()
        try:
            root=Path(temporary)/'project'; root.mkdir()
            endpoint=f'https://127.0.0.1:{server.server_port}/v1/chat/completions'
            env={**os.environ,'SSL_CERT_FILE':str(cert),'SSL_CERT_DIR':temporary}
            result=subprocess.run(
                [driver,str(root),endpoint,'Ask','thread','tls_smoke'],
                env=env,text=True,encoding='utf-8',capture_output=True,timeout=30)
            assert result.returncode==0, result.stderr
            response=json.loads(result.stdout)
            assert response['success'] and response['response']=='TLS transport verified', response
            assert Handler.requests[-1].get('stream') is True, Handler.requests[-1]
            print('HTTPS/SSE transport smoke test passed.')
        finally:
            server.shutdown(); server.server_close(); worker.join()

if __name__=='__main__': run(sys.argv[1])
