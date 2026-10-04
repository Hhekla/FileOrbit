#!/usr/bin/env python3
"""Run actual application conversions and independently inspect their outputs.

Requires Pillow, pypdf, reportlab, python-docx and Poppler. No fixtures are deleted.
Optional --private-pdf paths remain local in the ignored results directory.
"""
import argparse, gzip, hashlib, io, json, os, pathlib, shutil, subprocess, tarfile, time, zipfile
import xml.etree.ElementTree as ET
from PIL import Image, ImageChops, ImageDraw, ImageFont, ImageStat
from pypdf import PdfReader
from reportlab.pdfgen import canvas
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.cidfonts import UnicodeCIDFont
from docx import Document

parser = argparse.ArgumentParser()
parser.add_argument('--exe', required=True)
parser.add_argument('--root', required=True)
parser.add_argument('--private-pdf', action='append', default=[])
args = parser.parse_args()
exe = pathlib.Path(args.exe).resolve()
root = pathlib.Path(args.root).resolve()
root.mkdir(parents=True, exist_ok=False)
cases = []
metadata = {'executable': str(exe), 'executable_sha256': hashlib.sha256(exe.read_bytes()).hexdigest(), 'cases': cases}

def save():
    (root / 'results.json').write_text(json.dumps(metadata, ensure_ascii=False, indent=2))

def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()

def run(cmd, timeout=90):
    return subprocess.run(list(map(str,cmd)), capture_output=True, timeout=timeout)

def visible(p):
    assert p.exists() and not p.name.startswith('.'), 'output missing or dot-prefixed'
    assert not (p.stat().st_flags & 0x8000), 'UF_HIDDEN is set'
    try:
        attr = run(['/usr/bin/xattr', '-px', 'com.apple.FinderInfo', p])
        finder = bytes.fromhex(attr.stdout.decode()) if attr.returncode == 0 else b''
        assert not (int.from_bytes(finder[8:10], 'big') & 0x4000), 'Finder invisible flag is set'
    except OSError:
        pass

def execute(source, fmt, validate, label=None, private=False, extra=(), expected_failure=False):
    before = sha(source)
    case = {'source_format': source.suffix.lstrip('.'), 'target_format': fmt, 'label': label or source.stem,
            'input':str(source), 'outputs':[], 'checks':[], 'private':private, 'status':'running'}
    cases.append(case); save()
    try:
        started = time.monotonic()
        cmd = [exe, 'convert', source, '--to', fmt, '--json', *extra]
        proc = run(cmd, 180)
        case['seconds'] = round(time.monotonic()-started, 3)
        case['exit_code'] = proc.returncode
        case['stdout'] = proc.stdout.decode('utf8', errors='replace')
        case['stderr'] = proc.stderr.decode('utf8', errors='replace')
        report = json.loads(proc.stdout)
        case['outputs'] = report.get('outputs',[])
        assert sha(source) == before, 'source bytes changed'
        case['checks'].append('source SHA-256 unchanged')
        if expected_failure:
            assert proc.returncode != 0 and report.get('failures') and not report.get('outputs'), 'incorrect success or published output'
            case['status'] = 'expected_rejection'
        else:
            assert proc.returncode == 0 and report.get('succeededInputs') == 1 and not report.get('failures'), report.get('failures', case['stderr'])
            outputs = list(map(pathlib.Path, report['outputs']))
            assert outputs, 'no output files'
            for p in outputs:
                visible(p)
                if p.is_dir():
                    for child in p.rglob('*'): visible(child)
                else: assert p.stat().st_size > 0
            case['checks'].append('outputs exist, nonempty, Finder-visible')
            case['checks'] += validate(outputs)
            case['status'] = 'pass'
    except Exception as error:
        case['status'] = 'fail'; case['error'] = str(error)
    save()
    print(case['status'], case['label'], '->', fmt, case.get('error', ''), flush=True)

pdfmetrics.registerFont(UnicodeCIDFont('STSong-Light'))
pdfdir = root/'pdf'; pdfdir.mkdir()
markers = ['FIRST PAGE 12345', 'SECOND PAGE 67890', 'LAST PAGE 24680']
pdf = pdfdir/'mixed-text.pdf'
c = canvas.Canvas(str(pdf), pagesize=(595,842))
for i, marker in enumerate(markers):
    c.setFont('Helvetica-Bold', 24); c.drawString(45,760,marker)
    c.setFont('STSong-Light', 20); c.drawString(45,710,'中文转换验证：标题、数字与段落完整。')
    c.setFont('Helvetica', 14); c.drawString(45,670,'FileOrbit local conversion acceptance.'); c.drawString(45,640,f'Page {i+1} of 3')
    c.setFillColorRGB(0.1+i*0.2,0.5,0.8-i*0.2); c.rect(45,450,500,100,fill=1,stroke=0)
    c.showPage()
c.save()
blank = pdfdir/'blank.pdf'; c=canvas.Canvas(str(blank)); c.showPage(); c.save()
scan_image = Image.new('RGB',(1600,2100),'white')
draw=ImageDraw.Draw(scan_image)
font=ImageFont.truetype('/System/Library/Fonts/STHeiti Light.ttc',60)
for i,line in enumerate(['SCAN DOCUMENT 12345','中文扫描识别测试','FileOrbit Offline Test','Amount 9876.50','END OF SCANNED PAGE']):
    draw.text((90,150+i*200),line,font=font,fill='black')
scanpng=pdfdir/'scan-source.png'; scan_image.save(scanpng)
scan=pdfdir/'scan.pdf'; c=canvas.Canvas(str(scan),pagesize=(595,842)); c.drawImage(str(scanpng),0,0,595,842); c.save()
single=pdfdir/'single.pdf'; c=canvas.Canvas(str(single)); c.setFont('Helvetica',22); c.drawString(60,700,'SINGLE PAGE 13579'); c.showPage(); c.save()

def norm(s): return ''.join(s.split())
def text_read(p):
    if p.suffix == '.docx':
        return '\n'.join(x.text for x in Document(p).paragraphs)
    return p.read_text()

def pdf_validation(source, fmt, expected_markers, private=False):
    page_count=len(PdfReader(source).pages)
    def check(outputs):
        if fmt in ('jpg','png'):
            images = sorted(outputs[0].iterdir()) if outputs[0].is_dir() else outputs
            assert len(images)==page_count, f'page count {len(images)} != {page_count}'
            reference_dir = source.parent/(source.stem+'-reference')
            reference_dir.mkdir(exist_ok=True)
            references = list(reference_dir.glob('page-*.png'))
            if not references:
                rendered=run(['pdftoppm','-scale-to','800','-png',source,reference_dir/'page'],180)
                assert rendered.returncode==0, rendered.stderr.decode(errors='replace')
                references=list(reference_dir.glob('page-*.png'))
            references.sort(key=lambda p:int(p.stem.rsplit('-',1)[1]))
            assert len(references)==page_count, 'independent reference render page count differs'
            contact=[]
            errors=[]
            for i,p in enumerate(images):
                with Image.open(p) as im:
                    im.load()
                    assert im.format == ('JPEG' if fmt=='jpg' else 'PNG'), 'actual image format mismatch'
                    assert min(im.size)>500, 'unexpectedly low resolution'
                    assert max(ImageStat.Stat(im.convert('RGB')).stddev)>3, 'blank rendered page'
                    with Image.open(references[i]) as expected:
                        preview=im.convert('RGB').resize(expected.size,Image.Resampling.LANCZOS)
                        error=sum(ImageStat.Stat(ImageChops.difference(preview,expected.convert('RGB'))).mean)/3
                        assert error<18, f'page {i+1} differs from independent render: MAE {error:.2f}'
                        errors.append(round(error,3))
                    if not private:
                        im=im.convert('RGB'); im.thumbnail((230,340)); contact.append(im.copy())
            if contact:
                sheet=Image.new('RGB',(240*len(contact),350),'#dddddd')
                for i,im in enumerate(contact): sheet.paste(im,(240*i,0))
                sheet.save(root/f'{source.stem}-{fmt}-contact.png')
            return [f'{page_count} pages present; every image independently decoded; dimensions and nonblank pixels checked',
                    f'every page compared to independent Poppler render; max pixel MAE {max(errors):.3f} / 255']
        text=text_read(outputs[0]); normalized=norm(text)
        assert len(normalized)>10,'empty text'
        for marker in expected_markers: assert norm(marker) in normalized, f'missing text marker: {marker}'
        if private:
            if fmt=='docx':
                with zipfile.ZipFile(outputs[0]) as z:
                    body=ET.fromstring(z.read('word/document.xml'))
                ns={'w':'http://schemas.openxmlformats.org/wordprocessingml/2006/main'}
                chunks=['']
                for node in body.iter():
                    if node.tag=='{'+ns['w']+'}t': chunks[-1]+=node.text or ''
                    elif node.tag=='{'+ns['w']+'}br' and node.get('{'+ns['w']+'}type')=='page': chunks.append('')
                assert len(chunks)==page_count and all(len(norm(s))>5 for s in chunks), 'missing or empty DOCX page section'
            source_text=norm('\n'.join(p.extract_text() or '' for p in PdfReader(source).pages))
            if source_text:
                from difflib import SequenceMatcher
                ratio=SequenceMatcher(None,source_text,normalized,autojunk=False).ratio()
                assert ratio>0.96, f'PDF/output text differs too much ({ratio:.3f})'
                return [f'all {page_count} page sections have text; source/output normalized similarity {ratio:.5f}']
            return [f'all {page_count} page sections have nonempty OCR text; recognition accuracy not exhaustively proofread']
        return [f'nonempty readable text; {len(expected_markers)} expected markers retained']
    return check

for source,expected in [(pdf,markers+['中文转换验证']),(single,['SINGLE PAGE 13579']),
                        (scan,['SCAN DOCUMENT 12345','END OF SCANNED PAGE','中文扫描识别测试'])]:
    for fmt in ('docx','txt','png','jpg'):
        execute(source,fmt,pdf_validation(source,fmt,expected))
for fmt in ('docx','txt'):
    execute(blank,fmt,lambda outputs: ['unexpected output'],expected_failure=True)

for n,raw in enumerate(args.private_pdf,1):
    original=pathlib.Path(raw); private_dir=root/f'private-{n}'; private_dir.mkdir()
    copied=private_dir/f'private-source-{n}.pdf'; shutil.copyfile(original,copied)
    initial=sha(original)
    # Documents remain local; the report never stores source text or real filenames.
    for fmt in ('docx','png'):
        execute(copied,fmt,pdf_validation(copied,fmt,[],True),private=True,label=f'private PDF {n}')
    assert sha(original)==initial,'desktop source bytes changed'

subdir=root/'subtitles'; subdir.mkdir()
srt=subdir/'captions.srt'; srt.write_text('1\n00:00:00,125 --> 00:00:01,875\n中文第一行\nSecond line 123\n\n2\n00:00:02,050 --> 00:00:04,900\nLast cue 987\n\n')
vtt=subdir/'captions.vtt'; vtt.write_text('WEBVTT\n\n00:00:00.125 --> 00:00:01.875\n中文第一行\nSecond line 123\n\n00:00:02.050 --> 00:00:04.900\nLast cue 987\n\n')
for source,formats in ((srt,('vtt','txt')),(vtt,('srt','txt'))):
    for fmt in formats:
        def check_sub(outputs, fmt=fmt):
            text=outputs[0].read_text()
            for marker in ('中文第一行','Second line 123','Last cue 987'): assert marker in text
            if fmt!='txt':
                sep=',' if fmt=='srt' else '.'
                for t in ('00:00:00'+sep+'125','00:00:01'+sep+'875','00:00:02'+sep+'050','00:00:04'+sep+'900'): assert t in text
            return ['all Unicode/multiline cues retained; timestamps retained where applicable']
        execute(source,fmt,check_sub)

arcdir=root/'archives'; arcdir.mkdir()
payloads={'中文.txt':'Archive 中文 content 12345\n'.encode(),'nested/payload.bin':bytes(range(256))*4}
z=arcdir/'sample.zip'
with zipfile.ZipFile(z,'w',zipfile.ZIP_DEFLATED) as f:
    for name,data in payloads.items(): f.writestr(name,data)
t=arcdir/'sample.tar'
with tarfile.open(t,'w') as f:
    for name,data in payloads.items():
        info=tarfile.TarInfo(name); info.size=len(data); f.addfile(info,io.BytesIO(data))
g=arcdir/'single.gz'; g.write_bytes(gzip.compress(payloads['中文.txt']))
tg=arcdir/'sample.tar.gz'; tg.write_bytes(gzip.compress(t.read_bytes()))
for source,formats in ((z,('tar','gz')),(t,('zip','gz')),(g,('zip','tar')),(tg,('zip','tar'))):
    for fmt in formats:
        def check_archive(outputs, source=source):
            p=outputs[0]
            if zipfile.is_zipfile(p):
                with zipfile.ZipFile(p) as a:
                    assert a.testzip() is None
                    found={n:a.read(n) for n in a.namelist() if not n.endswith('/')}
            elif tarfile.is_tarfile(p):
                with tarfile.open(p,'r:*') as a: found={m.name:a.extractfile(m).read() for m in a if m.isfile()}
            else: found={'single':gzip.decompress(p.read_bytes())}
            expected=[payloads['中文.txt']] if source==g else list(payloads.values())
            assert sorted(found.values())==sorted(expected), 'archive bytes or file count differ'
            if source!=g: assert {n.lstrip('./') for n in found}==set(payloads),'archive names differ'
            return [f'independent archive reader restored {len(found)} files with exact original bytes and names']
        execute(source,fmt,check_archive)

metadata['summary']={s:sum(c['status']==s for c in cases) for s in sorted({c['status'] for c in cases})}
save(); print(json.dumps(metadata['summary']),flush=True)
