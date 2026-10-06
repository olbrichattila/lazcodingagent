"""Deterministic multi-turn and compaction coverage for both agent entrypoints."""
import http.server
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import tempfile
import threading

class Handler(http.server.BaseHTTPRequestHandler):
    requests = []
    summary_count = 0
    fail_summary_at = 0
    summary_kind = 'ok'

    def log_message(self, *args):
        pass

    def do_POST(self):
        p = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        type(self).requests.append(p)
        if p.get('max_tokens'):
            type(self).summary_count += 1
            assert 'tools' not in p and p['max_tokens'] == 2048
            assert 'SECRET_REASONING' not in json.dumps(p)
            if type(self).summary_count == type(self).fail_summary_at:
                self.send_response(500); self.end_headers(); return
            content = '' if type(self).summary_kind == 'empty' else 'Objective: inspect project. Decisions: use Pascal. Unresolved: finish task.'
            if type(self).summary_kind == 'oversized': content = 'x' * 25000
            calls = [self.call('bad', 'todo', {'action':'read'})] if type(self).summary_kind == 'tool' else []
            finish = 'length' if type(self).summary_kind == 'length' else 'stop'
        else:
            users = [m for m in p['messages'] if m['role'] == 'user']
            prompt = users[-1]['content']
            last = max(i for i, m in enumerate(p['messages']) if m['role'] == 'user')
            tools = [m for m in p['messages'][last+1:] if m['role'] == 'tool']
            content, calls, finish = 'answer:' + prompt, [], 'stop'
            if prompt in ('multi', 'empty', 'missing', 'repeated', 'reject', 'cancelbatch') and not tools:
                content = '' if prompt == 'empty' else 'Inspecting files'
                calls = [self.call('shared', 'todo', {'action':'read'}), self.call('other', 'todo', {'action':'read'})]
                if prompt == 'missing':
                    for c in calls: c['id'] = ''
                if prompt == 'reject':
                    calls[1] = self.call('other', 'shell', {'command':'touch denied'})
                    calls.append(self.call('third', 'todo', {'action':'read'}))
                if prompt == 'cancelbatch': calls[1] = self.call('other', 'read_file', {'path':'missing.pas'})
            elif prompt == 'multi' and len(tools) == 2:
                calls = [self.call('shared', 'todo', {'action':'read'})]
            elif prompt == 'huge' and not tools:
                calls = [self.call('huge', 'read_file', {'path':'huge.pas'})]
            elif prompt.startswith('seed:'):
                content = 'engineering evidence ' + ('x' * int(prompt.split(':')[1]))
            elif prompt in ('broken', 'shortstream', 'duplicate'):
                calls = [self.call('broken', 'todo', {'action':'read'})] if prompt != 'shortstream' or not tools else []
                if prompt == 'broken': calls[0]['function']['arguments'] = '{'
                if prompt == 'duplicate': calls = calls * 2
            elif prompt == 'httpfail':
                self.send_response(500); self.end_headers()
                self.wfile.write(b'{"error":{"message":"upstream rejected request"}}')
                return
        self.send_response(200)
        if p.get('stream'):
            self.send_header('Content-Type', 'text/event-stream'); self.end_headers()
            events = []
            if calls:
                # Index 1 arrives before index 0. Arguments are split and names repeated.
                for i in reversed(range(len(calls))):
                    c = calls[i]; args = c['function']['arguments']; split = len(args)//2
                    events.append({'choices':[{'delta':{'tool_calls':[{'index':i,'id':c['id'],'function':{'name':c['function']['name'],'arguments':args[:split]}}]}}]})
                for i, c in enumerate(calls):
                    args = c['function']['arguments']; split = len(args)//2
                    events.append({'choices':[{'delta':{'tool_calls':[{'index':i,'id':c['id'],'function':{'name':c['function']['name'],'arguments':args[split:]}}]}}]})
            events.append({'choices':[{'delta':{'content':content,'reasoning_content':'SECRET_REASONING',
                'reasoning_details':[{'type':'reasoning.text','text':'SECRET_REASONING_DETAILS'}]}}]})
            if prompt == 'shortstream':
                events[-1]['choices'][0]['finish_reason'] = 'tool_calls'
            response = ''.join('data: '+json.dumps(e)+'\n\n' for e in events)
            if prompt == 'badjson': response += 'data: {broken\n\n'
            elif prompt == 'providererr': response += 'data: {"error":{"message":"quota exceeded"}}\n\n'
            elif prompt == 'finishbad': response += 'data: '+json.dumps({'choices':[{'delta':{},'finish_reason':'length'}]})+'\n\n'
            if prompt not in ('shortstream', 'noterminal'): response += 'data: [DONE]\n\n'
        else:
            self.send_header('Content-Type', 'application/json'); self.end_headers()
            response = json.dumps({'choices':[{'finish_reason':finish,'message':{'content':content,'tool_calls':calls,'reasoning_content':'SECRET_REASONING'}}]})
        self.wfile.write(response.encode())

    @staticmethod
    def call(id_, name, args):
        return {'id':id_, 'type':'function', 'function':{'name':name,'arguments':json.dumps(args)}}

def run(driver):
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    worker = threading.Thread(target=server.serve_forever, daemon=True); worker.start()
    count = 0
    try:
        with tempfile.TemporaryDirectory(prefix='agent-context-') as tmp:
            root = Path(tmp)/'project'; root.mkdir(); (root/'huge.pas').write_text('z'*70000)
            env = {**os.environ, 'XDG_CONFIG_HOME':str(Path(tmp)/'config')}
            endpoint = f'http://127.0.0.1:{server.server_port}/v1/chat/completions'
            def execute(method, steps, fail=0, summary_kind='ok'):
                nonlocal count
                Handler.requests = []; Handler.summary_count = 0
                Handler.fail_summary_at = fail; Handler.summary_kind = summary_kind
                steps_file = root/'steps.json'
                steps_file.write_text(json.dumps(steps), encoding='utf-8')
                p = subprocess.run([driver,str(root),endpoint,method,str(steps_file)],env=env,text=True,encoding='utf-8',capture_output=True,timeout=45)
                assert p.returncode == 0, (p.stdout,p.stderr)
                assert not re.search(r'[1-9][0-9]* unfreed memory blocks', p.stderr), p.stderr
                result = json.loads(p.stdout)
                assert all(r['idle'] for r in result)
                assert 'SECRET_REASONING' not in p.stdout
                count += 1
                return result, Handler.requests[:]
            for method in ('sync', 'thread'):
                result, requests = execute(method, [{'prompt':'multi'},{'prompt':'fix it'},{'clear':True,'prompt':'fresh'}])
                assert all(r['success'] for r in result)
                assert [m['role'] for m in result[0]['messages']] == ['user','assistant','tool','tool','assistant','tool','assistant']
                assert result[0]['messages'][1]['content'] == 'Inspecting files'
                assert result[0]['messages'][1]['tool_calls'][0]['id'] == 'shared'
                assert result[0]['messages'][2]['tool_call_id'] == 'shared'
                assert result[0]['messages'][3]['tool_call_id'] == 'other'
                assert result[0]['messages'][5]['tool_call_id'] == 'shared'
                assert requests[3]['messages'][1:-1] == result[0]['messages']
                assert [m['content'] for m in requests[-1]['messages'] if m['role']=='user'] == ['fresh']
                for scenario in ('empty','missing','repeated'):
                    result, requests = execute(method,[{'prompt':scenario},{'prompt':scenario}])
                    assert all(r['success'] for r in result)
                    for r in result:
                        msgs = r['messages']
                        for i, m in enumerate(msgs):
                            if m.get('tool_calls'):
                                ids = [c['id'] for c in m['tool_calls']]
                                assert len(set(ids)) == len(ids) and all(ids)
                                assert [x['tool_call_id'] for x in msgs[i+1:i+1+len(ids)]] == ids
                    if scenario == 'empty': assert result[0]['messages'][1]['content'] is None
                result, requests = execute(method,[{'prompt':'reject'},{'prompt':'continue'}])
                assert not result[0]['success'] and result[1]['success']
                assert result[0]['count'] == 5 and not (root/'denied').exists()
                assert requests[-1]['messages'][1:-1] == result[0]['messages']
                for scenario in ('broken','duplicate','httpfail'):
                    result, requests = execute(method,[{'prompt':scenario},{'prompt':'retry followup'}])
                    assert not result[0]['success'] and result[0]['count'] == 1
                    assert result[1]['success'] and len(requests) == 2
                    if scenario == 'httpfail':
                        assert 'HTTP 500' in result[0]['response']
                        assert 'upstream rejected request' in result[0]['response']
                if method == 'thread':
                    result, requests = execute(method,[{'prompt':'shortstream'}])
                    assert result[0]['success'], result[0]['response']
                    assert any(m['role'] == 'tool' for m in result[0]['messages'])
                    assert len(requests) == 2
                    for scenario, expected in (('noterminal','missing data: [DONE]'),
                                               ('badjson','Invalid streaming response:'),
                                               ('providererr','Provider stream error: quota exceeded'),
                                               ('finishbad','finish_reason="length"')):
                        result, requests = execute(method,[{'prompt':scenario}])
                        assert not result[0]['success'] and result[0]['count'] == 1
                        assert expected in result[0]['response'], result[0]['response']
                        assert 'Raw model stream tail' in result[0]['response']
                # Many small turns trigger repeated summaries while retaining two prior turns.
                steps = [{'prompt':'seed:6000','budget':24000,'recent':2} for _ in range(16)]
                result, requests = execute(method, steps)
                assert all(r['success'] for r in result), result[-1]['response']
                assert Handler.summary_count >= 2
                assert result[-1]['summary'] and result[-1]['count'] < 32
                recent = result[-1]['messages'][-6:]
                assert [m['role'] for m in recent] == ['user','assistant']*3
                assert all(len(m['content']) > 6000 for m in recent if m['role']=='assistant')
                # Lowering the budget compacts a large prefix through multiple bounded batches.
                seeds = [{'prompt':'seed:18000','budget':300000,'recent':0} for _ in range(6)]
                result, requests = execute(method, seeds+[{'prompt':'continue','budget':12000,'recent':0}])
                assert result[-1]['success'], result[-1]['response']
                assert Handler.summary_count >= 3
                for request in requests:
                    if request.get('max_tokens'):
                        estimate = (len(json.dumps(request['messages'],ensure_ascii=False).encode())+2)//3 + 8*len(request['messages'])
                        assert estimate+2048 <= 12000
                result, requests = execute(method, seeds+[{'prompt':'continue','budget':12000,'recent':0},{'prompt':'retry'}],fail=2)
                assert not result[-2]['success'] and result[-1]['success']
                assert result[-2]['count'] == 12
                assert result[-2]['messages'] == result[-3]['messages']
                assert result[-2]['summary'] == '' and Handler.summary_count > 2
                for kind in ('empty','tool','length','oversized'):
                    result, requests = execute(method,seeds+[{'prompt':'continue','budget':12000,'recent':0}],summary_kind=kind)
                    assert not result[-1]['success'] and result[-1]['messages'] == result[-2]['messages']
                seeded_summary = [{'summary':'Previous architectural decisions.', **seeds[0]}] + seeds[1:]
                result, requests = execute(method,seeded_summary+[{'prompt':'continue','budget':12000,'recent':0}],fail=2)
                assert not result[-1]['success']
                assert result[-1]['summary'] == 'Previous architectural decisions.'
                assert result[-1]['messages'] == result[-2]['messages']
                result, requests = execute(method,[{'prompt':'huge','budget':12000},{'prompt':'blocked'},{'prompt':'resume','budget':100000}])
                assert not result[0]['success'] and not result[1]['success'] and result[2]['success']
                assert result[0]['count'] == result[1]['count'] == 3
                assert 'z'*70000 in result[0]['messages'][-1]['content']
                assert len(requests) == 2
                # A huge indivisible older turn must not be silently truncated for summarization.
                result, requests = execute(method,[{'prompt':'seed:90000','budget':300000,'recent':0},{'prompt':'next'},{'prompt':'small','budget':12000,'recent':0}])
                assert not result[-1]['success'] and result[-1]['messages'] == result[-2]['messages']
                assert Handler.summary_count == 0
                result, requests = execute(method,[{'prompt':'cancelbatch','cancel_tools':True},{'prompt':'continue'}])
                assert not result[0]['success'] and result[1]['success']
                assert result[0]['count'] == 4
                assert 'cancelled' in result[0]['messages'][-1]['content']
                result, requests = execute(method,seeds+[{'prompt':'continue','budget':12000,'recent':0,'cancel_summary':True},{'prompt':'retry'}])
                assert not result[-2]['success'] and result[-1]['success']
                assert result[-2]['messages'] == result[-3]['messages'] and result[-2]['summary'] == ''
                # Each invocation creates an independent chat.
                result, requests = execute(method,[{'prompt':'isolated'}])
                assert result[0]['count'] == 2 and len(requests[0]['messages']) == 2
            print(f'Conversation/context integration tests passed ({count} scenarios, sync and worker).')
    finally:
        server.shutdown(); server.server_close(); worker.join()

if __name__ == '__main__': run(sys.argv[1])
