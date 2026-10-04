"""Integration fixtures for native tools. Run through tests/run_tests.sh."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time


def run(driver):
    count = 0
    with tempfile.TemporaryDirectory(prefix='coding-agent-fixtures-') as temporary:
        root = Path(temporary) / 'project'
        root.mkdir()
        process = subprocess.Popen([driver, str(root)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        def call(tool, args=None, mode='Agent', **extra):
            nonlocal count
            process.stdin.write(json.dumps(dict(tool=tool, args=args or {}, mode=mode, **extra))+'\n')
            process.stdin.flush()
            line = process.stdout.readline()
            assert line, f'driver exited during {tool}'
            count += 1
            return json.loads(line)
        def ok(tool, args=None, **extra):
            result = call(tool, args, **extra)
            assert 'error' not in result, (tool, result)
            return result
        def error(tool, args=None, **extra):
            result = call(tool, args, **extra)
            assert isinstance(result.get('error'), str), (tool, result)
            return result
        def patch(text):
            return ok('apply_patch', {'patch':text})
        try:
            canonical = {'read_file','write_file','list_directory','glob','search_code','apply_patch','shell','diagnostics','git','todo','create_plan_file'}
            declarations = call('_declarations')
            assert {d['function']['name'] for d in declarations} == canonical
            readonly = {'read_file','list_directory','glob','search_code','diagnostics','git','todo'}
            assert {d['function']['name'] for d in call('_declarations', mode='Ask')} == readonly
            assert {d['function']['name'] for d in call('_declarations', mode='Plan')} == readonly | {'create_plan_file'}
            for mode in ('Ask','Plan'):
                for tool,args in [('write_file',{'path':'denied','content':'bad'}), ('terminal',{'command':'touch denied'}), ('edit_file',{'path':'denied','old_text':'a','new_text':'b'}), ('apply_patch',{'patch':'bad'}), ('diagnostics',{'action':'build','target':'bad.pas'})]:
                    error(tool, args, mode=mode)
            assert not (root/'denied').exists()
            error('read_file', '{bad')
            error('read_file', '[]')
            error('read_file', {'path':42})
            error('write_file', {'path':'missing-content'})
            assert not (root/'missing-content').exists()
            ok('write_file', {'path':'empty.txt','content':''})
            assert ok('read_file', {'path':'empty.txt'})['lines_returned'] == 0
            error('read_file', {'path':'empty.txt','offset':2})
            for offset,limit in [(0,1),(1,0),(1,-1),(1,2001)]:
                error('read_file', {'path':'empty.txt','offset':offset,'limit':limit})
            text = '\ufeffalpha\r\nbeta\r\n'
            ok('write_file', {'path':'src/main.pas','content':text})
            assert (root/'src/main.pas').read_bytes() == text.encode()
            assert ok('read_file', {'path':'src/main.pas','offset':2,'limit':1})['content'].startswith('2|beta')
            quoted = 'quote"name.txt'
            error('read_file', {'path':quoted})
            (root/'binary').write_bytes(b'abc\x00def')
            error('read_file', {'path':'binary'})
            (root/'invalid-encoding').write_bytes(b'\xff')
            error('read_file', {'path':'invalid-encoding'})
            os.mkfifo(root/'pipe')
            error('read_file', {'path':'pipe'})
            error('write_file', {'path':'pipe','content':'x'})
            (root/'pipe').unlink()
            for path in ('../escape.txt',str(Path(temporary)/'escape.txt')):
                error('write_file', {'path':path,'content':'x'})
            outside = Path(temporary)/'outside'; outside.mkdir()
            (root/'link').symlink_to(outside, target_is_directory=True)
            error('write_file', {'path':'link/new','content':'x'})
            error('list_files', {'path':'link'})
            (root/'.plan').symlink_to(outside, target_is_directory=True)
            error('create_plan_file', {'content':'# Plan'}, mode='Plan')
            (root/'.plan').unlink()
            assert not list(outside.iterdir())
            (root/'.plan').symlink_to(root/'src', target_is_directory=True)
            error('create_plan_file', {'content':'# Plan'}, mode='Plan')
            assert not list((root/'src').glob('plan-*.md'))
            (root/'.plan').unlink()
            (root/'.plan').symlink_to(root/'missing-plans', target_is_directory=True)
            error('create_plan_file', {'content':'# Plan'}, mode='Plan')
            assert not (root/'missing-plans').exists()
            (root/'.plan').unlink()
            plan = ok('create_plan_file', {'content':'# Plan'}, mode='Plan')
            assert Path(plan['path']).read_text() == '# Plan'
            assert Path(plan['path']).parent == root/'.plan'
            assert Path(plan['path']).suffix == '.md'
            second_plan = ok('create_plan_file', {'content':'# Second plan'}, mode='Plan')
            assert second_plan['path'] != plan['path']
            assert Path(second_plan['path']).parent == root/'.plan'
            assert Path(second_plan['path']).suffix == '.md'
            assert Path(plan['path']).read_text() == '# Plan'
            for path in ('outside-plan.md', '.plan/custom.md', '.plan/custom.pas'):
                error('write_file', {'path':path,'content':'denied'}, mode='Plan')
                assert not (root/path).exists()
            (root/'inside').symlink_to(root/'src', target_is_directory=True)
            assert ok('read_file', {'path':'inside/main.pas'})['total_lines'] == 2
            (root/'link').unlink()
            entries = ok('list_directory')['entries']
            assert any(e['path']=='src' and e['type']=='directory' for e in entries)
            assert [e['path'] for e in entries] == sorted(e['path'] for e in entries)
            ok('write_file', {'path':'src/nested/unit.pas','content':'CreateUser\nCreateUser\n'})
            ok('write_file', {'path':'root.pas','content':'createuser\n'})
            ok('write_file', {'path':'.hidden.pas','content':'CreateUser\n'})
            ok('write_file', {'path':'bin/generated.pas','content':'CreateUser\n'})
            found = [e['path'] for e in ok('glob',{'pattern':'**/*.pas'})['entries']]
            assert found == ['root.pas','src/main.pas','src/nested/unit.pas'], found
            assert [e['path'] for e in ok('glob',{'pattern':'src/?ain.pas'})['entries']] == ['src/main.pas']
            assert any(e['path']=='.hidden.pas' for e in ok('glob',{'pattern':'**/*.pas','include_hidden':True})['entries'])
            assert ok('list_files', {'extension':'*.pas'})['total_files'] == 3
            assert [e['path'] for e in ok('glob', {'pattern':'src/**/*.pas','path':'src'})['entries']] == ['src/main.pas','src/nested/unit.pas']
            result = ok('grep', {'query':'CreateUser'})
            assert len(result['matches']) == 2 and result['matches'][0]['column']==1
            assert len(ok('search_code', {'query':'createuser','case_sensitive':False})['matches']) == 3
            assert len(ok('search_code', {'query':'Create.*','regex':True,'glob':'src/**/*.pas'})['matches']) == 2
            assert ok('search_code', {'query':'nothing'})['matches'] == []
            error('search_code', {'query':'[','regex':True})
            for index in range(510):
                (root/f'item-{index:03d}.txt').write_text('needle\n')
            result = ok('glob', {'pattern':'item-*'})
            assert len(result['entries']) == 500 and result['truncated']
            result = ok('search_code', {'query':'needle'})
            assert len(result['matches']) == 500 and result['truncated']
            patch('--- a/src/main.pas\n+++ b/src/main.pas\n@@ -1,2 +1,2 @@\n alpha\n-beta\n+gamma\n')
            assert (root/'src/main.pas').read_bytes() == '\ufeffalpha\r\ngamma\r\n'.encode()
            ok('edit_file',{'path':'src/main.pas','old_text':'gamma','new_text':'delta'})
            assert (root/'src/main.pas').read_bytes() == '\ufeffalpha\r\ndelta\r\n'.encode()
            error('edit_file',{'path':'src/nested/unit.pas','old_text':'CreateUser','new_text':'x'})
            original = (root/'src/main.pas').read_bytes()
            error('apply_patch',{'patch':'--- a/src/main.pas\n+++ b/src/main.pas\n@@ -1 +1 @@\n-alpha\n+new\n--- a/root.pas\n+++ b/root.pas\n@@ -1 +1 @@\n-mismatch\n+new\n'})
            assert (root/'src/main.pas').read_bytes() == original
            patch('--- /dev/null\n+++ b/patch-empty.txt\n@@ -0,0 +0,0 @@\n')
            assert (root/'patch-empty.txt').read_bytes() == b''
            patch('--- /dev/null\n+++ b/new.txt\n@@ -0,0 +1 @@\n+hello\n')
            assert (root/'new.txt').read_bytes()==b'hello\n'
            patch('--- a/new.txt\n+++ /dev/null\n@@ -1 +0,0 @@\n-hello\n')
            assert not (root/'new.txt').exists()
            (root/'nonewline').write_bytes(b'old')
            patch('--- a/nonewline\n+++ b/nonewline\n@@ -1 +1 @@\n-old\n\\ No newline at end of file\n+new\n\\ No newline at end of file\n')
            assert (root/'nonewline').read_bytes()==b'new'
            error('apply_patch',{'patch':'--- /dev/null\n+++ b/../escape.txt\n@@ -0,0 +1 @@\n+x\n'})
            error('apply_patch',{'patch':'--- a/root.pas\n+++ b/root.pas\n@@ -1,2 +1 @@\n-createuser\n+new\n'})
            # Detect changes without Git, including hidden files and deletion.
            (root/'pre-existing').write_text('already changed')
            (root/'remove-me').write_text('old')
            (root/'modify-me').write_text('old')
            result = ok('shell', {'command': "printf new > modify-me; rm remove-me; printf config > .config; mkdir -p .plan bin; touch .plan/ignored bin/ignored; printf created > created"})
            assert set(result['changed_paths']) == {str(root/p) for p in ('modify-me','remove-me','.config','created')}, result
            result = ok('shell', {'command':'true'})
            assert result['changed_paths']==[], result
            # Unsupported entries cause an explicit warning without losing command results.
            os.mkfifo(root/'tracking-pipe')
            result = ok('shell', {'command':'printf still-runs'})
            assert result['stdout']=='still-runs' and 'incomplete' in result['tracking_warning']
            (root/'tracking-pipe').unlink()
            assert ok('terminal',{'command':'printf out; printf err >&2; exit 7'})['exit_code']==7
            result = ok('shell',{'command':'python3 -c "import os; os.write(1,b\'x\'*1100000); os.write(2,b\'y\'*1100000)"'})
            assert len(result['stdout'])==1024*1024 and len(result['stderr'])==1024*1024
            assert result['stdout_truncated'] and result['stderr_truncated']
            result = ok('shell', {'command':"python3 -c \"import os; os.write(1,bytes([255,195]))\""})
            assert result['stdout'] == '\ufffd\ufffd'
            started=time.monotonic()
            result = ok('shell',{'command':'sleep 10 & echo $! > child.pid; wait','timeout_ms':100})
            assert result['timed_out'] and time.monotonic()-started < 3
            child=int((root/'child.pid').read_text())
            time.sleep(.05)
            stat=Path(f'/proc/{child}/stat')
            assert not stat.exists() or stat.read_text().split()[2]=='Z', 'child still running'
            result = ok('shell',{'command':'sleep 10'}, cancel_after_ms=100)
            assert result['cancelled']
            result = ok('shell',{'command':'touch before-cancel; sleep 10'}, cancel_after_ms=100)
            assert result['cancelled'] and str(root/'before-cancel') in result['changed_paths']
            error('shell',{'command':'true','timeout_ms':600001})
            error('git',{'operation':'status'})
            subprocess.run(['git','init','-q',str(root)],check=True)
            subprocess.run(['git','-C',str(root),'add','root.pas'],check=True)
            subprocess.run(['git','-C',str(root),'-c','user.name=Test','-c','user.email=test@example.invalid','commit','-qm','initial'],check=True)
            for operation in ('status','diff','log','show'):
                assert ok('git',{'operation':operation}, mode='Ask')['exit_code']==0
            error('git',{'operation':'reset'})
            error('git',{'operation':'show','revision':'--help'})
            ok('write_file',{'path':'ok.pas','content':'program ok; begin end.\n'})
            result = ok('diagnostics',{'action':'build','target':'ok.pas'})
            assert result['status']=='success' and result['target'].endswith('ok.pas')
            assert str(root/'ok') in result['changed_paths']
            assert not (root/'ok.ran').exists()
            assert ok('diagnostics',{'action':'read'},mode='Ask')['target']==result['target']
            ok('write_file',{'path':'bad.pas','content':'program bad; begin MissingIdentifier; end.\n'})
            result = ok('diagnostics',{'action':'build','target':'bad.pas'})
            assert result['status']=='failed' and any(m.get('line')==1 and m['severity']=='error' for m in result['messages'])
            error('diagnostics',{'action':'build'})
            tasks=[{'id':'one','text':'Refactor','status':'in_progress'},{'id':'two','text':'Verify','status':'pending'}]
            assert ok('plan',{'action':'replace','items':tasks},mode='Plan')['items']==tasks
            assert ok('todo',{'action':'read'},mode='Ask')['items']==tasks
            error('todo',{'action':'replace','items':tasks+[tasks[0]]})
            assert ok('todo',{'action':'read'})['items']==tasks
            error('todo',{'action':'replace','items':[{'id':'x','text':'x','status':'unknown'}]})
            assert ok('_fallback',text='```json\n'+json.dumps({'name':'grep','arguments':{'query':'needle'}})+'\n```')['total_matches']==500
            ok('_clear')
            assert ok('todo',{'action':'read'})['items']==[]
            assert ok('diagnostics',{'action':'read'})['status']=='unavailable'
            isolated = subprocess.run([driver,str(root)], input=json.dumps({'tool':'search_code','args':{'query':'x'}})+'\n'+json.dumps({'tool':'git','args':{'operation':'status'}})+'\n', env={**os.environ,'PATH':'/nonexistent'}, text=True, capture_output=True, timeout=5)
            assert isolated.returncode == 0
            unavailable = [json.loads(line) for line in isolated.stdout.splitlines()]
            assert 'ripgrep' in unavailable[0]['error'] and 'Git' in unavailable[1]['error']
            print(f'Local tool integration tests passed ({count} tool calls plus missing-dependency fixtures).')
        finally:
            process.stdin.close()
            process.wait(timeout=5)
            assert process.returncode==0

if __name__ == '__main__':
    run(sys.argv[1])
