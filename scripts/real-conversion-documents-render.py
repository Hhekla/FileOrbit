#!/usr/bin/env python3
"""Revalidate retained actual conversions and render DOCX using the document skill.

All renderer work directories are retained to honor the no-bulk-deletion rule.
No conversion is replaced by fixture generation, and no conversion count is added.
"""
import argparse
import importlib.util
import json
import tempfile
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

from PIL import Image, ImageDraw


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--renderer', type=Path, required=True)
    parser.add_argument('--baseline-only', action='store_true')
    parser.add_argument('--native-only', action='store_true', help='Reuse retained LibreOffice results and add macOS Quick Look validation')
    parser.add_argument('--baseline-evidence', type=Path, help='Reuse the independently generated renderer baseline recorded in another results.json')
    args = parser.parse_args()
    root = args.root.resolve()
    base = load('actual_documents', Path(__file__).with_name('real-conversion-documents.py'))
    renderer = load('document_skill_renderer', args.renderer)
    work = root / 'retained-renderer-work'
    work.mkdir(exist_ok=True)

    class RetainedTemporaryDirectory:
        def __init__(self, suffix=None, prefix=None, dir=None, **kwargs):
            self.name = tempfile.mkdtemp(prefix=prefix or 'retained-', suffix=suffix or '', dir=work)
        def __enter__(self):
            return self.name
        def __exit__(self, *args):
            return False
        def cleanup(self):
            pass

    renderer.tempfile.TemporaryDirectory = RetainedTemporaryDirectory
    results = json.loads((root / 'results.json').read_text())
    paragraphs = json.loads((root / 'fixtures' / 'expected.json').read_text())['paragraphs']
    baseline_dir = root / 'baseline-docx-render'
    if args.baseline_evidence:
        results['independent_renderer_baseline'] = json.loads(args.baseline_evidence.read_text())['independent_renderer_baseline']
        results['baseline_evidence_path'] = str(args.baseline_evidence.resolve())
    else:
        baseline_pages = list(map(str, sorted(baseline_dir.glob('page-*.png')))) if args.native_only else renderer.rasterize(str(root / 'fixtures' / 'source.docx'), str(baseline_dir), 100, verbose=False, emit_pdf=True)
        baseline_text, baseline_details = base.text_of(baseline_dir / 'source.pdf', 'pdf')
        results['independent_renderer_baseline'] = {
            'input': str(root / 'fixtures' / 'source.docx'),
            'description': 'python-docx generated source before any FileOrbit conversion',
            'pages': list(baseline_pages), 'checks': base.content_checks(baseline_text, paragraphs),
            'details': baseline_details}
    (root / 'results.json').write_text(json.dumps(results, ensure_ascii=False, indent=2))
    if args.baseline_only:
        print(json.dumps(results['independent_renderer_baseline'], ensure_ascii=False, indent=2))
        return
    baseline_usable = results['independent_renderer_baseline']['checks']['missing_paragraph_count'] == 0
    if not baseline_usable:
        results['rendering_limitation'] = 'Bundled LibreOffice also fails to render Chinese from the original python-docx source. Its output is not an adequate oracle for Chinese display. DOCX is instead checked with native Quick Look thumbnails and full textutil extraction; Word/LibreOffice on another installation remains unverified.'
    rendered_groups = []
    for case in results['cases']:
        if case.get('cli_returncode') != 0 or len(case.get('outputs', [])) != 1:
            continue
        output = Path(case['outputs'][0])
        text, details = base.text_of(output, case['target_format'])
        old_checks = case['checks']
        checks = base.content_checks(text, paragraphs)
        checks.update({k: v for k, v in old_checks.items() if k not in checks and not k.startswith('missing_')})
        case['checks'] = checks
        good = checks['missing_paragraph_count'] == 0 and checks['paragraphs_in_order']
        if case['target_format'] == 'pdf':
            case['pdf_text_codepoint_limitation'] = not checks['exact_codepoint_paragraphs_present']
            rendered_groups.append((case['source_format'] + ' to PDF', [Path(p['path']) for p in case['renders']]))
        if case['target_format'] == 'docx':
            render_dir = output.parent / 'render-docx'
            try:
                pages = list(map(str, sorted(render_dir.glob('page-*.png')))) if args.native_only else renderer.rasterize(str(output), str(render_dir), 100, verbose=False, emit_pdf=True)
                with zipfile.ZipFile(output) as package:
                    xml = ET.fromstring(package.read('word/document.xml'))
                    ns = {'w': 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'}
                    details['bold_runs'] = len(xml.findall('.//w:rPr/w:b', ns))
                if pages:
                    checks['docx_renders_in_libreoffice'] = len(pages) > 0
                    pdftext, pdfdetails = base.text_of(render_dir / (output.stem + '.pdf'), 'pdf')
                    checks['docx_rendered_text_content'] = base.content_checks(pdftext, paragraphs)
                if baseline_usable:
                    assert pages, 'No independently rendered pages'
                    good = good and checks['docx_rendered_text_content']['missing_paragraph_count'] == 0
                else:
                    native = base.run(['/usr/bin/textutil', '-convert', 'txt', '-stdout', '-encoding', 'UTF-8', output])
                    checks['docx_native_text_content'] = base.content_checks(native['stdout'], paragraphs)
                    quicklook_dir = output.parent / 'quicklook'
                    quicklook_dir.mkdir(exist_ok=True)
                    quicklook = base.run(['/usr/bin/qlmanage', '-t', '-s', '1200', '-o', quicklook_dir, output], timeout=60)
                    (quicklook_dir / 'command.json').write_text(json.dumps(quicklook, ensure_ascii=False, indent=2))
                    thumb = quicklook_dir / (output.name + '.png')
                    checks['docx_native_preview_exists'] = quicklook['returncode'] == 0 and thumb.is_file()
                    case['quicklook_thumbnail'] = str(thumb)
                    good = good and checks['docx_native_text_content']['missing_paragraph_count'] == 0 and checks['docx_native_preview_exists']
                case['docx_render_pages'] = pages
                if pages:
                    rendered_groups.append((case['source_format'] + ' to DOCX', [Path(p) for p in pages]))
            except Exception as e:
                checks['docx_renders_in_libreoffice'] = False
                case['render_error'] = repr(e)
                good = False
        case['status'] = 'passed' if good else 'failed'
        case['error'] = None if good else case.get('render_error', 'Content validation failed')
        case['output_details'] = details
        results['counts'] = {s: sum(c['status'] == s for c in results['cases']) for s in ['passed', 'failed']}
        (root / 'results.json').write_text(json.dumps(results, ensure_ascii=False, indent=2))
        print(f"{case['source_format']}->{case['target_format']}: {case['status']}", flush=True)

    overview = root / 'visual-overviews'
    overview.mkdir(exist_ok=True)
    manifest = []
    for label, paths in rendered_groups:
        for start in range(0, len(paths), 6):
            batch = paths[start:start + 6]
            canvas = Image.new('RGB', (1260, 3 * 910), '#c8c8c8')
            draw = ImageDraw.Draw(canvas)
            for i, path in enumerate(batch):
                with Image.open(path) as image:
                    image.thumbnail((610, 870))
                    x = (i % 2) * 630 + 10
                    y = (i // 2) * 910 + 25
                    canvas.paste(image, (x, y))
                    draw.text((x, y - 18), label + ' ' + path.name, fill='black')
            dest = overview / (label.replace(' ', '-') + f'-{start + 1}.jpg')
            canvas.save(dest, quality=90)
            manifest.append({'path': str(dest), 'pages': list(map(str, batch))})
    results['visual_overviews'] = manifest
    (root / 'results.json').write_text(json.dumps(results, ensure_ascii=False, indent=2))
    print(json.dumps(results['counts']), flush=True)


if __name__ == '__main__':
    main()
