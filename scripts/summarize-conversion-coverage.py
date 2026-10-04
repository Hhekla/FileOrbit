#!/usr/bin/env python3
"""Audit actual conversion evidence against the app's current menus; publish no paths/content."""
import argparse, collections, hashlib, json, pathlib, re, subprocess

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--exe',required=True);ap.add_argument('--images',required=True);args=ap.parse_args()
    repo=pathlib.Path(__file__).resolve().parents[1];base=repo/'.build/extended-conversions-20261005';exe=pathlib.Path(args.exe).resolve()
    groups=[('extended-images',pathlib.Path(args.images)),('original-images',base/'images/original70-consolidated.json'),
      ('extended-documents',base/'documents/verified/results.json'),('plain-containers',base/'documents/plain-containers/results.json'),('original-documents',base/'documents/original-verified/results.json'),
      ('extended-media',base/'media-alpha5/results.json'),('original-media',base/'media-baseline-alpha5/results.json'),
      ('extended-pdf-archives-subtitles',base/'pdf-archives/accepted/results.json'),('original-pdf-archives-subtitles',base/'pdf-archives/original-final/results.json')]
    statuses={'pass':'passed','fail':'failed','passed_with_limitations':'limited','expected_rejection':'expected_rejection','rejected':'expected_rejection','unsupported':'unsupported','expected_unsupported':'unsupported'}
    cases=[];samples={};attempts=collections.defaultdict(set);successful=collections.defaultdict(set)
    for group,path in groups:
        data=json.loads(path.read_text())
        for i,c in enumerate(data['cases']):
            status=statuses.get(c['status'],c['status'])
            if status not in ['passed','limited','failed','expected_rejection','unsupported']:raise ValueError(f'incomplete evidence: {path} {i}')
            ext=c['source_format'];target=c['target_format'];attempts[ext].add(target)
            if status in ['passed','limited']:successful[ext].add(target)
            source=c.get('input');
            if source and pathlib.Path(source).exists() and (ext not in samples or status in ['passed','limited']):samples[ext]=source
            variant=c.get('fixture_variant',c.get('label','standard'))
            checks=c.get('checks',{})
            scalar_checks={k:v for k,v in checks.items() if isinstance(v,(bool,int,float))} if isinstance(checks,dict) else {}
            cases.append({'group':group,'source_format':ext,'target_format':target,'fixture_variant':variant,'status':status,
                          'checks':scalar_checks,'test_executable_sha256':c.get('test_executable_sha256',c.get('executable_sha256',data.get('executable_sha256')))})
    classifier=(repo/'Sources/KumquatCore/Model/FileKind.swift').read_text();families={}
    for family in ['image','document','video','audio']:
        block=re.search(r'static let '+family+r'Extensions: Set<String> = \[(.*?)\]',classifier,re.S).group(1)
        for ext in re.findall(r'"([a-z0-9]+)"',block):families[ext]=family
    families.update(pdf='pdf',srt='subtitle',vtt='subtitle',zip='archive',tar='archive',gz='archive',gzip='archive',tgz='archive',rar='archive')
    svg=base/'images/sources/unsupported.svg';samples['svg']=str(svg)
    coverage=[];missing=[]
    for ext in sorted(families):
        if ext not in samples:raise ValueError(f'No genuine source fixture for {ext}')
        p=subprocess.run([str(exe),'actions',samples[ext]],capture_output=True,text=True,timeout=30)
        assert p.returncode==0,p.stderr
        targets=p.stdout.splitlines()[0].split(':',1)[1].lower().split()
        unseen=sorted(set(targets)-attempts[ext]);missing.extend([ext+'→'+t for t in unseen])
        coverage.append({'extension':ext,'family':families[ext],'offered_outputs':targets,'attempted_outputs':sorted(set(targets)&attempts[ext]),'outputs_with_content_pass':sorted(set(targets)&successful[ext]),'untested_outputs':unseen})
    result={'version':'0.1.0-alpha.5','date':'2026-10-05','scope':'Explicit input extensions including aliases; real files through the shipping app engine. Cases with limitations or rejections are not full conversion passes.',
      'final_executable_sha256':hashlib.sha256(exe.read_bytes()).hexdigest(),'case_counts':dict(collections.Counter(c['status'] for c in cases)),
      'group_counts':{g:dict(collections.Counter(c['status'] for c in cases if c['group']==g)) for g in sorted({c['group'] for c in cases})},
      'explicit_extensions':len(coverage),'offered_directions':sum(len(c['offered_outputs']) for c in coverage),'untested_directions':missing,'coverage':coverage,'cases':cases,
      'build_provenance':'The main matrix ran on alpha.5 candidate builds; later fixes were retested on affected paths. Each case retains its executable hash. Untouched paths were not needlessly rerun. Historical failed trials remain in local evidence.'}
    guard_path=base/'documents/guards-final/results.json'
    if guard_path.exists():
        guards=json.loads(guard_path.read_text())
        guard_cases=[]
        for c in guards['cases']:
            status=statuses.get(c['status'],c['status'])
            if status not in ['passed','expected_rejection','unsupported']:
                raise ValueError('Final DOCX guard check did not pass or reject as expected')
            guard_cases.append({'source_format':c['source_format'],'target_format':c['target_format'],
                'fixture_variant':c['fixture_variant'],'status':status,
                'checks':{k:v for k,v in c.get('checks',{}).items() if isinstance(v,(bool,int,float))},
                'test_executable_sha256':guards['executable_sha256']})
        result['additional_final_docx_checks']={'excluded_from_main_case_counts':True,
            'case_counts':dict(collections.Counter(c['status'] for c in guard_cases)),'cases':guard_cases}
    (repo/'docs/actual-conversion-results.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    (base/'coverage-audit.json').write_text(json.dumps({k:v for k,v in result.items() if k!='cases'},ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({k:result[k] for k in ['case_counts','group_counts','explicit_extensions','offered_directions','untested_directions']},ensure_ascii=False,indent=2))
    if missing:raise SystemExit(1)
if __name__=='__main__':main()
