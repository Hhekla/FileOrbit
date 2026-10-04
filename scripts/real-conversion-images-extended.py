#!/usr/bin/env python3
"""Verify real image conversions using an explicit fixture manifest; retain all artifacts.
Fixture preparation is separate; no tests pretend a renamed non-RAW file is RAW.
Native sips reference decoding is used for camera RAW/HEIF/JXL; Pillow/LittleCMS
checks displayed sRGB colors. Synthetic EXR uses a known linear-to-sRGB oracle.
"""
import argparse,pathlib,json,hashlib,subprocess,shutil,time,io,zipfile,struct,xml.etree.ElementTree as ET
from PIL import Image,ImageOps,ImageCms
import numpy as np
import pypdfium2 as pdfium

def run(a,timeout=180):
 p=subprocess.run([str(v) for v in a],capture_output=True,text=True,timeout=timeout);return dict(command=[str(v) for v in a],exit_code=p.returncode,stdout=p.stdout,stderr=p.stderr)
def save(p,d):p.write_text(json.dumps(d,ensure_ascii=False,indent=2))
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def pil(p):
 im=Image.open(p);im=ImageOps.exif_transpose(im);icc=im.info.get('icc_profile')
 if im.mode.startswith('I;16') or im.mode=='I':im=Image.fromarray((np.asarray(im,dtype=float)/257).clip(0,255).astype('uint8'))
 alpha=im.convert('RGBA').getchannel('A')
 if icc:
  color=im.convert('RGB') if im.mode=='RGBA' else im
  im=ImageCms.profileToProfile(color,ImageCms.ImageCmsProfile(io.BytesIO(icc)),ImageCms.createProfile('sRGB'),outputMode='RGB')
 im=im.convert('RGBA');im.putalpha(alpha);return im
def decode(p,folder):
 try:
  if p.suffix.lower() in ['.dng','.cr2','.cr3','.nef','.arw','.raf','.orf','.rw2','.srw','.pef','.heif','.heic','.jxl','.exr']:raise ValueError('native reference')
  im=pil(p)
  if p.suffix.lower()=='.avif':
   q=run(['/opt/homebrew/bin/ffprobe','-v','error','-select_streams','v:0','-show_entries','stream=color_transfer','-of','json',p])
   if q['exit_code']==0 and any(x.get('color_transfer')=='linear' for x in json.loads(q['stdout']).get('streams',[])):
    a=np.asarray(im,dtype=float)/255;rgb=a[:,:,:3];a[:,:,:3]=np.where(rgb<=.0031308,12.92*rgb,1.055*np.power(rgb,1/2.4)-.055);im=Image.fromarray(np.round(a.clip(0,1)*255).astype('uint8'))
  return im
 except Exception:
  dest=folder/(p.name+'-reference.png');r=run(['/usr/bin/sips','-s','format','png',p,'--out',dest]);save(folder/(p.name+'-reference.json'),r)
  if r['exit_code'] or not dest.exists():
   # TIFF-based Nikon scanner NEF contains a full RGB SubIFD independent of its
   # small preview. Decode that actual pixel data without changing the fixture.
   if p.suffix.lower()=='.nef':
    preview=Image.open(p);offset=preview.tag_v2.get(330,(None,))[0]
    if offset:
     raw=bytearray(p.read_bytes());struct.pack_into('<I' if raw[:2]==b'II' else '>I',raw,4,offset)
     full=Image.open(io.BytesIO(raw));full.load()
     if full.mode=='RGB':full.save(folder/(p.name+'-pillow-full-subifd.png'));return full.convert('RGBA')
   raise ValueError('reference decode failed: '+r['stderr'])
  return pil(dest)
def flat(im):
 rgba=im.convert('RGBA');bg=Image.new('RGBA',rgba.size,'white');bg.alpha_composite(rgba);return bg.convert('RGB')
def compare(im,ref):
 size=im.size==ref.size
 # Downsample solely for verification metrics; original output size separately checked.
 a=np.asarray(flat(im).resize((320,240)),dtype=float);b=np.asarray(flat(ref).resize((320,240)),dtype=float)
 mae=float(abs(a-b).mean());std=float(a.std())
 return {'decodable':True,'dimensions':list(im.size),'dimensions_match':size,'mean_absolute_rgb_error':round(mae,3),'content_matches':mae<24,'nonblank':std>4}
def validate(p,t,ref,entry,folder):
 finder=run(['/usr/bin/xattr','-px','com.apple.FinderInfo',p]);data=bytes.fromhex(finder['stdout']) if finder['exit_code']==0 else b'';invisible=len(data)>=10 and bool(int.from_bytes(data[8:10],'big')&0x4000)
 ck={'exists':p.is_file(),'nonzero_size':p.stat().st_size>0,'visible_in_finder':not p.name.startswith('.') and not(getattr(p.stat(),'st_flags',0)&0x8000) and not invisible};required=list(ck)
 if t=='pdf':
  pdf=pdfium.PdfDocument(str(p));ck['page_count']=len(pdf);page=pdf[0];im=page.render(scale=ref.width/page.get_width()).to_pil().resize(ref.size);im.save(folder/'pdf-page1.png')
 elif t=='docx':
  with zipfile.ZipFile(p) as z:
   names=[n for n in z.namelist() if n.startswith('word/media/')];ck['embedded_images']=len(names);im=pil(io.BytesIO(z.read(names[0])))
   tree=ET.fromstring(z.read('word/document.xml'));text=''.join(x.text or '' for x in tree.iter('{http://schemas.openxmlformats.org/wordprocessingml/2006/main}t'));ck['ocr_text_present']=len(text)>0
   if entry.get('text_expected') and ref.width>=600:ck['ocr_english_recognized']='fileorbit' in text.lower().replace(' ','');required.append('ocr_english_recognized')
 elif t=='mp4':
  q=run(['/opt/homebrew/bin/ffprobe','-v','error','-count_frames','-show_streams','-show_format','-of','json',p]);save(folder/'ffprobe.json',q);probe=json.loads(q['stdout']);v=next(v for v in probe['streams'] if v['codec_type']=='video');duration=float(v.get('duration',probe['format']['duration']));ck['duration_seconds']=duration;ck['duration_matches']=abs(duration-sum(entry['durations'])/1000)<0.06;required+=['duration_matches']
  timing=run(['/opt/homebrew/bin/ffprobe','-v','error','-select_streams','v:0','-show_entries','frame=pts_time','-of','json',p]);frames=json.loads(timing['stdout']).get('frames',[]);pts=[float(frame['pts_time']) for frame in frames];delays=[(pts[i+1] if i+1<len(pts) else duration)-pts[i] for i in range(len(pts))];ck['frame_delays_seconds']=delays;ck['frame_delays_match']=len(delays)==len(entry['durations']) and all(abs(x-y/1000)<0.006 for x,y in zip(delays,entry['durations']));required+=['frame_delays_match']
  original=Image.open(entry['path']);matching=[];frame_images=[]
  for index in range(len(entry['durations'])):
   path=folder/('decoded-frame-'+str(index)+'.png');r=run(['/opt/homebrew/bin/ffmpeg','-y','-v','error','-i',p,'-vf',f'select=eq(n\\,{index})','-frames:v','1',path]);original.seek(index);actual=pil(path);matching.append(compare(actual,original)['content_matches']);frame_images.append(actual)
  im=frame_images[0];ck['all_animation_frame_contents_match']=all(matching);required+=['all_animation_frame_contents_match']
 else:im=decode(p,folder)
 ck.update(compare(im,ref));required+=['dimensions_match','content_matches','nonblank']
 if t in ['png','webp','tiff','heic','avif']:
  a=np.asarray(ref)[:,:,3];b=np.asarray(im)[:,:,3]
  if a.min()<255 and a.shape==b.shape:ck['alpha_preserved']=float(abs(a.astype(float)-b.astype(float)).mean())<3;required+=['alpha_preserved']
 if t=='webp' and (entry.get('durations') is not None or entry['variant']=='APNG-two-frames'):
  im=Image.open(p);dur=[];matching=[];original=Image.open(entry['path'])
  for i in range(im.n_frames):
   im.seek(i);im.load();dur.append(im.info.get('duration'));original.seek(i);matching.append(compare(im,original)['content_matches'])
  ck['all_animation_frame_contents_match']=all(matching);required+=['all_animation_frame_contents_match']
  ck.update(animation_frames=im.n_frames,animation_duration_ms=dur,animation_preserved=im.n_frames==len(entry.get('durations',[200,400])) and dur==entry.get('durations',[200,400]) and im.info.get('loop')==entry.get('loop',3));required+=['animation_preserved']
 if entry['variant'].startswith('TIFF-'):
  expected_pages=entry.get('expected_pages',2)
  ck['multipage_source_pages']=expected_pages;ck['pages_preserved']=(t=='pdf' and ck.get('page_count')==expected_pages) or (t=='docx' and ck.get('embedded_images')==expected_pages)
  required+=['pages_preserved']
  page_checks=[];original=Image.open(entry['path'])
  for index in range(expected_pages):
   original.seek(index);expected=original.convert('RGBA')
   if t=='pdf' and index<len(pdf):
    pg=pdf[index];actual=pg.render(scale=expected.width/pg.get_width()).to_pil().resize(expected.size)
   elif t=='docx' and index<len(names):
    with zipfile.ZipFile(p) as archive:actual=pil(io.BytesIO(archive.read(names[index])))
   else:page_checks.append(False);continue
   page_checks.append(compare(actual,expected)['content_matches'])
  ck['all_pages_content_match']=all(page_checks);required+=['all_pages_content_match']
 ck['required_checks']=required;return ck,all(ck[k] for k in required)
def main():
 ap=argparse.ArgumentParser();ap.add_argument('--exe',required=True);ap.add_argument('--root',required=True);ap.add_argument('--resume',action='store_true');ap.add_argument('--only-sources');ap.add_argument('--only-variants');a=ap.parse_args();root=pathlib.Path(a.root).resolve();exe=pathlib.Path(a.exe).resolve();s=root/'sources';refs=root/'source-validation';refs.mkdir(exist_ok=True)
 entries=json.loads((s/'synthetic-manifest.json').read_text())
 if (s/'additional-raw-manifest.json').exists():entries.update(json.loads((s/'additional-raw-manifest.json').read_text()))
 for ext,x in json.loads((root/'downloads/download-manifest.json').read_text()).items():
  if x.get('download_ok'):entries['cc0-camera.'+ext]={'path':x['path'],'variant':'CC0-camera-'+x['camera'],'reference':None,'text_expected':False,'provenance':x}
 report={'executable':str(exe),'executable_sha256':sha(exe),'cases':[],'fixtures':entries,'unavailable_fixtures':[]};result=root/'results.json'
 if a.resume and result.exists():report=json.loads(result.read_text());report['fixtures']=entries
 done={(c['source_format'],c['target_format'],c['fixture_variant']) for c in report['cases']}
 for name,entry in entries.items():
  source=pathlib.Path(entry['path']);fmt=source.suffix[1:];variant=entry['variant']
  if a.only_sources and fmt not in a.only_sources.split(','):continue
  if a.only_variants and variant not in a.only_variants.split(','):continue
  action=run([exe,'actions',source]);save(refs/(name+'-actions.json'),action);targets=action['stdout'].splitlines()[0].split(':',1)[1].lower().split()
  try:ref=pil(entry['reference']) if entry.get('reference') else decode(source,refs);reference_error=None
  except Exception as e:ref=None;reference_error=str(e)
  for target in targets:
   if entry.get('targets') and target not in entry['targets']:continue
   if (fmt,target,variant) in done:continue
   d=root/'cases'/(source.stem+'-'+fmt+'-to-'+target);d.mkdir(parents=True,exist_ok=True);input=d/source.name
   if not input.exists():shutil.copy2(source,input)
   before=sha(source);case={'source_format':fmt,'target_format':target,'fixture_variant':variant,'input':str(input),'outputs':[],'checks':{}};start=time.monotonic()
   try:
    r=run([exe,'convert',input,'--to',target,'--json']);save(d/'invocation.json',r);data=json.loads(r['stdout']);case['outputs']=data.get('outputs',[])
    if r['exit_code'] or data.get('succeededInputs')!=1 or len(case['outputs'])!=1:
     error='; '.join(f.get('message','') for f in data.get('failures',[]));case.update(status='failed',error=error)
     if target=='avif' and '透明' in error and not case['outputs']:case.update(status='expected_rejection',checks={'transparent_avif_rejected_clearly':True})
     if variant.startswith('TIFF-') and target not in ['pdf','docx'] and '多页 TIFF' in error and not case['outputs']:case.update(status='expected_rejection',checks={'multipage_loss_rejected_clearly':True})
     if variant=='APNG-separate-poster' and '独立封面' in error and not case['outputs']:case.update(status='expected_rejection',checks={'unsupported_poster_variant_rejected_clearly':True,'no_wrong_frames_published':True})
    elif ref is None:case.update(status='unverified',error=reference_error)
    else:
     ck,ok=validate(pathlib.Path(case['outputs'][0]),target,ref,entry,d);case.update(checks=ck,status='passed' if ok else 'failed')
     if not ok:case['error']='Failed semantic checks: '+', '.join(k for k in ck['required_checks'] if not ck[k])
   except Exception as e:case.update(status='failed',error=str(e))
   case['checks']['original_sha256_unchanged']=before==sha(source)==sha(input)
   if not case['checks']['original_sha256_unchanged']:case.update(status='failed',error='Original fixture changed')
   case['elapsed_seconds']=round(time.monotonic()-start,3);report['cases'].append(case);save(result,report);print(fmt,variant,'->',target,case['status'],case.get('error','')[:150],flush=True)
 report['summary']={key:sum(c['status']==key for c in report['cases']) for key in ['passed','failed','expected_rejection','unverified']};report['summary'].update(cases=len(report['cases']),unique_directions=len({(c['source_format'],c['target_format']) for c in report['cases']}));save(result,report);print(report['summary'],flush=True)
if __name__=='__main__':main()
