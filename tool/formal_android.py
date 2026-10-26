import hashlib,json,os,re,subprocess,sys,tempfile,zipfile
from pathlib import Path
REPO='kurumiZafkiel12/Hotaru'
CERT='7963ba5a3728d320e82cdfb43d58f7d32bdffd419113e2850de7ea2f2b987faa'
ABIS=['arm64-v8a','armeabi-v7a','x86_64']
def run(*args): return subprocess.check_output(args,text=True).strip()
def sha(p):
 with p.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def inspect(version):
 tools=next(p for p in sorted((Path(os.environ['ANDROID_HOME'])/'build-tools').iterdir(),reverse=True) if (p/'apksigner').exists() and (p/'aapt').exists())
 rows=[]
 for abi in ABIS:
  files=list(Path('dist').rglob(f'*-android-{abi}.apk'));assert len(files)==1
  p=files[0];meta=run(str(tools/'aapt'),'dump','badging',str(p))
  m=re.search(r"package: name='([^']+)' versionCode='([^']+)' versionName='([^']+)'",meta)
  assert m and m[1]=='dev.hotaru.hotaru' and m[3]==version and int(m[2])%1000==int(version[-1])+9
  signing=run(str(tools/'apksigner'),'verify','--verbose','--print-certs',str(p))
  certificates=re.findall(r'certificate SHA-256 digest:\s*(\w+)',signing);assert certificates and set(certificates)=={CERT}
  with zipfile.ZipFile(p) as z:
   assert z.testzip() is None
   assert all(f'lib/{abi}/{lib}' in z.namelist() for lib in ['libclash.so','librust_api.so','libflutter.so','libapp.so'])
  dest=Path('android-release')/f'Hotaru-{version}-android-{abi}.apk';dest.write_bytes(p.read_bytes())
  rows.append({'name':dest.name,'abi':abi,'version':version,'version_code':int(m[2]),'package':m[1],'certificate_sha256':CERT,'sha256':sha(dest)})
 Path('android-release/verification.json').write_text(json.dumps(rows,indent=2));print(json.dumps(rows))
def publish():
 versions=['0.0.1','0.0.2'];reports={}
 for v in versions:
  root=Path('signed')/f'formal-{v}';rows=json.loads((root/'verification.json').read_text());assert len(rows)==3
  for r in rows:assert r['certificate_sha256']==CERT and r['package']=='dev.hotaru.hotaru' and sha(root/r['name'])==r['sha256']
  reports[v]=(root,rows)
 for abi in ABIS:assert next(r['version_code'] for r in reports['0.0.2'][1] if r['abi']==abi)>next(r['version_code'] for r in reports['0.0.1'][1] if r['abi']==abi)
 for v,(root,rows) in reports.items():
  tag='v'+v;release=json.loads(run('gh','api',f'repos/{REPO}/releases/tags/{tag}'))
  with tempfile.TemporaryDirectory() as tmp:
   t=Path(tmp);subprocess.run(['gh','release','download',tag,'--repo',REPO,'--pattern','SHA256SUMS','--dir',tmp],check=True)
   checksum=t/'SHA256SUMS';old=checksum.read_text();lines=[l for l in old.splitlines() if '-android-' not in l]
   assert any('-windows-' in l for l in lines)
   checksum.write_text('\n'.join(lines+[f'{r["sha256"]}  {r["name"]}' for r in rows])+'\n')
   for r in rows:
    subprocess.run(['gh','release','upload',tag,'--repo',REPO,str(root/r['name']),'--clobber'],check=True)
    subprocess.run(['gh','release','download',tag,'--repo',REPO,'--pattern',r['name'],'--dir',tmp],check=True)
    assert sha(t/r['name'])==r['sha256']
   subprocess.run(['gh','release','upload',tag,'--repo',REPO,str(checksum),'--clobber'],check=True)
   body=release['body'].split('<!-- android-v002-supplement -->')[0]
   body='\n'.join(l for l in body.splitlines() if 'Android：' not in l and '安卓为调试签名' not in l)
   banner=f'## Android 正式签名重建 · {v}\n\n三个 Android APK 已使用固定正式密钥重建，包名 `dev.hotaru.hotaru`。证书 SHA256：`{CERT}`。先备份并卸载旧 `.dev` 调试包，再安装正式签名 0.0.1，随后安装正式签名 0.0.2 测试覆盖升级。不要卸载两次正式包之间的升级；实际数据保留仍需实机验证。Windows 资产未改。\n\n'
   notes=t/'notes.md';notes.write_text(banner+body)
   subprocess.run(['gh','release','edit',tag,'--repo',REPO,'--notes-file',str(notes)],check=True)
if __name__=='__main__':
 if sys.argv[1]=='inspect':inspect(sys.argv[2])
 else:publish()
