#!/usr/bin/env python3
"""Real extended PDF/archive/subtitle acceptance. Keeps every fixture and output.

Requires reportlab, Pillow, pypdf, python-docx, Poppler. RAR fixtures are local
copies of libarchive's public test data; pass their directory with --upstream.
"""
import argparse, binascii, gzip, hashlib, io, json, pathlib, shutil, subprocess, tarfile, time, zipfile
import xml.etree.ElementTree as ET
from PIL import Image, ImageDraw, ImageFont, ImageChops, ImageStat
from pypdf import PdfReader, PdfWriter
from pypdf.generic import RectangleObject
from reportlab.pdfgen import canvas
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.cidfonts import UnicodeCIDFont
from docx import Document

def run(args, timeout=240):
    return subprocess.run(list(map(str,args)),capture_output=True,timeout=timeout)
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def norm(s): return ''.join(s.split())

def main():
    p=argparse.ArgumentParser();p.add_argument('--exe',required=True);p.add_argument('--root',required=True);p.add_argument('--upstream',required=True);p.add_argument('--only')
    args=p.parse_args();root=pathlib.Path(args.root).resolve();root.mkdir(parents=True,exist_ok=False)
    fixtures=root/'fixtures';fixtures.mkdir();exe=pathlib.Path(args.exe).resolve()
    report={'executable_sha256':sha(exe),'cases':[],'sources':[]}
    def save():
        report['summary']={s:sum(c['status']==s for c in report['cases']) for s in ['passed','limited','failed','expected_rejection']}
        (root/'results.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
    def execute(source,target,validate,variant='',reject=False,extra=()):
        if args.only and args.only not in (variant or source.stem): return
        case_dir=root/'cases'/f'{len(report["cases"]):03d}-{source.stem}-{target}';case_dir.mkdir(parents=True)
        inp=case_dir/source.name;shutil.copyfile(source,inp);before=sha(inp)
        c={'source_format':source.suffix[1:],'target_format':target,'fixture_variant':variant or source.stem,'input':str(inp),'outputs':[],'checks':{},'status':'running'}
        report['cases'].append(c);save()
        try:
            start=time.monotonic();result=run([exe,'convert',inp,'--to',target,'--json',*extra]);c['seconds']=round(time.monotonic()-start,3)
            c['exit_code']=result.returncode;c['stderr']=result.stderr.decode(errors='replace');c['cli']=json.loads(result.stdout)
            c['outputs']=c['cli'].get('outputs',[]);c['checks']['source_unchanged']=sha(inp)==before and sha(source)==before
            assert c['checks']['source_unchanged'],'source changed'
            if reject:
                assert result.returncode!=0 and c['cli'].get('failures') and not c['outputs'],'invalid/unsupported case falsely succeeded'
                c['checks']['explicit_failure_without_output']=True;c['status']='expected_rejection'
            else:
                assert result.returncode==0 and c['cli'].get('succeededInputs')==1,c['cli'].get('failures')
                outputs=list(map(pathlib.Path,c['outputs']));assert outputs,'no output'
                for out in outputs:
                    assert out.exists() and not out.name.startswith('.') and not(out.stat().st_flags&0x8000),'missing/hidden output'
                c['checks']['visible_outputs']=True;c['checks'].update(validate(outputs,case_dir));c['status']='limited' if c['checks'].get('fidelity_limitations') else 'passed'
        except Exception as e:c['status']='failed';c['error']=str(e)
        save();print(c['status'],c['fixture_variant'],target,c.get('error',''),flush=True)

    pdfmetrics.registerFont(UnicodeCIDFont('STSong-Light'))
    def textpdf(name,pages):
        dest=fixtures/(name+'.pdf');c=canvas.Canvas(str(dest),pagesize=(595,842))
        for i,text in enumerate(pages):
            if text:
                c.setFont('Helvetica-Bold',22);c.drawString(50,740,text)
                c.setFont('STSong-Light',18);c.drawString(50,690,'中文正文转换验证，保留页面顺序。')
                c.setFillColorRGB(.2,.4,.7);c.rect(50,380,450,180,fill=1);c.setFillColorRGB(0,0,0)
            c.showPage()
        c.save();return dest
    mixed=textpdf('mixed-blank',['FIRST 12345',None,'LAST 98765'])
    normal=textpdf('rotation-source',['ROTATED CROP 86420'])
    writer=PdfWriter();page=writer.add_page(PdfReader(normal).pages[0]);page.cropbox=RectangleObject([25,50,570,800]);page.rotate(90)
    rotated=fixtures/'rotated-cropped.pdf';writer.write(rotated)
    long=textpdf('forty-pages',[f'PAGE {i:03d} TOKEN {i*37:05d}' for i in range(1,41)])
    form=fixtures/'filled-form.pdf';c=canvas.Canvas(str(form),pagesize=(595,842));c.setFont('Helvetica',20);c.drawString(50,750,'FILLED FORM 24680')
    c.acroForm.textfield(name='name',value='FORM VALUE 12345',x=50,y=610,width=450,height=50,fontSize=22,borderWidth=1);c.showPage();c.save()
    formrot=fixtures/'filled-form-rotated.pdf';w=PdfWriter();w.clone_document_from_reader(PdfReader(form));w.pages[0].rotate(90);w.write(formrot)
    encrypted=fixtures/'password.pdf';w=PdfWriter();w.append(normal);w.encrypt('test-only-password');w.write(encrypted)
    broken=fixtures/'damaged.pdf';broken.write_bytes(b'%PDF-1.7\nmalformed intentional test')
    scanpng=fixtures/'scan.png';im=Image.new('RGB',(1600,2100),'white');draw=ImageDraw.Draw(im);font=ImageFont.truetype('/System/Library/Fonts/STHeiti Light.ttc',58)
    expected=['SCAN PAGE 12345','中文扫描识别验证','Amount 9876.50','END OF PAGE 86420']
    for i,line in enumerate(expected):draw.text((100,200+i*260),line,font=font,fill='black')
    im.save(scanpng)
    scan=fixtures/'rotated-scan.pdf';c=canvas.Canvas(str(scan),pagesize=(595,842));c.drawImage(str(scanpng),0,0,595,842);c.showPage();c.save()
    w=PdfWriter();w.add_page(PdfReader(scan).pages[0]).rotate(90);scanrot=fixtures/'scan-90.pdf';w.write(scanrot)
    lowpng=fixtures/'low-contrast.png';low=Image.new('RGB',(1600,2100),'white');ld=ImageDraw.Draw(low)
    for i,line in enumerate(expected):ld.text((100,200+i*260),line,font=font,fill='#bbbbbb')
    low.save(lowpng);lowpdf=fixtures/'low-contrast.pdf';c=canvas.Canvas(str(lowpdf),pagesize=(595,842));c.drawImage(str(lowpng),0,0,595,842);c.showPage();c.save()
    scanform=fixtures/'scanned-form.pdf';c=canvas.Canvas(str(scanform),pagesize=(595,842));c.drawImage(str(scanpng),0,0,595,842)
    c.acroForm.textfield(name='Name',value='SCAN FORM VALUE 54321',x=50,y=70,width=450,height=50,fontSize=18);c.showPage();c.save()
    off=fixtures/'off-field.pdf';c=canvas.Canvas(str(off),pagesize=(595,842));c.setFont('Helvetica',20);c.drawString(50,750,'TEXT FIELD LITERAL VALUE')
    c.acroForm.textfield(name='Status',value='Off',x=50,y=70,width=450,height=50,fontSize=22);c.showPage();c.save()

    def pdfcheck(source,target,markers=(),appearance=False):
        count=len(PdfReader(source).pages)
        def check(outputs,case_dir):
            if target in ['png','jpg'] or appearance:
                ref=root/'references'/source.stem;ref.mkdir(parents=True,exist_ok=True)
                if not (ref/'complete.json').exists():
                    r=run(['pdftoppm','-cropbox','-r','72','-png',source,ref/'page']);assert r.returncode==0,r.stderr.decode()
                    (ref/'complete.json').write_text(json.dumps({'source_sha256':sha(source)}))
                refs=sorted(ref.glob('page-*.png'),key=lambda p:int(p.stem.rsplit('-',1)[1]))
                if appearance:
                    with zipfile.ZipFile(outputs[0]) as z:
                        pics=[Image.open(io.BytesIO(z.read(n))).convert('RGB') for n in z.namelist() if n.startswith('word/media/')]
                else:
                    names=sorted(outputs[0].glob('*')) if outputs[0].is_dir() else outputs
                    pics=[Image.open(n).convert('RGB') for n in names]
                assert len(pics)==count==len(refs),'page count differs'
                errors=[];region_errors=[];previews=[];field_text_verified=False
                for pic,refp in zip(pics,refs):
                    with Image.open(refp) as rr:
                        assert abs(pic.width/pic.height-rr.width/rr.height)<.01,'rotation/crop aspect differs'
                        shown=pic.resize(rr.size,Image.Resampling.LANCZOS);delta=ImageChops.difference(shown,rr.convert('RGB'))
                        errors.append(sum(ImageStat.Stat(delta).mean)/3)
                        if source in [form,formrot]:
                            region=(50,182,500,232) if source==form else (610,50,660,500)
                            region_errors.append(sum(ImageStat.Stat(delta.crop(region)).mean)/3)
                            field=shown.crop(region)
                            if source==formrot:field=field.rotate(90,expand=True)
                            field=field.resize((field.width*3,field.height*3));field_path=case_dir/'field-ocr.png';field.save(field_path)
                            recognized=run(['tesseract',field_path,'stdout','--psm','6','-l','eng'])
                            assert recognized.returncode==0 and 'FORMVALUE12345' in norm(recognized.stdout.decode()),'visible form value lost or unreadable'
                            field_text_verified=True
                        previews.append(shown.copy())
                assert max(errors)<18,f'render differs MAE {max(errors)}'
                montage=Image.new('RGB',(300*min(4,len(previews)),430),'#dddddd')
                selected=previews if len(previews)<=4 else [previews[0],previews[len(previews)//2],previews[-1]]
                for i,pic in enumerate(selected):pic.thumbnail((295,420));montage.paste(pic,(i*300,0))
                montage.save(case_dir/'contact.png')
                result={'all_pages_present':count,'max_render_mae':max(errors),'form_region_mae':region_errors,'independently_decoded':True}
                if region_errors:
                    result['form_value_verified_with_independent_ocr']=field_text_verified
                    if max(region_errors)>=18:result['fidelity_limitations']=['PDFKit repositions the filled field text relative to the stored Poppler appearance; actual value retained, pixel layout not identical.']
                return result
            text='\n'.join(p.text for p in Document(outputs[0]).paragraphs) if target=='docx' else outputs[0].read_text()
            missing=[x for x in markers if norm(x) not in norm(text)];assert not missing,f'missing markers {missing}'
            return {'expected_markers_retained':len(markers),'text_characters':len(text)}
        return check
    for source,markers in [(mixed,['FIRST 12345','LAST 98765']),(rotated,['ROTATED CROP 86420']),(long,[f'PAGE {i:03d} TOKEN {i*37:05d}' for i in range(1,41)]),(form,['FILLED FORM 24680','FORM VALUE 12345']),(formrot,['FILLED FORM 24680','FORM VALUE 12345']),(scanrot,expected),(lowpdf,expected),(scanform,expected+['SCAN FORM VALUE 54321']),(off,['Status: Off'])]:
        for target in ['png','jpg','txt','docx']:
            execute(source,target,pdfcheck(source,target,markers),reject=source==mixed and target in ['txt','docx'])
        execute(source,'docx',pdfcheck(source,'docx',appearance=True),variant=source.stem+'-appearance',extra=['--pdf-mode','appearance'])
    for source in [encrypted,broken]:
        for target in ['png','jpg','txt','docx']:execute(source,target,lambda *_:{},reject=True)

    payloads={'中文目录/空 格.txt':'归档正文 Chinese text 12345\n'.encode(),'binary.bin':bytes(range(256))*8}
    tar=fixtures/'archive.tar'
    with tarfile.open(tar,'w') as f:
        for name,data in payloads.items():info=tarfile.TarInfo(name);info.size=len(data);f.addfile(info,io.BytesIO(data))
    tgz=fixtures/'archive.tgz';tgz.write_bytes(gzip.compress(tar.read_bytes()))
    gz=fixtures/'stream.gzip';gz.write_bytes(gzip.compress(payloads['binary.bin']))
    def arccheck(expected):
        def check(outputs,_):
            out=outputs[0]
            if zipfile.is_zipfile(out):
                with zipfile.ZipFile(out) as z:actual={n:z.read(n) for n in z.namelist() if not n.endswith('/')}
            else:
                with tarfile.open(out,'r:*') as z:actual={m.name:z.extractfile(m).read() for m in z.getmembers() if m.isfile()}
            if expected=='raw':assert list(actual.values())==[payloads['binary.bin']], 'gzip wrapped compressed bytes instead of payload'
            else:assert actual==expected,'archive names or bytes differ'
            return {'all_entry_names_and_bytes_match':True,'entry_count':len(actual)}
        return check
    for source,expected_content in [(tgz,payloads),(gz,'raw')]:
        for target in ['zip','tar','gz']:execute(source,target,arccheck(expected_content))
    upstream=pathlib.Path(args.upstream)
    for stem in ['basic-rar','compressed-rar5','solid-rar5']:
        uu=upstream/(stem+'.uu');lines=uu.read_bytes().splitlines();data=b''.join(binascii.a2b_uu(line) for line in lines[1:] if line and line!=b'end')
        source=fixtures/(stem+'.rar');source.write_bytes(data)
        report['sources'].append({'fixture':stem,'origin':'https://github.com/libarchive/libarchive/tree/master/libarchive/test','sha256':sha(source)})
        # Read per-entry bytes independently with bsdtar, without extracting onto disk.
        listing=run(['/usr/bin/tar','-tf',source]);assert listing.returncode==0,listing.stderr.decode()
        entries={}
        if stem!='basic-rar':
            for name in listing.stdout.decode().splitlines():
                r=run(['/usr/bin/tar','-xOf',source,name]);assert r.returncode==0;entries[name]=r.stdout
        for target in ['zip','tar','gz']:execute(source,target,arccheck(entries),reject=stem=='basic-rar')
    for badname,entry in [('traversal','../outside.txt'),('absolute','/tmp/unsafe-test.txt')]:
        source=fixtures/(badname+'.zip')
        with zipfile.ZipFile(source,'w') as z:z.writestr(entry,b'INTENTIONAL UNSAFE ARCHIVE FIXTURE')
        for target in ['tar','gz']:execute(source,target,lambda *_:{},reject=True)
    bad=fixtures/'damaged.zip';bad.write_bytes(b'PK\x03\x04broken')
    for target in ['tar','gz']:execute(bad,target,lambda *_:{},reject=True)
    # UTF-8 BOM/CRLF, cue identifiers and WebVTT metadata, subsecond timestamps.
    subtitle=fixtures/'metadata.vtt';subtitle.write_text('\ufeffWEBVTT\r\n\r\nNOTE metadata excluded\r\nnot spoken\r\n\r\ncue-a\r\n00:00:00.125 --> 00:00:01.875 align:start\r\n中文字幕\r\nSecond line\r\n\r\ncue-b\r\n00:00:02.050 --> 00:00:03.900\r\nLast cue 987\r\n',encoding='utf8')
    for target in ['srt','txt']:
        def checksub(outputs,_):
            text=outputs[0].read_text();assert all(x in text for x in ['中文字幕','Second line','Last cue 987']),'cue dropped'
            assert 'not spoken' not in text and 'metadata excluded' not in text,'metadata became dialogue'
            if target=='srt':assert all(x in text for x in ['00:00:00,125','00:00:03,900']),'timestamp changed'
            return {'all_cues_retained_metadata_excluded':True}
        execute(subtitle,target,checksub,reject=True,variant='vtt-positioned-unsupported')
    plain=fixtures/'metadata-without-position.vtt';plain.write_text(subtitle.read_text().replace(' align:start',''))
    for target in ['srt','txt']:execute(plain,target,checksub)
    srt=fixtures/'utf16.srt';srt.write_text('1\r\n00:00:00,125 --> 00:00:03,900\r\n中文字幕\r\nSecond line\r\nLast cue 987\r\n',encoding='utf16')
    for target in ['vtt','txt']:execute(srt,target,checksub)
    save()
    print(json.dumps(report['summary']),flush=True)
if __name__=='__main__':main()
