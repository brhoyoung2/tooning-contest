-- =====================================================
-- [투닝콘테스트] v24 — 교수 입장을 '개인 링크'로만
--
--   교수님마다 추측할 수 없는 개인 링크를 하나씩 발급하고,
--   그 링크로만 /professor 에 들어올 수 있게 합니다.
--   (v23 의 '성함 + 대학' 로그인은 없어집니다 — 성함·대학은 홈페이지에
--    공개돼 있어서 사칭을 막지 못했기 때문입니다.)
--
--   링크 형태:  /professor?k=<32자리 토큰>
--
--   · 토큰은 DB 의 암호학적 난수(gen_random_uuid)로 만듭니다.
--     내부 식별자 code 는 random() 으로 만든 값이라 열쇠로 쓰지 않습니다.
--   · 링크가 유출되면 그 교수님 것만 재발급(투닝콘테스트_링크재발급)합니다.
--     새 링크가 만들어지는 즉시 이전 링크는 입장도, 상장 저장도 안 됩니다.
--   · 교수님별로 처음 연 시각·마지막 접속·접속 횟수를 기록합니다.
--     아직 링크를 열지 않은 교수님께 독촉하는 데 씁니다.
--   · 잘못된 링크로 시도하면 기록을 남기고 응답을 늦춥니다.
--
-- 전제: v21, v22, v23 실행 완료
-- 성격: 비파괴 · 여러 번 실행해도 안전
-- 실행: Supabase 대시보드 → SQL Editor → 전체 붙여넣기 → Run
-- =====================================================

-- 0) 토큰·접속 현황 컬럼
ALTER TABLE 투닝콘테스트_심사위원 ADD COLUMN IF NOT EXISTS link_token  text;
ALTER TABLE 투닝콘테스트_심사위원 ADD COLUMN IF NOT EXISTS 처음접속    timestamptz;
ALTER TABLE 투닝콘테스트_심사위원 ADD COLUMN IF NOT EXISTS 마지막접속  timestamptz;
ALTER TABLE 투닝콘테스트_심사위원 ADD COLUMN IF NOT EXISTS 접속횟수    int NOT NULL DEFAULT 0;

-- 이미 등록된 교수님께 토큰을 채운다
UPDATE 투닝콘테스트_심사위원
   SET link_token = replace(gen_random_uuid()::text, '-', '')
 WHERE link_token IS NULL;

-- 앞으로 등록되는 분은 자동 발급
ALTER TABLE 투닝콘테스트_심사위원
  ALTER COLUMN link_token SET DEFAULT replace(gen_random_uuid()::text, '-', '');
ALTER TABLE 투닝콘테스트_심사위원 ALTER COLUMN link_token SET NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS 투닝콘테스트_심사위원_링크_uq
  ON 투닝콘테스트_심사위원 (link_token);

-- =====================================================
-- 1) 교수 인증 — 개인 링크의 토큰으로만
-- =====================================================
DROP FUNCTION IF EXISTS public.투닝콘테스트_교수인증(text);
DROP FUNCTION IF EXISTS public.투닝콘테스트_교수인증(text, text);

CREATE FUNCTION public.투닝콘테스트_교수인증(p_key text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_key   text := lower(btrim(coalesce(p_key, '')));
  v_judge 투닝콘테스트_심사위원%ROWTYPE;
  v_found boolean := false;
  v_works jsonb;
BEGIN
  IF v_key ~ '^[0-9a-f]{32}$' THEN
    SELECT * INTO v_judge FROM 투닝콘테스트_심사위원 WHERE active AND link_token = v_key;
    v_found := FOUND;       -- 아래 INSERT/UPDATE 가 FOUND 를 덮어쓰기 전에 보관한다
  END IF;

  IF NOT v_found THEN
    -- 실패한 토큰은 앞 6자만 남긴다 (전체를 남기면 로그가 열쇠 목록이 된다)
    INSERT INTO 투닝콘테스트_교수접속로그 (입력이름, 입력대학, 성공)
    VALUES ('(잘못된 링크)', left(v_key, 6) || '…', false);
    PERFORM pg_sleep(1.5);
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_link');
  END IF;

  UPDATE 투닝콘테스트_심사위원
     SET 처음접속   = coalesce(처음접속, now()),
         마지막접속 = now(),
         접속횟수   = 접속횟수 + 1
   WHERE id = v_judge.id;

  INSERT INTO 투닝콘테스트_교수접속로그 (입력이름, 입력대학, 성공)
  VALUES (v_judge.교수명, v_judge.대학, true);

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
    '교수명', v_judge.교수명,
    '대학',   v_judge.대학,
    '직함',   v_judge.직함,
    'works', v_works);          -- 내부 식별자(code)는 돌려주지 않는다
END $fn$;

REVOKE ALL ON FUNCTION public.투닝콘테스트_교수인증(text) FROM public;
GRANT EXECUTE ON FUNCTION public.투닝콘테스트_교수인증(text) TO anon, authenticated;

-- =====================================================
-- 2) 상장 저장 — 이제 링크 토큰으로 본인을 확인한다
--    링크를 재발급하면 이전 링크로는 저장도 되지 않는다.
-- =====================================================
DROP FUNCTION IF EXISTS public.투닝콘테스트_상장저장(text, text, jsonb);

CREATE FUNCTION public.투닝콘테스트_상장저장(p_token text, p_submit_key text, p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_key  text := upper(btrim(coalesce(p_submit_key, '')));
  v_tok  text := lower(btrim(coalesce(p_token, '')));
  v_code text;
BEGIN
  IF v_tok ~ '^[0-9a-f]{32}$' THEN
    SELECT j.code INTO v_code FROM 투닝콘테스트_심사위원 j WHERE j.active AND j.link_token = v_tok;
  END IF;

  -- 링크가 유효하고, 그 교수님께 이 작품이 실제로 배정돼 있어야 한다
  IF v_code IS NULL OR NOT EXISTS (
       SELECT 1 FROM 투닝콘테스트_배정 a WHERE a.code = v_code AND a.submit_key = v_key) THEN
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
-- 3) 심사위원 등록 — 결과에 개인 링크 토큰을 함께 돌려준다
-- =====================================================
DROP FUNCTION IF EXISTS public.투닝콘테스트_심사위원등록(text, jsonb);

CREATE FUNCTION public.투닝콘테스트_심사위원등록(p_pw text, p_rows jsonb)
RETURNS TABLE (out_code text, out_교수명 text, out_대학 text, out_submit_key text, out_상 text, out_link text)
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
  v_t  text;
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
      -- 내부 식별자 PRO-XXXX-XXXX-XXXX (열쇠가 아니라 표 안의 번호표)
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

      INSERT INTO 투닝콘테스트_배정 (code, submit_key, section, 상)
      VALUES (v_c, v_k, v_s, nullif(btrim(coalesce(r->>'상', '')), ''))
      ON CONFLICT (code, section) DO UPDATE
        SET submit_key = EXCLUDED.submit_key, 상 = EXCLUDED.상;
    END IF;

    SELECT j.link_token INTO v_t FROM 투닝콘테스트_심사위원 j WHERE j.code = v_c;

    RETURN QUERY
      SELECT v_c, btrim(r->>'교수명'), btrim(r->>'대학'),
             nullif(upper(btrim(coalesce(r->>'submit_key', ''))), ''),
             nullif(btrim(coalesce(r->>'상', '')), ''),
             v_t;
  END LOOP;
END $fn$;

REVOKE ALL ON FUNCTION public.투닝콘테스트_심사위원등록(text, jsonb) FROM public;
GRANT EXECUTE ON FUNCTION public.투닝콘테스트_심사위원등록(text, jsonb) TO anon, authenticated;

-- =====================================================
-- 4) 링크 재발급 — 유출됐거나 잃어버렸을 때
--    새 링크가 만들어지는 즉시 이전 링크는 쓸 수 없다.
-- =====================================================
DROP FUNCTION IF EXISTS public.투닝콘테스트_링크재발급(text, text, text);

CREATE FUNCTION public.투닝콘테스트_링크재발급(p_pw text, p_name text, p_univ text)
RETURNS TABLE (out_교수명 text, out_대학 text, out_link text)
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
  WITH u AS (
    UPDATE 투닝콘테스트_심사위원 j
       SET link_token = replace(gen_random_uuid()::text, '-', ''),
           처음접속 = NULL, 마지막접속 = NULL, 접속횟수 = 0
     WHERE j.active
       AND public.투닝콘테스트_이름키(j.교수명) = public.투닝콘테스트_이름키(p_name)
       AND public.투닝콘테스트_대학키(j.대학)   = public.투닝콘테스트_대학키(p_univ)
    RETURNING j.교수명 AS n, j.대학 AS d, j.link_token AS t
  )
  SELECT u.n, u.d, u.t FROM u;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found';
  END IF;
END $fn$;

REVOKE ALL ON FUNCTION public.투닝콘테스트_링크재발급(text, text, text) FROM public;
GRANT EXECUTE ON FUNCTION public.투닝콘테스트_링크재발급(text, text, text) TO anon, authenticated;

-- =====================================================
-- 5) 관리자 — 교수님별 링크와 접속·발급 현황
-- =====================================================
DROP FUNCTION IF EXISTS public.투닝콘테스트_교수링크목록(text);

CREATE FUNCTION public.투닝콘테스트_교수링크목록(p_pw text)
RETURNS TABLE (
  out_교수명 text, out_대학 text, out_직함 text, out_link text,
  out_처음접속 timestamptz, out_마지막접속 timestamptz, out_접속횟수 int,
  out_배정수 int, out_발급수 int
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
  SELECT j.교수명, j.대학, j.직함, j.link_token,
         j.처음접속, j.마지막접속, j.접속횟수,
         (SELECT count(*)::int FROM 투닝콘테스트_배정 a WHERE a.code = j.code),
         (SELECT count(*)::int FROM 투닝콘테스트_상장 c WHERE c.code = j.code)
    FROM 투닝콘테스트_심사위원 j
   WHERE j.active
   ORDER BY j.대학, j.교수명;
END $fn$;

REVOKE ALL ON FUNCTION public.투닝콘테스트_교수링크목록(text) FROM public;
GRANT EXECUTE ON FUNCTION public.투닝콘테스트_교수링크목록(text) TO anon, authenticated;

-- =====================================================
-- 적용 후 확인
-- =====================================================
-- 교수님별 링크 토큰과 접속 현황
--   SELECT 교수명, 대학, link_token, 처음접속, 접속횟수
--     FROM 투닝콘테스트_심사위원 WHERE active ORDER BY 대학;
--
-- 링크는  https://tooning-contest.vercel.app/professor?k=<link_token>
-- 터미널에서는  python judge_assign.py --links  로 전체 링크 목록(CSV)을 받을 수 있습니다.
