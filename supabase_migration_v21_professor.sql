-- =====================================================
-- [투닝콘테스트] v21 — 교수 심사 · 디지털 상장 발급
--
--   /professor 페이지가 쓰는 테이블과 RPC 입니다.
--
--   흐름: 심사 코드 입력 → 배정된 작품 확인 → 상장에 직인 올리기
--         → 확정 → 상장 이미지 저장 + 운영자에게 메일
--
--   ⚠️ 직인 원본은 저장하지 않습니다.
--      대학 공식 직인 이미지가 공개 URL 에 떠 있으면 도용될 수 있습니다.
--      직인은 교수님 브라우저에서 상장 이미지에 합성만 하고,
--      서버에는 '완성된 상장'과 '직인을 어디에 얼마만큼 놓았는지'(좌표·크기)만
--      남깁니다. 다시 발급할 때는 직인을 한 번 더 올리시면 됩니다.
--
--   ⚠️ 접근 통제는 '심사 코드' 하나에 달려 있습니다.
--      코드를 아는 사람만 배정된 학생 정보를 볼 수 있고, 자기에게
--      배정된 작품 외에는 어떤 접수도 조회되지 않습니다.
--      코드는 교수님 개인 메일로만 전달하세요.
--
-- 전제: v17, v18, v20 실행 완료
-- 성격: 비파괴 · 여러 번 실행해도 안전
-- 실행: Supabase 대시보드 → SQL Editor → 전체 붙여넣기 → Run
-- =====================================================

BEGIN;

-- 심사위원(교수님) — 코드 1개 = 교수님 1분
CREATE TABLE IF NOT EXISTS 투닝콘테스트_심사위원 (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code       text UNIQUE NOT NULL,              -- PRO-XXXX-XXXX-XXXX
  교수명      text NOT NULL,
  대학        text NOT NULL,
  직함        text,
  email      text,
  active     boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- 배정 — 교수님 ↔ 작품. 교수님(대학)당 부문별 1건 = 최대 4건, 작품 1건당 교수님 1분.
-- (우수상 64명 = 16개 대학 x 4부문. 아래 유니크 인덱스가 이 규칙을 지킨다)
CREATE TABLE IF NOT EXISTS 투닝콘테스트_배정 (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code       text NOT NULL REFERENCES 투닝콘테스트_심사위원(code) ON DELETE CASCADE,
  submit_key text NOT NULL,
  section    text,                               -- comic/novel/cardnews/poster (접수에서 복사)
  상         text,                               -- 대상 / 금상 / 은상 / 동상 / 장려상
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (code, submit_key)
);

-- 발급된 상장
CREATE TABLE IF NOT EXISTS 투닝콘테스트_상장 (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code        text NOT NULL,
  submit_key  text NOT NULL,
  상          text,
  교수명       text,
  대학         text,
  직함         text,
  직인배치     jsonb,                            -- {x, y, size} — 직인 원본은 저장하지 않음
  상장_url     text,                             -- 합성이 끝난 상장 이미지
  확정일시     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (code, submit_key)
);

-- 이미 실행한 적이 있는 경우를 위한 정리: 예전의 '교수님당 1건' 규칙과 section 컬럼 보강
ALTER TABLE 투닝콘테스트_배정 ADD COLUMN IF NOT EXISTS section text;
DROP INDEX IF EXISTS 투닝콘테스트_배정_교수당1건_uq;
UPDATE 투닝콘테스트_배정 a SET section = s.section
  FROM 투닝콘테스트_접수 s
 WHERE a.section IS NULL AND s.submit_key = a.submit_key;

-- 교수님(대학)당 부문별 1건 · 작품당 1분.
-- 같은 교수님에게 같은 부문의 다른 작품을 다시 배정하면 교체된다.
CREATE UNIQUE INDEX IF NOT EXISTS 투닝콘테스트_배정_교수부문1건_uq ON 투닝콘테스트_배정 (code, section);
CREATE UNIQUE INDEX IF NOT EXISTS 투닝콘테스트_배정_작품당1명_uq   ON 투닝콘테스트_배정 (submit_key);
CREATE INDEX IF NOT EXISTS 투닝콘테스트_배정_코드_idx ON 투닝콘테스트_배정 (code);
CREATE INDEX IF NOT EXISTS 투닝콘테스트_상장_코드_idx ON 투닝콘테스트_상장 (code);

ALTER TABLE 투닝콘테스트_심사위원 ENABLE ROW LEVEL SECURITY;
ALTER TABLE 투닝콘테스트_배정     ENABLE ROW LEVEL SECURITY;
ALTER TABLE 투닝콘테스트_상장     ENABLE ROW LEVEL SECURITY;
-- 정책 없음 = anon 직접 접근 불가. 아래 RPC 로만.

COMMIT;

-- =====================================================
-- 0) Storage — 상장 이미지 업로드 경로
--
--    익명 업로드는 v8 이후 'entries/' 만 허용돼 있다. 상장 이미지는
--    'certificates/' 아래에 올리며, 이 경로만 추가로 연다.
--    파일명은 페이지가 무작위로 만들고, 교수님이 코드를 입력해 '확정'해야만
--    DB 에 연결된다(투닝콘테스트_상장저장). 연결되지 않은 파일은 쓰이지 않는다.
-- =====================================================
DROP POLICY IF EXISTS "투닝콘테스트_상장_업로드" ON storage.objects;
CREATE POLICY "투닝콘테스트_상장_업로드" ON storage.objects
  FOR INSERT TO anon
  WITH CHECK (bucket_id = 'submissions' AND name LIKE 'certificates/%');

-- =====================================================
-- 1) 교수 인증 — 코드로 본인 정보와 '배정된 작품만' 돌려준다
--
--    배정되지 않은 접수는 한 건도 나오지 않는다.
--    연락처·이메일 등 심사에 불필요한 개인정보는 제외한다.
-- =====================================================
DROP FUNCTION IF EXISTS public.투닝콘테스트_교수인증(text);

CREATE FUNCTION public.투닝콘테스트_교수인증(p_code text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_code  text := upper(btrim(coalesce(p_code, '')));
  v_judge 투닝콘테스트_심사위원%ROWTYPE;
  v_works jsonb;
BEGIN
  SELECT * INTO v_judge FROM 투닝콘테스트_심사위원 WHERE code = v_code AND active;
  IF NOT FOUND THEN
    PERFORM pg_sleep(1);          -- 코드 대입 공격을 늦춘다
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_code');
  END IF;

  SELECT coalesce(jsonb_agg(w ORDER BY w->>'section', w->>'name'), '[]'::jsonb) INTO v_works
    FROM (
      SELECT jsonb_build_object(
               'submit_key',   s.submit_key,
               'name',         s.name,
               'school',       s.school,
               'school_level', s.school_level,
               'grade',        s.grade,
               'class',        s.class,
               'section',      s.section,
               'topic',        s.topic,
               'pdf_url',      s.pdf_url,
               'board_link',   s.board_link,
               'teacher_name', s.teacher_name,
               '상',            a.상,
               'issued',       (c.id IS NOT NULL),
               'issued_url',   c.상장_url,
               'issued_at',    c.확정일시
             ) AS w
        FROM 투닝콘테스트_배정 a
        JOIN 투닝콘테스트_접수 s ON s.submit_key = a.submit_key
        LEFT JOIN 투닝콘테스트_상장 c ON c.code = a.code AND c.submit_key = a.submit_key
       WHERE a.code = v_code
    ) t;

  RETURN jsonb_build_object(
    'ok',    true,
    '교수명', v_judge.교수명,
    '대학',   v_judge.대학,
    '직함',   v_judge.직함,
    'works', v_works);
END $fn$;

REVOKE ALL ON FUNCTION public.투닝콘테스트_교수인증(text) FROM public;
GRANT EXECUTE ON FUNCTION public.투닝콘테스트_교수인증(text) TO anon, authenticated;

-- =====================================================
-- 2) 상장 확정 저장
--    교수님이 직인 위치를 잡고 '완료'를 누르면 호출된다.
-- =====================================================
DROP FUNCTION IF EXISTS public.투닝콘테스트_상장저장(text, text, jsonb);

CREATE FUNCTION public.투닝콘테스트_상장저장(p_code text, p_submit_key text, p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_code text := upper(btrim(coalesce(p_code, '')));
  v_key  text := upper(btrim(coalesce(p_submit_key, '')));
  v_ok   boolean;
BEGIN
  -- 코드가 유효하고, 그 코드에 이 작품이 실제로 배정돼 있어야 한다
  SELECT true INTO v_ok
    FROM 투닝콘테스트_배정 a
    JOIN 투닝콘테스트_심사위원 j ON j.code = a.code AND j.active
   WHERE a.code = v_code AND a.submit_key = v_key;
  IF NOT coalesce(v_ok, false) THEN
    PERFORM pg_sleep(1);
    RAISE EXCEPTION 'not_assigned';
  END IF;

  IF coalesce(btrim(p_payload->>'상장_url'), '') = '' THEN
    RAISE EXCEPTION 'certificate_required';
  END IF;

  INSERT INTO 투닝콘테스트_상장
    (code, submit_key, 상, 교수명, 대학, 직함, 직인배치, 상장_url)
  SELECT v_code, v_key,
         (SELECT a.상 FROM 투닝콘테스트_배정 a WHERE a.code = v_code AND a.submit_key = v_key),
         nullif(btrim(coalesce(p_payload->>'교수명', '')), ''),
         nullif(btrim(coalesce(p_payload->>'대학', '')), ''),
         nullif(btrim(coalesce(p_payload->>'직함', '')), ''),
         p_payload->'직인배치',
         btrim(p_payload->>'상장_url')
  ON CONFLICT (code, submit_key) DO UPDATE
    SET 교수명 = EXCLUDED.교수명, 대학 = EXCLUDED.대학, 직함 = EXCLUDED.직함,
        직인배치 = EXCLUDED.직인배치, 상장_url = EXCLUDED.상장_url,
        확정일시 = now();

  RETURN jsonb_build_object('ok', true);
END $fn$;

REVOKE ALL ON FUNCTION public.투닝콘테스트_상장저장(text, text, jsonb) FROM public;
GRANT EXECUTE ON FUNCTION public.투닝콘테스트_상장저장(text, text, jsonb) TO anon, authenticated;

-- =====================================================
-- 3) 상장 확정 메일 — 운영자에게 알린다
--    v13 의 메일 설정(투닝콘테스트_설정)을 그대로 쓴다.
-- =====================================================
CREATE OR REPLACE FUNCTION public.투닝콘테스트_상장알림()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE
  v_api  text;
  v_on   text;
  v_from text;
  v_to   text;
  v_stu  record;
  v_html text;
BEGIN
  SELECT value INTO v_on FROM 투닝콘테스트_설정 WHERE key = '메일발송';
  IF coalesce(v_on, 'on') <> 'on' THEN RETURN NEW; END IF;

  SELECT btrim(value) INTO v_api  FROM 투닝콘테스트_설정 WHERE key = 'RESEND_API_KEY';
  IF coalesce(v_api, '') = '' THEN RETURN NEW; END IF;

  SELECT value INTO v_from FROM 투닝콘테스트_설정 WHERE key = '메일발신';
  SELECT value INTO v_to   FROM 투닝콘테스트_설정 WHERE key = '상장알림수신';
  v_from := coalesce(nullif(btrim(v_from), ''), '투닝 공모전 <support@tooning.io>');
  v_to   := coalesce(nullif(btrim(v_to),   ''), 'leo@tooning.io');

  SELECT s.name, s.school, s.grade, s.section, s.topic
    INTO v_stu
    FROM 투닝콘테스트_접수 s WHERE s.submit_key = NEW.submit_key LIMIT 1;

  v_html :=
    '<div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',sans-serif;font-size:15px;line-height:1.75;color:#222">'
    || '<h2 style="margin:0 0 14px">디지털 상장이 발급되었습니다</h2>'
    || '<p><b>' || coalesce(NEW.대학, '') || '</b> ' || coalesce(NEW.교수명, '')
    || ' ' || coalesce(NEW.직함, '교수') || '</p>'
    || '<hr style="border:none;border-top:1px solid #eee;margin:14px 0">'
    || '<p>수상자: <b>' || coalesce(v_stu.name, '') || '</b> (' || coalesce(v_stu.school, '')
    || ' · ' || coalesce(v_stu.grade, '') || ')<br>'
    || '작품: ' || coalesce(v_stu.topic, '') || '<br>'
    || '상: ' || coalesce(NEW.상, '-') || '<br>'
    || '접수번호: ' || NEW.submit_key || '</p>'
    || '<p><a href="' || coalesce(NEW.상장_url, '') || '">상장 이미지 열기</a></p>'
    || '</div>';

  BEGIN
    PERFORM net.http_post(
      url := 'https://api.resend.com/emails',
      headers := jsonb_build_object(
        'Authorization', 'Bearer ' || v_api,
        'Content-Type',  'application/json',
        'User-Agent',    'tooning-contest/1.0 (+https://tooning.io)'),
      body := jsonb_build_object(
        'from',    v_from,
        'to',      jsonb_build_array(v_to),
        'subject', '[제2회 투닝 국제 공모전] 상장 발급 — ' || coalesce(v_stu.name, '')
                   || ' (' || coalesce(NEW.대학, '') || ')',
        'html',    v_html));
  EXCEPTION WHEN others THEN
    NULL;   -- 메일이 실패해도 상장 저장은 유지
  END;

  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS 투닝콘테스트_상장알림_trg ON 투닝콘테스트_상장;
CREATE TRIGGER 투닝콘테스트_상장알림_trg
AFTER INSERT OR UPDATE OF 상장_url ON 투닝콘테스트_상장
FOR EACH ROW EXECUTE FUNCTION public.투닝콘테스트_상장알림();

-- =====================================================
-- 4) 관리자 — 심사위원 코드 발급 + 작품 배정
--    p_rows: [{"교수명":"홍길동","대학":"○○대학교","직함":"교수",
--              "email":"...","submit_key":"TC-...","상":"금상"}, ...]
--    code 를 넣지 않으면 자동 생성한다. 같은 교수님께 다른 부문 작품을
--    배정하려면 처음 발급된 code 를 적어 넣는다 (교수님당 부문별 1건, 최대 4건).
-- =====================================================
DROP FUNCTION IF EXISTS public.투닝콘테스트_심사위원등록(text, jsonb);

CREATE FUNCTION public.투닝콘테스트_심사위원등록(p_pw text, p_rows jsonb)
RETURNS TABLE (out_code text, out_교수명 text, out_대학 text, out_submit_key text, out_상 text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_pw CONSTANT text := '2509';
  r    jsonb;
  v_c  text;
  v_k  text;
  v_s  text;
BEGIN
  IF p_pw IS DISTINCT FROM v_pw THEN
    PERFORM pg_sleep(1);
    RAISE EXCEPTION 'unauthorized';
  END IF;

  FOR r IN SELECT * FROM jsonb_array_elements(p_rows) LOOP
    v_c := upper(btrim(coalesce(r->>'code', '')));
    IF v_c = '' THEN
      -- PRO-XXXX-XXXX-XXXX (헷갈리는 0/O/1/I 제외)
      SELECT 'PRO-' || string_agg(ch, '' ORDER BY i)
        INTO v_c
        FROM (SELECT i,
                     CASE WHEN i IN (5, 10) THEN '-'
                          ELSE substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789',
                                      1 + floor(random() * 32)::int, 1) END AS ch
                FROM generate_series(1, 14) AS i) g;
    END IF;

    INSERT INTO 투닝콘테스트_심사위원 (code, 교수명, 대학, 직함, email)
    VALUES (v_c, btrim(r->>'교수명'), btrim(r->>'대학'),
            nullif(btrim(coalesce(r->>'직함', '')), ''),
            nullif(btrim(coalesce(r->>'email', '')), ''))
    ON CONFLICT (code) DO UPDATE
      SET 교수명 = EXCLUDED.교수명, 대학 = EXCLUDED.대학,
          직함 = coalesce(EXCLUDED.직함, 투닝콘테스트_심사위원.직함),
          email = coalesce(EXCLUDED.email, 투닝콘테스트_심사위원.email);

    IF coalesce(btrim(r->>'submit_key'), '') <> '' THEN
      v_k := upper(btrim(r->>'submit_key'));
      -- 부문은 접수에서 가져온다 (재접수가 있으면 가장 최근 것)
      SELECT s.section INTO v_s FROM 투닝콘테스트_접수 s
       WHERE s.submit_key = v_k ORDER BY s.created_at DESC LIMIT 1;
      IF v_s IS NULL THEN
        RAISE EXCEPTION 'unknown_submit_key: %', v_k;
      END IF;

      -- 교수님당 부문별 1건: 같은 부문에 이미 배정돼 있으면 작품을 교체한다.
      -- 같은 작품이 다른 교수님에게 이미 배정돼 있으면 유니크 위반으로 멈춘다.
      INSERT INTO 투닝콘테스트_배정 (code, submit_key, section, 상)
      VALUES (v_c, v_k, v_s, nullif(btrim(coalesce(r->>'상', '')), ''))
      ON CONFLICT (code, section) DO UPDATE
        SET submit_key = EXCLUDED.submit_key, 상 = EXCLUDED.상;
    END IF;

    RETURN QUERY
      SELECT v_c, btrim(r->>'교수명'), btrim(r->>'대학'),
             nullif(upper(btrim(coalesce(r->>'submit_key', ''))), ''),
             nullif(btrim(coalesce(r->>'상', '')), '');
  END LOOP;
END $fn$;

REVOKE ALL ON FUNCTION public.투닝콘테스트_심사위원등록(text, jsonb) FROM public;
GRANT EXECUTE ON FUNCTION public.투닝콘테스트_심사위원등록(text, jsonb) TO anon, authenticated;

-- =====================================================
-- 5) 관리자 — 발급 현황
-- =====================================================
DROP FUNCTION IF EXISTS public.투닝콘테스트_상장현황(text);

CREATE FUNCTION public.투닝콘테스트_상장현황(p_pw text)
RETURNS TABLE (
  out_code       text,
  out_교수명      text,
  out_대학        text,
  out_submit_key text,
  out_학생        text,
  out_학교        text,
  out_상          text,
  out_발급        boolean,
  out_상장_url    text,
  out_확정일시    timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_pw CONSTANT text := '2509';
BEGIN
  IF p_pw IS DISTINCT FROM v_pw THEN
    PERFORM pg_sleep(1);
    RAISE EXCEPTION 'unauthorized';
  END IF;

  RETURN QUERY
  SELECT j.code, j.교수명, j.대학, a.submit_key, s.name, s.school, a.상,
         (c.id IS NOT NULL), c.상장_url, c.확정일시
    FROM 투닝콘테스트_심사위원 j
    LEFT JOIN 투닝콘테스트_배정 a ON a.code = j.code
    LEFT JOIN 투닝콘테스트_접수 s ON s.submit_key = a.submit_key
    LEFT JOIN 투닝콘테스트_상장 c ON c.code = a.code AND c.submit_key = a.submit_key
   ORDER BY j.대학, j.교수명;
END $fn$;

REVOKE ALL ON FUNCTION public.투닝콘테스트_상장현황(text) FROM public;
GRANT EXECUTE ON FUNCTION public.투닝콘테스트_상장현황(text) TO anon, authenticated;

-- =====================================================
-- 적용 후 확인
-- =====================================================
-- 1) 테스트 심사위원 한 분 발급 (submit_key 는 실제 접수번호로)
--    SELECT * FROM public.투닝콘테스트_심사위원등록('2509', '[
--      {"교수명":"홍길동","대학":"테스트대학교","직함":"교수",
--       "submit_key":"TC-0E4C-4394","상":"금상"}]'::jsonb);
--
-- 2) 나온 코드로 인증이 되는지
--    SELECT public.투닝콘테스트_교수인증('PRO-....-....-....');
--
-- 3) 발급 현황
--    SELECT * FROM public.투닝콘테스트_상장현황('2509');
--
-- 상장 알림 메일 수신처를 바꾸려면:
--    INSERT INTO 투닝콘테스트_설정 (key, value) VALUES ('상장알림수신','leo@tooning.io')
--    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
