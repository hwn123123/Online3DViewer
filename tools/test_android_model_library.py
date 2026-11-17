#!/usr/bin/env python3
"""Exercise isolated model import, deduplication, cache rebuild and deletion on a device."""
import argparse,hashlib,json,subprocess,time,tempfile


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--adb',default='adb');parser.add_argument('--device',required=True);args=parser.parse_args()
    adb=[args.adb,'-s',args.device];package='com.hwn.modelviewer'
    def run(*values,check=True):
        return subprocess.run(adb+list(values),capture_output=True,text=True,check=check,timeout=30).stdout.strip()
    def shell(*values,check=True):return run('shell','run-as',package,*values,check=check)
    def start(*extras):
        run('shell','am','force-stop',package)
        shell('rm','-f','cache/viewer-debug-status.json')
        run('shell','am','start','-n',package+'/.MainActivity','--ez','debug-library-test','true',*extras)
    def status(types,timeout=60):
        deadline=time.monotonic()+timeout
        while time.monotonic()<deadline:
            try:data=json.loads(shell('cat','cache/viewer-debug-status.json'))
            except (ValueError,subprocess.CalledProcessError):time.sleep(.25);continue
            if data.get('type') in types:return data
            time.sleep(.25)
        raise RuntimeError('No terminal status for '+str(types))
    def run_import():
        start('--es','debug-sample','import')
        s=status({'model_loaded','native_read_error','javascript_error'})
        assert s['type']=='model_loaded',s
        ident=s['manifestUrl'].split('/library/')[1].split('/')[0]
        return ident,s
    ident,state=run_import()
    directory='files/model-library-test/'+ident
    source=directory+'/android-test-teapot.stl';cache=directory+'/stream/manifest.json'
    before=shell('sha256sum','cache/android-test-teapot.stl').split()[0]
    manifest=shell('stat','-c','%Y:%s',cache)
    duplicate,_=run_import()
    assert duplicate==ident and shell('stat','-c','%Y:%s',cache)==manifest
    print('PASS import, duplicate recognition and cache reuse',flush=True)
    start('--es','debug-library-action','clear','--es','debug-action-item',ident)
    action=status({'library_action_complete'});assert action['action']=='clear'
    assert shell('test','-f',source,check=False)==''
    assert subprocess.run(adb+['shell','run-as',package,'test','-f',source]).returncode==0
    assert subprocess.run(adb+['shell','run-as',package,'test','-e',cache]).returncode!=0
    start('--es','debug-library-item',ident)
    result=status({'model_loaded','native_read_error','javascript_error'});assert result['type']=='model_loaded',result
    assert subprocess.run(adb+['shell','run-as',package,'test','-f',cache]).returncode==0
    print('PASS clear cache preserves model and regenerates it',flush=True)
    start('--es','debug-library-action','clear','--es','debug-action-item',ident)
    status({'library_action_complete'})
    start('--es','debug-library-item',ident,'--ez','debug-cancel-on-stream','true')
    status({'load_cancelled'})
    start('--es','debug-library-item',ident)
    result=status({'model_loaded','native_read_error','javascript_error'});assert result['type']=='model_loaded',result
    assert subprocess.run(adb+['shell','run-as',package,'test','-f',source]).returncode==0
    print('PASS cancellation preserves source and allows reopening',flush=True)
    item=json.loads(shell('cat',cache));name=item['objects'][0]['url']
    assert '/' not in name and name not in ('.','..')
    shell('truncate','-s','16',directory+'/stream/'+name)
    start('--es','debug-library-item',ident)
    result=status({'model_loaded','native_read_error','javascript_error'});assert result['type']=='model_loaded',result
    assert int(shell('stat','-c','%s',directory+'/stream/'+name))==item['objects'][0]['bytes']
    print('PASS truncated cache is detected and rebuilt',flush=True)
    # A large but valid manifest should be reused without a full Java JSON tree.
    large=dict(item);large['testPadding']='x'*(34*1024*1024)
    with tempfile.NamedTemporaryFile(mode='w',encoding='utf-8') as fixture:
        json.dump(large,fixture);fixture.flush()
        remote='/data/local/tmp/o3dv-large-manifest-test.json'
        try:
            run('push',fixture.name,remote)
            shell('cp',remote,cache)
        finally:run('shell','rm','-f',remote,check=False)
    original_size=int(shell('stat','-c','%s',cache));assert original_size>32*1024*1024
    start('--es','debug-library-item',ident)
    result=status({'model_loaded','native_read_error','javascript_error'});assert result['type']=='model_loaded',result
    assert int(shell('stat','-c','%s',cache))==original_size
    print('PASS large valid manifest is reused',flush=True)
    start('--es','debug-library-action','delete','--es','debug-action-item',ident)
    action=status({'library_action_complete'});assert action['action']=='delete'
    assert subprocess.run(adb+['shell','run-as',package,'test','-e',directory]).returncode!=0
    after=shell('sha256sum','cache/android-test-teapot.stl').split()[0]
    assert before==after
    print('PASS delete removes only app model copy; input fixture unchanged',flush=True)


if __name__=='__main__':main()
