# -*- coding: utf-8 -*-
"""
심사 입력 준비 — 접수 데이터를 AI 심사가 읽을 수 있는 형태로 변환한다.

  PDF 있는 작품  → 페이지를 몽타주 PNG 로 렌더 (비전 모델이 한 번에 흐름을 본다)
  PDF 없는 작품  → 텍스트만 덤프하고 'text_only' 로 표시
  소설           → 회차 본문 전문을 텍스트로 덤프

산출물은 _심사작업/ 아래에 쌓인다. 학생 개인정보가 들어 있으므로
이 폴더는 .gitignore 로 막혀 있다. 공개 저장소에 올리지 말 것.

사용:
  python judge_prepare.py            # 전량
  python judge_prepare.py --limit 8  # 샘플만 (리허설용)
"""
import argparse
import io
import json
import os
import re
import sys
import urllib.request
import urllib.parse
import urllib.error

import fitz  # PyMuPDF
from PIL import Image

BASE = 'https://mllbsqnrvhvnqvxkpxof.supabase.co'
ADMIN_PW = os.environ.get('TC_ADMIN_PW', '2509')
OUT = '_심사작업'
# 비전 모델은 긴 변을 1568px 로 줄여서 본다. 세로로 길게 이어 붙이면
# 축소 과정에서 대사와 작화가 뭉개지므로, 2x2 격자로 1568x1568 에 맞춘다.
GRID = (2, 2)             # 열 x 행 — 한 장에 4페이지
CELL = 784                # 칸 한 변(px) → 784*2 = 1568
JPEG_Q = 82
SEC = {'comic': '만화웹툰', 'novel': '소설이야기', 'cardnews': '카드뉴스', 'poster': '포스터'}


def anon_key():
    s = io.open('index.html', encoding='utf-8').read()
    return re.search(r"'(eyJ[A-Za-z0-9._-]+)'", s).group(1)


def rpc(fn, payload):
    key = anon_key()
    req = urllib.request.Request(
        BASE + '/rest/v1/rpc/' + urllib.parse.quote(fn),
        data=json.dumps(payload, ensure_ascii=False).encode('utf-8'),
        headers={'apikey': key, 'Authorization': 'Bearer ' + key,
                 'Content-Type': 'application/json'},
        method='POST')
    with urllib.request.urlopen(req) as r:
        return json.loads(r.read().decode('utf-8') or 'null')


def is_test(x):
    e = str(x.get('contact_email') or '')
    return e.endswith('@test.invalid') or (e == 'rehodesign7@gmail.com' and x.get('school') == '투닝초')


def safe(s):
    return re.sub(r'[\\/:*?"<>|\s]+', '_', str(s or ''))[:40]


def render_page(page, box):
    """페이지를 box 변 길이에 맞춰 렌더해 PIL 이미지로 돌려준다."""
    zoom = box / max(page.rect.width, page.rect.height)
    pix = page.get_pixmap(matrix=fitz.Matrix(zoom, zoom))
    return Image.frombytes('RGB', (pix.width, pix.height), pix.samples)


def montage(pdf_bytes, outdir, stem):
    """PDF 를 2x2 격자 JPEG 으로 렌더하고 (경로목록, 페이지수) 를 돌려준다.

    한 장짜리(포스터)는 격자로 만들지 않고 한 장을 크게 렌더한다."""
    doc = fitz.open(stream=pdf_bytes, filetype='pdf')
    cols, rows = GRID
    per = cols * rows
    paths = []

    if doc.page_count == 1:
        img = render_page(doc[0], CELL * 2)
        path = os.path.join(outdir, '%s_p01.jpg' % stem)
        img.save(path, 'JPEG', quality=JPEG_Q)
        paths.append(path)
    else:
        for start in range(0, doc.page_count, per):
            pages = list(range(start, min(start + per, doc.page_count)))
            sheet = Image.new('RGB', (CELL * cols, CELL * rows), 'white')
            for i, pno in enumerate(pages):
                img = render_page(doc[pno], CELL)
                x = (i % cols) * CELL + (CELL - img.width) // 2
                y = (i // cols) * CELL + (CELL - img.height) // 2
                sheet.paste(img, (x, y))
            # 남는 칸이 있으면 그만큼 잘라낸다 (빈 흰 칸을 모델에 보여줄 이유가 없다)
            used_rows = (len(pages) + cols - 1) // cols
            if used_rows < rows:
                sheet = sheet.crop((0, 0, CELL * cols, CELL * used_rows))
            path = os.path.join(outdir, '%s_p%02d-%02d.jpg' % (stem, pages[0] + 1, pages[-1] + 1))
            sheet.save(path, 'JPEG', quality=JPEG_Q)
            paths.append(path)

    n = doc.page_count
    doc.close()
    return paths, n


def dump_text(x):
    """심사 프롬프트에 그대로 붙일 텍스트 본문."""
    out = []
    out.append('작품 제목: %s' % (x.get('topic') or ''))
    out.append('부문: %s' % SEC.get(x['section'], x['section']))
    out.append('학교급/학년: %s %s' % (x.get('school_level') or '', x.get('grade') or ''))
    desc = x.get('work_description') or x.get('proposal_text') or ''
    out.append('\n[시놉시스 / 기획안]\n%s' % (desc.strip() or '(미작성)'))
    eps = x.get('episodes') or []
    if eps:
        out.append('\n[본문 — 총 %d회차]' % len(eps))
        for e in eps:
            out.append('\n── %s회차 ──\n%s' % (e.get('ep', '?'), (e.get('body') or '').strip()))
    out.append('\n[생성형 AI 활용 과정]\n%s' % ((x.get('ai_process') or '').strip() or '(미작성)'))
    return '\n'.join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--limit', type=int, default=0, help='앞에서 N건만 (리허설용)')
    ap.add_argument('--section', default='', help='부문 한정: comic/novel/cardnews/poster')
    args = ap.parse_args()

    rows = rpc('투닝콘테스트_관리자목록', {'p_pw': ADMIN_PW})
    if not isinstance(rows, list):
        print('접수 목록을 가져오지 못했습니다:', rows)
        return 1
    live = [x for x in rows
            if not is_test(x) and x['created_at'] >= '2026-09-29T15:00:00' and x.get('is_latest')]
    if args.section:
        live = [x for x in live if x['section'] == args.section]
    live.sort(key=lambda x: (x['section'], x['created_at']))
    if args.limit:
        live = live[:args.limit]

    os.makedirs(OUT, exist_ok=True)
    manifest = []
    for i, x in enumerate(live, 1):
        stem = '%s_%s_%s' % (SEC.get(x['section'], x['section']), safe(x.get('name')), x.get('submit_key'))
        d = os.path.join(OUT, stem)
        os.makedirs(d, exist_ok=True)

        item = {
            'submit_key': x.get('submit_key'), 'name': x.get('name'), 'school': x.get('school'),
            'school_level': x.get('school_level'), 'grade': x.get('grade'),
            'section': x['section'], 'section_ko': SEC.get(x['section'], x['section']),
            'topic': x.get('topic'), 'dir': d, 'images': [], 'pages': 0,
            'evidence': 'text_only', 'board_link': x.get('board_link'),
        }

        io.open(os.path.join(d, '본문.txt'), 'w', encoding='utf-8').write(dump_text(x))

        url = x.get('pdf_url')
        if url:
            try:
                req = urllib.request.Request(url, headers={'User-Agent': 'tooning-contest-judge/1.0'})
                data = urllib.request.urlopen(req, timeout=60).read()
                imgs, pages = montage(data, d, stem)
                item['images'] = imgs
                item['pages'] = pages
                item['evidence'] = 'pdf'
            except Exception as e:                      # 한 건이 실패해도 전체를 멈추지 않는다
                item['note'] = 'PDF 처리 실패: %s' % e
        manifest.append(item)
        print('[%2d/%2d] %-9s %-8s %-14s %s' % (
            i, len(live), item['section_ko'], item['name'], (item['school'] or '')[:14],
            ('PDF %d쪽 → %d장' % (item['pages'], len(item['images'])))
            if item['evidence'] == 'pdf' else '텍스트만 (PDF 미첨부)'))

    io.open(os.path.join(OUT, '_manifest.json'), 'w', encoding='utf-8').write(
        json.dumps(manifest, ensure_ascii=False, indent=2))

    pdf_n = sum(1 for m in manifest if m['evidence'] == 'pdf')
    print('\n준비 완료: %d건 (작품 확인 가능 %d · 텍스트만 %d)'
          % (len(manifest), pdf_n, len(manifest) - pdf_n))
    print('산출물: %s/  ← 개인정보 포함, 공개 저장소에 올리지 말 것' % OUT)
    return 0


if __name__ == '__main__':
    sys.exit(main())
