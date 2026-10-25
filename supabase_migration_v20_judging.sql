-- =====================================================
-- [투닝콘테스트] v20 — AI 1차 심사 결과 저장
--
--   AI 심사는 '1차 정렬 + 근거 생성' 용도입니다. 최종 순위는
--   18개 협력 대학 교수님들이 확정합니다. 그래서 이 테이블은
--   접수 원본을 건드리지 않고 '옆에' 점수를 쌓습니다.
--
--   · 4축 0.0~10.0 (소수 1자리) · 총점은 자동 계산
--   · 같은 접수에 여러 차수(1차/2차 재독)를 쌓을 수 있음
--   · PDF 없이 텍스트만으로 채점한 건은 evidence='text_only' 로 구분
--     (작품을 보지 않고 매긴 점수를 같은 선에서 비교하지 않기 위함)
--
--   ⚠️ 테이블 이름이 투닝콘테스트_'AI'심사 인 이유
--      초기 스키마(supabase_schema.sql)에 이미 투닝콘테스트_심사 테이블이
--      다른 구조(submission_id, ai_score_* INT 1~10)로 만들어져 있습니다.
--      거기에 끼워 맞추면 CHECK 제약과 투닝콘테스트_리뷰 뷰까지 건드려야 해서,
--      기존 테이블은 그대로 두고 새 테이블을 따로 만듭니다.
--      기존 테이블은 나중에 교수님 최종 심사를 담는 용도로 쓸 수 있습니다.
--
-- 전제: v17, v18 실행 완료
-- 성격: 비파괴 · 여러 번 실행해도 안전
-- 실행: Supabase 대시보드 → SQL Editor → 전체 붙여넣기 → Run
-- =====================================================

BEGIN;

CREATE TABLE IF NOT EXISTS 투닝콘테스트_AI심사 (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  submit_key  text NOT NULL,
  round       int  NOT NULL DEFAULT 1,          -- 1 = 전량 1차, 2 = 상위밴드 재독
  evidence    text NOT NULL DEFAULT 'pdf',      -- pdf | text_only
  model       text,
  주제적합성   numeric(3,1) NOT NULL CHECK (주제적합성 BETWEEN 0 AND 10),
  창의성      numeric(3,1) NOT NULL CHECK (창의성   BETWEEN 0 AND 10),
  완성도      numeric(3,1) NOT NULL CHECK (완성도   BETWEEN 0 AND 10),
  표현력      numeric(3,1) NOT NULL CHECK (표현력   BETWEEN 0 AND 10),
  총점        numeric(4,1) GENERATED ALWAYS AS (주제적합성 + 창의성 + 완성도 + 표현력) STORED,
  총평        text,
  근거        text,
  세부        jsonb,                            -- 컷분석 등 부문별 추가 항목
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (submit_key, round)
);

CREATE INDEX IF NOT EXISTS 투닝콘테스트_AI심사_접수키_idx ON 투닝콘테스트_AI심사 (submit_key);

ALTER TABLE 투닝콘테스트_AI심사 ENABLE ROW LEVEL SECURITY;
-- 정책 없음 = anon 직접 접근 불가. 아래 RPC 로만 읽고 쓴다.

COMMIT;

-- =====================================================
-- 1) 심사 결과 저장 (배치 upsert)
--    p_rows 예시:
--      [{"submit_key":"TC-...","round":1,"evidence":"pdf","model":"...",
--        "주제적합성":7.4,"창의성":6.8,"완성도":7.1,"표현력":7.6,
--        "총평":"...","근거":"...","세부":{...}}, ...]
-- =====================================================
CREATE OR REPLACE FUNCTION public.투닝콘테스트_심사저장(p_pw text, p_rows jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_pw CONSTANT text := '2509';   -- ← 관리자 비밀번호. 다른 RPC 와 동일하게 유지
  v_n  int := 0;
BEGIN
  IF p_pw IS DISTINCT FROM v_pw THEN
    PERFORM pg_sleep(1);
    RAISE EXCEPTION 'unauthorized';
  END IF;

  INSERT INTO 투닝콘테스트_AI심사
    (submit_key, round, evidence, model, 주제적합성, 창의성, 완성도, 표현력, 총평, 근거, 세부)
  SELECT upper(btrim(r->>'submit_key')),
         coalesce((r->>'round')::int, 1),
         coalesce(nullif(btrim(r->>'evidence'), ''), 'pdf'),
         r->>'model',
         (r->>'주제적합성')::numeric, (r->>'창의성')::numeric,
         (r->>'완성도')::numeric,    (r->>'표현력')::numeric,
         r->>'총평', r->>'근거', r->'세부'
    FROM jsonb_array_elements(p_rows) AS r
   WHERE EXISTS (SELECT 1 FROM 투닝콘테스트_접수 s
                  WHERE s.submit_key = upper(btrim(r->>'submit_key')))
  ON CONFLICT (submit_key, round) DO UPDATE
    SET evidence = EXCLUDED.evidence, model = EXCLUDED.model,
        주제적합성 = EXCLUDED.주제적합성, 창의성 = EXCLUDED.창의성,
        완성도 = EXCLUDED.완성도,       표현력 = EXCLUDED.표현력,
        총평 = EXCLUDED.총평, 근거 = EXCLUDED.근거, 세부 = EXCLUDED.세부,
        created_at = now();

  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN jsonb_build_object('saved', v_n);
END $fn$;

REVOKE ALL ON FUNCTION public.투닝콘테스트_심사저장(text, jsonb) FROM public;
GRANT EXECUTE ON FUNCTION public.투닝콘테스트_심사저장(text, jsonb) TO anon, authenticated;

-- =====================================================
-- 2) 심사 결과 조회 — 접수 정보 + 점수 + 부문×학교급 순위
--
--    순위는 '최신 접수(심사 대상)' 안에서만 매깁니다.
--    동점은 주제적합성 → 완성도 → 창의성 → 표현력 순으로 가릅니다.
-- =====================================================
DROP FUNCTION IF EXISTS public.투닝콘테스트_심사결과(text, int);

CREATE FUNCTION public.투닝콘테스트_심사결과(p_pw text, p_round int DEFAULT 1)
RETURNS TABLE (
  submit_key   text,
  name         text,
  school       text,
  school_level text,
  grade        text,
  section      text,
  topic        text,
  evidence     text,
  주제적합성    numeric,
  창의성       numeric,
  완성도       numeric,
  표현력       numeric,
  총점         numeric,
  순위         int,
  부문내총원    int,
  총평         text,
  근거         text,
  pdf_url      text,
  board_link   text,
  judged_at    timestamptz
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
  WITH live AS (
    SELECT s.*
      FROM (SELECT e.*,
                   row_number() OVER (PARTITION BY public.투닝콘테스트_참가자키(e.name, e.school, e.grade, e.class)
                                      ORDER BY e.created_at) AS rn,
                   count(*)     OVER (PARTITION BY public.투닝콘테스트_참가자키(e.name, e.school, e.grade, e.class)) AS cnt
              FROM 투닝콘테스트_접수 e) s
     WHERE s.rn = s.cnt                                  -- 최신 접수만
  ),
  joined AS (
    SELECT l.submit_key, l.name, l.school, l.school_level, l.grade, l.section, l.topic,
           j.evidence, j.주제적합성, j.창의성, j.완성도, j.표현력, j.총점,
           j.총평, j.근거, l.pdf_url, l.board_link, j.created_at AS judged_at
      FROM live l
      JOIN 투닝콘테스트_AI심사 j ON j.submit_key = l.submit_key AND j.round = p_round
  )
  SELECT g.submit_key, g.name, g.school, g.school_level, g.grade, g.section, g.topic,
         g.evidence, g.주제적합성, g.창의성, g.완성도, g.표현력, g.총점,
         row_number() OVER (PARTITION BY g.section, g.school_level
                            ORDER BY g.총점 DESC, g.주제적합성 DESC, g.완성도 DESC,
                                     g.창의성 DESC, g.표현력 DESC)::int,
         count(*)    OVER (PARTITION BY g.section, g.school_level)::int,
         g.총평, g.근거, g.pdf_url, g.board_link, g.judged_at
    FROM joined g
   ORDER BY g.section, g.school_level, 14;
END $fn$;

REVOKE ALL ON FUNCTION public.투닝콘테스트_심사결과(text, int) FROM public;
GRANT EXECUTE ON FUNCTION public.투닝콘테스트_심사결과(text, int) TO anon, authenticated;

-- =====================================================
-- 적용 후 확인
-- =====================================================
--   SELECT section, school_level, 순위, name, 총점, evidence
--     FROM public.투닝콘테스트_심사결과('2509', 1)
--    ORDER BY section, school_level, 순위;
--
-- evidence='text_only' 인 행은 작품 실물을 보지 않고 채점한 건입니다.
-- 교수님 최종 확정 때 이 점을 반드시 함께 보셔야 합니다.
