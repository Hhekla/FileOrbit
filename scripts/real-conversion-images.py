#!/usr/bin/env python3
"""Run real shipping-app conversions; retain sources, outputs, logs and semantic checks.
Requires Pillow, numpy, pypdfium2 and the macOS sips/ffprobe tools.
No private files are read; no generated artifacts are removed.
"""
from __future__ import annotations
import argparse, hashlib, io, json, os, pathlib, shutil, subprocess, time, zipfile
import xml.etree.ElementTree as ET
from PIL import Image, ImageDraw, ImageFont, ImageStat
import numpy as np
import pypdfium2 as pdfium

def run(args, timeout=120):
    p = subprocess.run([str(x) for x in args], capture_output=True, text=True, timeout=timeout)
    return {'command': [str(x) for x in args], 'exit_code': p.returncode, 'stdout': p.stdout, 'stderr': p.stderr}

def save_json(path, data):
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding='utf8')

def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def flat(image):
    rgba = image.convert('RGBA'); white = Image.new('RGBA', rgba.size, 'white'); white.alpha_composite(rgba)
    return white.convert('RGB')

def decoded(path, validation):
    if path.suffix.lower() == '.heic':
        dest = validation / (path.stem + '-decoded.png')
        p = run(['/usr/bin/sips', '-s', 'format', 'png', path, '--out', dest])
        if p['exit_code'] != 0: raise ValueError('Independent HEIC decode failed: ' + p['stderr'])
        return Image.open(dest).convert('RGBA')
    with Image.open(path) as im:
        im.seek(0); return im.convert('RGBA')

def image_checks(image, reference):
    a, b = np.asarray(flat(image), dtype=float), np.asarray(flat(reference), dtype=float)
    size = list(image.size)
    if image.size != reference.size:
        return {'decodable': True, 'dimensions': size, 'dimensions_match': False, 'content_matches': False}
    mae = float(np.abs(a - b).mean())
    text_mae = float(np.abs(a[0:300, 0:900] - b[0:300, 0:900]).mean())
    return {'decodable': True, 'dimensions': size, 'dimensions_match': True,
            'mean_absolute_rgb_error': round(mae, 3), 'text_region_error': round(text_mae, 3),
            'content_matches': mae < 22 and text_mae < 22,
            'rgb_stddev': [round(float(x), 3) for x in a.std(axis=(0,1))],
            'nonblank': float(a.std()) > 20}

def make_sources(root, opaque=False):
    sources = root / 'sources'; sources.mkdir(parents=True, exist_ok=True)
    manifest = sources / 'manifest.json'
    if manifest.exists(): return json.loads(manifest.read_text())
    font = ImageFont.truetype('/System/Library/Fonts/STHeiti Medium.ttc', 44)
    small = ImageFont.truetype('/System/Library/Fonts/STHeiti Medium.ttc', 32)
    base = Image.new('RGBA', (960,640), 'white'); d=ImageDraw.Draw(base)
    d.text((35,30), 'FileOrbit 20261005', fill='#112233', font=font)
    d.text((35,105), '图片转换测试 中文内容', fill='#223344', font=font)
    d.text((35,180), 'ABC xyz 0123456789', fill='#223344', font=small)
    for x,color in [(35,'#e84645'),(245,'#37ae75'),(455,'#406ee5')]: d.rectangle((x,290,x+170,490), fill=color)
    d.ellipse((90,335,150,395), fill='white')
    d.rectangle((715,340,920,595), fill=(0,0,0,0))
    d.rectangle((760,390,870,500), fill=(190,55,190,128))
    if opaque: base=flat(base).convert('RGBA')
    entries={}
    for fmt in ['png','jpg','webp','tiff','avif','bmp']:
        dest=sources / ('sample.'+fmt)
        im=flat(base) if fmt in ['jpg','bmp'] else base
        params={'quality':95} if fmt=='jpg' else {'lossless':True} if fmt=='webp' else {'quality':95} if fmt=='avif' else {}
        im.save(dest, **params); entries[fmt]={'path':str(dest), 'sha256':sha(dest)}
    heic=sources/'sample.heic'
    p=run(['/usr/bin/sips','-s','format','heic',sources/'sample.png','--out',heic])
    save_json(sources/'heic-generation.json', p)
    if p['exit_code']==0 and heic.exists(): entries['heic']={'path':str(heic),'sha256':sha(heic)}
    else: entries['heic']={'generation_error':p}
    f1=flat(base); f2=f1.copy(); d2=ImageDraw.Draw(f2); d2.rectangle((245,290,415,490),fill='#ffa020');d2.text((680,260),'FRAME 2',fill='#112233',font=small)
    gif=sources/'sample.gif';f1.save(gif,save_all=True,append_images=[f2],duration=[200,400],loop=2,disposal=2)
    entries['gif']={'path':str(gif),'sha256':sha(gif),'frames':2,'durations_ms':[200,400],'gif_loop_repetitions':2}
    save_json(manifest,entries);return entries

def validate_output(out, target, source_format, reference, case_dir):
    checks={'exists':out.is_file(),'nonzero_size':out.stat().st_size>0,'bytes':out.stat().st_size}
    st=out.stat(); flags=getattr(st,'st_flags',0)
    try:
        raw=run(['/usr/bin/xattr','-px','com.apple.FinderInfo',out]); fi=bytes.fromhex(raw['stdout']) if raw['exit_code']==0 else b''
        invisible=len(fi)>=10 and bool(int.from_bytes(fi[8:10],'big') & 0x4000)
    except OSError: invisible=False
    checks['visible_in_finder'] = not bool(flags & 0x8000) and not invisible and not out.name.startswith('.')
    validation=case_dir/'validation';validation.mkdir(exist_ok=True)
    if target=='pdf':
        pdf=pdfium.PdfDocument(str(out));checks['page_count']=len(pdf)
        page=pdf[0]; render=page.render(scale=reference.width/page.get_width()).to_pil().convert('RGBA')
        if render.size != reference.size: render=render.resize(reference.size)
        render.save(validation/'rendered.png');checks.update(image_checks(render,reference));checks['one_page']=len(pdf)==1
    elif target=='docx':
        with zipfile.ZipFile(out) as z:
            root=ET.fromstring(z.read('word/document.xml')); text='\n'.join(root.itertext())
            texts=[x.text or '' for x in root.iter('{http://schemas.openxmlformats.org/wordprocessingml/2006/main}t')]
            text='\n'.join(texts);(validation/'ocr.txt').write_text(text)
            compact=''.join(text.split()).lower();checks['ocr_text']=text
            checks['ocr_has_english']='fileorbit' in compact
            checks['ocr_has_number']='20261005' in compact
            checks['ocr_has_chinese']='转换' in compact and '中文' in compact
            native_reader=run(['/usr/bin/textutil','-convert','txt','-stdout',out])
            save_json(validation/'native-docx-reader.json',native_reader)
            native_compact=''.join(native_reader['stdout'].split()).lower()
            checks['native_docx_reader_has_text']=(native_reader['exit_code']==0 and
                all(token in native_compact for token in ['fileorbit','20261005','转换','中文']))
            media=[name for name in z.namelist() if name.startswith('word/media/')]
            checks['embedded_images']=len(media)
            if media:
                image=Image.open(io.BytesIO(z.read(media[0]))).convert('RGBA');checks.update(image_checks(image,reference))
    elif target=='mp4':
        p=run(['/opt/homebrew/bin/ffprobe','-v','error','-count_frames','-show_streams','-show_format','-of','json',out]);save_json(validation/'ffprobe.json',p)
        data=json.loads(p['stdout']);v=next(s for s in data['streams'] if s['codec_type']=='video')
        duration=float(v.get('duration',data['format'].get('duration',0)))
        checks.update({'video_frames':int(v.get('nb_read_frames',0)), 'duration_seconds':duration,
                       'duration_matches': abs(duration-0.6)<0.08, 'dimensions_match':(v['width'],v['height'])==reference.size})
        first=validation/'first-frame.png'; last=validation/'last-frame.png'
        for index,dest in [(0,first),(1,last)]:
            q=run(['/opt/homebrew/bin/ffmpeg','-y','-v','error','-i',out,'-vf',f'select=eq(n\\,{index})','-frames:v','1',dest]);
            if q['exit_code']!=0: raise ValueError('MP4 frame extraction failed: '+q['stderr'])
        checks.update(image_checks(Image.open(first),reference))
        a=np.asarray(Image.open(first).convert('RGB'),dtype=float);b=np.asarray(Image.open(last).convert('RGB'),dtype=float)
        checks['animation_changes']=float(np.abs(a-b).mean())>3
        gif_source=Image.open(next(case_dir.glob('*.gif')));gif_source.seek(1)
        checks['second_frame_content_matches']=image_checks(Image.open(last),gif_source)['content_matches']
    else:
        image=decoded(out,validation); checks.update(image_checks(image,reference))
        if target in ['png','webp','tiff','heic','avif']:
            a=np.asarray(reference.convert('RGBA'))[:,:,3];b=np.asarray(image.convert('RGBA'))[:,:,3]
            checks['source_has_transparency']=bool(a.min()<255)
            checks['output_has_transparency']=bool(b.min()<255)
            if checks['source_has_transparency']:
                checks['alpha_error']=round(float(np.abs(a.astype(float)-b.astype(float)).mean()),3)
                checks['alpha_preserved']=checks['alpha_error']<3
        if source_format=='gif' and target=='webp':
            im=Image.open(out);checks['frame_count']=im.n_frames;duration=[]
            for i in range(im.n_frames): im.seek(i); im.load();duration.append(im.info.get('duration'))
            checks['durations_ms']=duration;checks['animation_preserved']=im.n_frames==2 and duration==[200,400]
            checks['webp_total_plays']=im.info.get('loop')
            gif_source=Image.open(next(case_dir.glob('*.gif')))
            repeats=gif_source.info.get('loop')
            checks['animation_loop_preserved']=im.info.get('loop')==(0 if repeats==0 else repeats+1)
            matching_frames=[]
            for i in range(im.n_frames):
                im.seek(i);gif_source.seek(i)
                matching_frames.append(image_checks(im,gif_source)['content_matches'])
            checks['all_animation_frames_match']=all(matching_frames)
    required=['exists','nonzero_size','visible_in_finder']
    required += [k for k in ['dimensions_match','content_matches','nonblank','one_page','ocr_has_english','ocr_has_number','ocr_has_chinese','native_docx_reader_has_text','alpha_preserved','animation_preserved','duration_matches','animation_changes','second_frame_content_matches','animation_loop_preserved','all_animation_frames_match'] if k in checks]
    checks['required_checks']=required
    return checks,all(checks[k] for k in required)

def main():
    p=argparse.ArgumentParser();p.add_argument('--exe',required=True);p.add_argument('--root',required=True);p.add_argument('--resume',action='store_true');p.add_argument('--only');p.add_argument('--sources');p.add_argument('--opaque',action='store_true');p.add_argument('--expect-transparent-avif-rejection',action='store_true')
    args=p.parse_args();exe=pathlib.Path(args.exe).resolve();root=pathlib.Path(args.root).resolve();root.mkdir(parents=True,exist_ok=True)
    sources=make_sources(root,args.opaque); validation=root/'source-validation';validation.mkdir(exist_ok=True)
    report={'executable':str(exe),'executable_sha256':sha(exe),'sources':sources,'cases':[],'notes':['All fixtures synthetic. Shipping app CLI uses the same ConversionEngine as UI.','Static targets from animated GIF are compared to the first frame; animation is required only for WebP and MP4.','Pillow independently decodes most output formats; macOS sips decodes HEIC. PDFium renders PDFs. DOCX OOXML and embedded images are inspected.']}
    results=root/'results.json'
    if args.resume and results.exists(): report['cases']=json.loads(results.read_text())['cases']
    existing={(c['source_format'],c['target_format']) for c in report['cases']}
    for fmt,entry in sources.items():
        if args.sources and fmt not in args.sources.split(','): continue
        if 'path' not in entry: continue
        source=pathlib.Path(entry['path']);ref=decoded(source,validation)
        action=run([exe,'actions',source]);save_json(root/(fmt+'-actions.json'),action)
        first=action['stdout'].splitlines()[0];targets=[f.lower() for f in first.split(':',1)[1].split()]
        for target in targets:
            if args.only and target not in args.only.split(','):continue
            if (fmt,target) in existing: continue
            case_dir=root/'cases'/(fmt+'-to-'+target);case_dir.mkdir(parents=True,exist_ok=True)
            input=case_dir/('图片转换 样例.'+fmt);shutil.copy2(source,input)
            before=sha(input);start=time.monotonic();case={'source_format':fmt,'target_format':target,'fixture_variant':'opaque' if args.opaque else 'mixed-alpha','input':str(input),'outputs':[]}
            try:
                p=run([exe,'convert',input,'--to',target,'--json']);save_json(case_dir/'invocation.json',p)
                cli=json.loads(p['stdout']);case['outputs']=cli.get('outputs',[]);case['cli']=cli
                if p['exit_code']!=0 or cli.get('succeededInputs')!=1 or len(case['outputs'])!=1:
                    case['status']='failed';case['error']='Conversion did not report one successful result';case['checks']={}
                    failure_text=' '.join(f.get('message','') for f in cli.get('failures',[]))
                    if (args.expect_transparent_avif_rejection and target=='avif'
                            and np.asarray(ref)[:,:,3].min()<255 and p['exit_code']==1
                            and cli.get('succeededInputs')==0 and not case['outputs']
                            and all(word in failure_text for word in ['透明','PNG','WebP'])
                            and not list(case_dir.glob('*.avif'))):
                        case['status']='expected_rejection'
                        case['error']='Transparent AVIF unsupported by this encoder; correctly refused before publishing a damaged result.'
                        case['checks']={'clear_transparency_limitation':True,'no_damaged_output_published':True}
                else:
                    checks,ok=validate_output(pathlib.Path(case['outputs'][0]),target,fmt,ref,case_dir)
                    case['checks']=checks;case['status']='passed' if ok else 'failed';
                    if not ok:case['error']='Failed semantic checks: '+', '.join(k for k in checks['required_checks'] if not checks[k])
            except Exception as e:case.update(status='failed',error=str(e));case.setdefault('checks',{})
            case['checks']['original_sha256_unchanged']=sha(input)==before and sha(source)==entry['sha256']
            if not case['checks']['original_sha256_unchanged']:case['status']='failed'
            case['elapsed_seconds']=round(time.monotonic()-start,3)
            report['cases'].append(case);save_json(results,report)
            print(fmt+' -> '+target+': '+case['status']+' '+case.get('error',''),flush=True)
    report['summary']={'cases':len(report['cases']),'passed':sum(c['status']=='passed' for c in report['cases']),'failed':sum(c['status']=='failed' for c in report['cases']),'expected_rejections':sum(c['status']=='expected_rejection' for c in report['cases']),'unique_directions':len({(c['source_format'],c['target_format']) for c in report['cases']})}
    save_json(results,report);print(json.dumps(report['summary']),flush=True)
if __name__=='__main__':main()
