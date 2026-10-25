-- =====================================================
-- [투닝콘테스트] v23 — 교수 로그인을 '성함 + 대학'으로
--
--   심사 코드를 없애고, 교수님이 성함과 대학만 입력해서 들어옵니다.
--   서버는 운영팀이 미리 등록한 심사위원 명단과 대조합니다.
--
--   ⚠️ 본인 확인이 약해집니다 (결정 사항)
--      교수님 성함과 대학은 홈페이지 심사위원 목록에 이미 공개돼 있어서,
--      그 목록을 보는 사람은 누구나 같은 값을 입력할 수 있습니다.
--      들어오면 배정된 학생의 이름·학교·학년·작품 PDF가 보이고,
--      상장을 발급할 수 있습니다.
--      그래서 다음 안전장치를 둡니다.
--        · 등록된 심사위원만 통과 (미등록이면 아무것도 보이지 않음)
--        · 배정된 작품 외에는 어떤 접수도 조회되지 않음
--        · 모든 접속 시도를 기록 (성공·실패, 시각) → 이상 징후 확인용
--        · 실패하면 응답을 늦춤
--      접속 기록은 아래 '적용 후 확인' 의 쿼리로 볼 수 있습니다.
--
--   · 표기 차이를 흡수합니다: 공백, 대소문자, '대학교'/'대학'/'대' 끝말
--       '건국대' = '건국대학교' = '건국 대학교'
--     상장에는 입력값이 아니라 '등록된 정식 명칭'이 들어갑니다.
--   · 같은 성함 + 같은 대학의 활성 교수님은 한 분만 등록할 수 있습니다.
--   · 내부적으로는 코드(code)를 그대로 식별자로 씁니다. 화면에는 나오지 않습니다.
--
-- 전제: v21, v22 실행 완료
-- 성격: 비파괴 · 여러 번 실행해도 안전
-- 실행: Supabase 대시보드 → SQL Editor → 전체 붙여넣기 → Run
-- =====================================================

-- 0) 이름·대학 비교용 정규화 함수
CREATE OR REPLACE FUNCTION public.투닝콘테스트_이름키(p text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT lower(regexp_replace(coalesce(p, ''), '\s+', '', 'g'))
$$;

CREATE OR REPLACE FUNCTION public.투닝콘테스트_대학키(p text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT regexp_replace(lower(regexp_replace(coalesce(p, ''), '\s+', '', 'g')), '(대학교|대학|대)$', '')
$$;

-- 1) 같은 성함 + 같은 대학의 활성 교수님은 한 분만
CREATE UNIQUE INDEX IF NOT EXISTS 투닝콘테스트_심사위원_본인확인_uq
  ON 투닝콘테스트_심사위원 (public.투닝콘테스트_이름키(교수명), public.투닝콘테스트_대학키(대학))
  WHERE active;

-- 2) 접속 기록
CREATE TABLE IF NOT EXISTS 투닝콘테스트_교수접속로그 (
  id        bigserial PRIMARY KEY,
  입력이름   text,
  입력대학   text,
  성공       boolean NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS 투닝콘테스트_교수접속로그_시각_idx ON 투닝콘테스트_교수접속로그 (created_at DESC);
ALTER TABLE 투닝콘테스트_교수접속로그 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON 투닝콘테스트_교수접속로그 FROM anon, authenticated;

-- =====================================================
-- 3) 교수 인증 — 성함 + 대학
-- =====================================================
DROP FUNCTION IF EXISTS public.투닝콘테스트_교수인증(text);
DROP FUNCTION IF EXISTS public.투닝콘테스트_교수인증(text, text);

CREATE FUNCTION public.투닝콘테스트_교수인증(p_name text, p_univ text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_judge 투닝콘테스트_심사위원%ROWTYPE;
  v_works jsonb;
  v_found boolean;
BEGIN
  IF public.투닝콘테스트_이름키(p_name) = '' OR public.투닝콘테스트_대학키(p_univ) = '' THEN
    PERFORM pg_sleep(1);
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid');
  END IF;

  SELECT * INTO v_judge
    FROM 투닝콘테스트_심사위원
   WHERE active
     AND public.투닝콘테스트_이름키(교수명) = public.투닝콘테스트_이름키(p_name)
     AND public.투닝콘테스트_대학키(대학)   = public.투닝콘테스트_대학키(p_univ)
   LIMIT 1;
  v_found := FOUND;               -- 아래 INSERT 가 FOUND 를 덮어쓰기 전에 보관한다

  INSERT INTO 투닝콘테스트_교수접속로그 (입력이름, 입력대학, 성공)
  VALUES (left(btrim(coalesce(p_name, '')), 60), left(btrim(coalesce(p_univ, '')), 60), v_found);

  IF NOT v_found THEN
    PERFORM pg_sleep(1.5);        -- 대입 시도를 늦춘다
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
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
       WHERE a.code = v_judge.code
    ) t;

  RETURN jsonb_build_object(
    'ok',    true,
    'code',  v_judge.code,        -- 이후 상장 저장 호출의 식별자 (화면에는 나오지 않음)
    '교수명', v_judge.교수명,
    '대학',   v_judge.대학,
    '직함',   v_judge.직함,
    'works', v_works);
END $fn$;

REVOKE ALL ON FUNCTION public.투닝콘테스트_교수인증(text, text) FROM public;
GRANT EXECUTE ON FUNCTION public.투닝콘테스트_교수인증(text, text) TO anon, authenticated;

-- =====================================================
-- 4) 심사위원 등록 — code 를 적지 않으면 같은 성함+대학의 기존 교수님을 찾는다
--    (같은 교수님께 다른 부문 작품을 추가할 때 코드를 몰라도 된다)
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
    v_c := nullif(upper(btrim(coalesce(r->>'code', ''))), '');

    IF v_c IS NULL THEN
      -- 이미 등록된 같은 분이면 그 분을 쓴다
      SELECT j.code INTO v_c FROM 투닝콘테스트_심사위원 j
       WHERE j.active
         AND public.투닝콘테스트_이름키(j.교수명) = public.투닝콘테스트_이름키(r->>'교수명')
         AND public.투닝콘테스트_대학키(j.대학)   = public.투닝콘테스트_대학키(r->>'대학');
    END IF;

    IF v_c IS NULL THEN
      -- 새 식별자 PRO-XXXX-XXXX-XXXX (헷갈리는 0/O/1/I 제외)
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
      SELECT s.section INTO v_s FROM 투닝콘테스트_접수 s
       WHERE s.submit_key = v_k ORDER BY s.created_at DESC LIMIT 1;
      IF v_s IS NULL THEN
        RAISE EXCEPTION 'unknown_submit_key: %', v_k;
      END IF;

      -- 교수님당 부문별 1건: 같은 부문에 이미 배정돼 있으면 작품을 교체한다.
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
-- 5) 관리자 — 접속 기록 조회
-- =====================================================
DROP FUNCTION IF EXISTS public.투닝콘테스트_교수접속현황(text, int);

CREATE FUNCTION public.투닝콘테스트_교수접속현황(p_pw text, p_limit int DEFAULT 200)
RETURNS TABLE (out_시각 timestamptz, out_입력이름 text, out_입력대학 text, out_성공 boolean)
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
  SELECT l.created_at, l.입력이름, l.입력대학, l.성공
    FROM 투닝콘테스트_교수접속로그 l
   ORDER BY l.created_at DESC
   LIMIT greatest(1, least(coalesce(p_limit, 200), 1000));
END $fn$;

REVOKE ALL ON FUNCTION public.투닝콘테스트_교수접속현황(text, int) FROM public;
GRANT EXECUTE ON FUNCTION public.투닝콘테스트_교수접속현황(text, int) TO anon, authenticated;

-- =====================================================
-- 적용 후 확인
-- =====================================================
-- 접속 기록 (실패가 짧은 시간에 여러 번 보이면 누군가 이름을 대입하는 중입니다)
--   SELECT created_at, 입력이름, 입력대학, 성공
--     FROM 투닝콘테스트_교수접속로그 ORDER BY created_at DESC LIMIT 50;
--
-- 로그인 시험 (등록된 분의 성함·대학으로)
--   SELECT public.투닝콘테스트_교수인증('테스트교수', '테스트대학');
