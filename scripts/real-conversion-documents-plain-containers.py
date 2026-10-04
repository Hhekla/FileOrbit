#!/usr/bin/env python3
"""Actual text-only RTFD/Webarchive conversions; retain every fixture and output.

Requires the bundled document Python dependencies and macOS textutil.
The supplied executable converts each genuine container to all seven menu targets.
"""
import argparse
import html
import importlib.util
import json
import plistlib
import shutil
from pathlib import Path

spec = importlib.util.spec_from_file_location('extended_documents', Path(__file__).with_name('real-conversion-documents-extended.py'))
ext = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ext)
basic = ext.basic


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--exe', required=True, type=Path)
    parser.add_argument('--root', required=True, type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    if root.exists():
        raise SystemExit('Choose a fresh evidence directory; previous files are retained.')
    fixtures = root / 'fixtures'
    fixtures.mkdir(parents=True)
    markers = ['BEGIN-PLAIN-7429 中文容器正文验收',
               'BODY-13579 English and 中文内容 0123456789。',
               'PUNCTUATION-2468 符号 & < > 应完整保留。',
               'END-PLAIN-9876 最后一段结束标记']
    txt = fixtures / 'plain.txt'
    txt.write_text('\n\n'.join(markers) + '\n', encoding='utf-8')
    rtfd = fixtures / 'plain.rtfd'
    generation = ext.run(['/usr/bin/textutil', '-convert', 'rtfd', '-output', rtfd, txt])
    (fixtures / 'rtfd-generation.json').write_text(json.dumps(generation, ensure_ascii=False, indent=2))
    assert generation['returncode'] == 0 and rtfd.is_dir(), generation
    webarchive = fixtures / 'plain.webarchive'
    markup = '<!doctype html><html><head><meta charset="utf-8"></head><body>' + ''.join('<p>' + html.escape(m) + '</p>' for m in markers) + '</body></html>'
    archive = {'WebMainResource': {'WebResourceData': markup.encode('utf-8'), 'WebResourceFrameName': '',
               'WebResourceMIMEType': 'text/html', 'WebResourceTextEncodingName': 'UTF-8',
               'WebResourceURL': 'file:///fileorbit-fixture/plain.html'}, 'WebSubresources': []}
    webarchive.write_bytes(plistlib.dumps(archive, fmt=plistlib.FMT_BINARY))
    report = {'executable': str(args.exe.resolve()), 'executable_sha256': ext.digest(args.exe),
              'pass_scope': 'Text-only container: independent full text and order checks, valid visible output, original preserved. No attachment/layout fidelity claim.',
              'fixtures': [], 'cases': []}
    for source_format, fixture in [('rtfd', rtfd), ('webarchive', webarchive)]:
        decoded = ext.run(['/usr/bin/textutil', '-convert', 'txt', '-stdout', '-encoding', 'UTF-8', fixture])
        (fixtures / (source_format + '-decoded.json')).write_text(json.dumps(decoded, ensure_ascii=False, indent=2))
        assert decoded['returncode'] == 0 and all(basic.normalize(m) in basic.normalize(decoded['stdout']) for m in markers), decoded
        source_check = {'path': str(fixture), 'source_format': source_format, 'sha256': ext.digest(fixture),
                        'markers': markers, 'independently_decoded': True, 'text_only': True}
        report['fixtures'].append(source_check)
        for target in ext.TARGETS:
            folder = root / 'cases' / (source_format + '-to-' + target)
            folder.mkdir(parents=True)
            source = folder / fixture.name
            if fixture.is_dir(): shutil.copytree(fixture, source)
            else: shutil.copy2(fixture, source)
            before = ext.digest(source)
            case = {'source_format': source_format, 'target_format': target, 'fixture_variant': 'plain-text-container',
                    'input': str(source), 'outputs': [], 'status': 'failed', 'checks': {}, 'error': None}
            try:
                command = ext.run([args.exe.resolve(), 'convert', source, '--to', target, '--json'], timeout=90)
                (folder / 'cli.json').write_text(json.dumps(command, ensure_ascii=False, indent=2))
                result = json.loads(command['stdout'])
                case['cli_returncode'] = command['returncode']
                case['cli_result'] = result
                case['outputs'] = result.get('outputs', [])
                assert command['returncode'] == 0 and result['succeededInputs'] == 1 and len(case['outputs']) == 1, result
                output = Path(case['outputs'][0])
                text, details = basic.text_of(output, target)
                (folder / 'extracted.txt').write_text(text, encoding='utf-8')
                normalized = basic.normalize(text)
                positions = [normalized.find(basic.normalize(m)) for m in markers]
                case['checks'] = {'real_format_parse': True, 'missing_markers': [m for m in markers if basic.normalize(m) not in normalized],
                                  'body_in_order': positions == sorted(positions) and all(x >= 0 for x in positions),
                                  'output_visible': not bool(output.stat().st_flags & 0x8000), 'details': details}
                if target == 'pdf': case['checks']['rendered_pages'] = basic.render_pdf(output, folder / 'render')
                assert not case['checks']['missing_markers'] and case['checks']['body_in_order'], case['checks']
                assert case['checks']['output_visible'], 'Output hidden'
                case['status'] = 'passed'
            except Exception as error:
                case['error'] = str(error)
            case['checks']['source_unchanged'] = ext.digest(source) == before
            if not case['checks']['source_unchanged']:
                case['status'] = 'failed'; case['error'] = 'Source changed'
            report['cases'].append(case)
            report['counts'] = {status: sum(c['status'] == status for c in report['cases']) for status in ['passed', 'failed']}
            report['distinct_directions'] = len({(c['source_format'], c['target_format']) for c in report['cases']})
            (root / 'results.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
            print(f'{source_format} -> {target}: {case["status"]} {case["error"] or ""}', flush=True)
    print(json.dumps(report['counts']), flush=True)


if __name__ == '__main__':
    main()
