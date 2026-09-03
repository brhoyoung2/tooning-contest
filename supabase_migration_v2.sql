-- =====================================================
-- [투닝콘테스트] v2 마이그레이션
--   ① 이메일 필드 추가 (보호자/지도교사 — 결과 안내 수신처)
--   ② 보안 강화: anon 직접 접근 전면 차단 → SECURITY DEFINER RPC 게이트
--   ③ 접수키(submit_key) 발급 + 접수키 전용 조회
--   ④ 이메일+부문 기준 재제출 덮어쓰기 (1인 1작품 키)
--
-- 전제: supabase_schema.sql 이 이미 실행된 상태
-- 성격: 비파괴 (기존 데이터 유지, DROP TABLE 없음)
-- 실행: Supabase 대시보드 → SQL Editor → 전체 붙여넣기 → Run
-- =====================================================

BEGIN;

-- =====================================================
-- 1. 접수 테이블 컬럼 추가
-- =====================================================
ALTER TABLE 투닝콘테스트_접수
  ADD COLUMN IF NOT EXISTS contact_email TEXT,                          -- 보호자/지도교사 이메일 (필수 — RPC에서 검증)
  ADD COLUMN IF NOT EXISTS consent       BOOLEAN NOT NULL DEFAULT false, -- 개인정보 수집·이용 동의 기록
  ADD COLUMN IF NOT EXISTS submit_key    TEXT,                          -- 접수키 (조회 전용, 예: TC-7K3Q-2M9X)
  ADD COLUMN IF NOT EXISTS updated_at    TIMESTAMPTZ DEFAULT now();     -- 재제출(덮어쓰기) 시각

COMMENT ON COLUMN 투닝콘테스트_접수.contact_email IS '보호자 또는 지도교사 이메일. contact_type 이 가리키는 대상의 이메일이며 결과 안내 수신처.';
COMMENT ON COLUMN 투닝콘테스트_접수.submit_key    IS '접수 조회 전용 랜덤 키. 이름/이메일 열거 공격 방지용.';

-- 학년 → 학교급(초/중/고) 자동 산출 : 부문×학교급 분리 심사·집계용
ALTER TABLE 투닝콘테스트_접수
  ADD COLUMN IF NOT EXISTS school_level TEXT
  GENERATED ALWAYS AS (
    CASE
      WHEN grade LIKE '초등%' THEN '초등'
      WHEN grade LIKE '중학%' THEN '중학'
      WHEN grade LIKE '고등%' THEN '고등'
      ELSE '기타'
    END
  ) STORED;

-- =====================================================
-- 2. 제약 조건 · 인덱스
-- =====================================================

-- 1인 1작품 키: 같은 이메일 + 같은 부문 = 재제출(UPDATE). 부문이 다르면 별건 허용.
CREATE UNIQUE INDEX IF NOT EXISTS 투닝콘테스트_접수_이메일부문_uk
  ON 투닝콘테스트_접수 (lower(contact_email), section)
  WHERE contact_email IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS 투닝콘테스트_접수_접수키_uk
  ON 투닝콘테스트_접수 (submit_key)
  WHERE submit_key IS NOT NULL;

-- 심사·집계 조회용
CREATE INDEX IF NOT EXISTS 투닝콘테스트_접수_부문학교급_idx
  ON 투닝콘테스트_접수 (section, school_level, created_at DESC);

-- =====================================================
-- 3. 보안: anon 직접 접근 전면 차단
--    (기존에는 anon INSERT 정책이 열려 있었고, SELECT 가 열려 있으면
--     이름만으로 타인의 접수 정보 열람이 가능했음)
-- =====================================================
DROP POLICY IF EXISTS "투닝콘테스트_접수_anon_insert" ON 투닝콘테스트_접수;

-- 혹시 대시보드에서 추가된 다른 정책이 있으면 함께 제거
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT policyname FROM pg_policies
     WHERE schemaname = 'public' AND tablename = '투닝콘테스트_접수'
  LOOP
    EXECUTE format('DROP POLICY %I ON public.%I', r.policyname, '투닝콘테스트_접수');
  END LOOP;
END $$;

-- RLS 활성 상태 확인 (정책이 하나도 없으므로 anon/authenticated 는 전부 차단됨)
ALTER TABLE 투닝콘테스트_접수 ENABLE ROW LEVEL SECURITY;
ALTER TABLE 투닝콘테스트_심사 ENABLE ROW LEVEL SECURITY;

-- 테이블 권한 자체를 회수 (RLS 이전 단계에서 차단)
REVOKE ALL ON TABLE 투닝콘테스트_접수 FROM anon, authenticated;
REVOKE ALL ON TABLE 투닝콘테스트_심사 FROM anon, authenticated;
REVOKE ALL ON TABLE 투닝콘테스트_리뷰 FROM anon, authenticated;

-- =====================================================
-- 4. 접수 RPC — 유일한 쓰기 경로
--    반환: {"status":"created"|"updated", "key":"TC-XXXX-XXXX"}
-- =====================================================
CREATE OR REPLACE FUNCTION public.투닝콘테스트_제출(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  -- 접수 기간 (KST). 운영 일정이 바뀌면 이 두 줄만 수정하세요.
  v_open   CONSTANT timestamptz := '2026-09-30 00:00:00+09';
  v_close  CONSTANT timestamptz := '2026-10-30 23:59:59+09';

  v_email    text := lower(btrim(coalesce(p_payload->>'contact_email', '')));
  v_section  text := btrim(coalesce(p_payload->>'section', ''));
  v_editor   text := btrim(coalesce(p_payload->>'link_editor', ''));
  v_name     text := btrim(coalesce(p_payload->>'name', ''));
  v_school   text := btrim(coalesce(p_payload->>'school', ''));
  v_grade    text := btrim(coalesce(p_payload->>'grade', ''));
  v_class    text := btrim(coalesce(p_payload->>'class', ''));
  v_ctype    text := btrim(coalesce(p_payload->>'contact_type', ''));
  v_topic    text := btrim(coalesce(p_payload->>'topic', ''));

  v_id       uuid;
  v_key      text;
  v_status   text;
  v_try      int := 0;
BEGIN
  -- ── 접수 기간 (프런트 우회 방지: 서버에서도 반드시 확인) ──
  IF now() < v_open  THEN RAISE EXCEPTION 'not_open'; END IF;
  IF now() > v_close THEN RAISE EXCEPTION 'closed';   END IF;

  -- ── 개인정보 동의 (미동의 접수 거부 + 동의 사실 기록) ──
  IF coalesce((p_payload->>'consent')::boolean, false) IS NOT TRUE THEN
    RAISE EXCEPTION 'consent_required';
  END IF;

  -- ── 필수값 ──
  IF v_name = '' OR v_school = '' OR v_grade = '' OR v_class = '' OR v_topic = '' THEN
    RAISE EXCEPTION 'missing_required';
  END IF;

  -- ── 이메일 (결과 안내 수신처) ──
  IF v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' THEN
    RAISE EXCEPTION 'invalid_email';
  END IF;

  -- ── 부문 화이트리스트 ──
  IF v_section NOT IN ('comic', 'novel', 'cardnews', 'poster') THEN
    RAISE EXCEPTION 'invalid_section';
  END IF;

  -- ── 연락처 유형 ──
  IF v_ctype NOT IN ('teacher', 'parent') THEN
    RAISE EXCEPTION 'invalid_contact_type';
  END IF;

  -- ── 공식 제출작 링크는 투닝 에디터 링크만 허용 ──
  IF position('tooning.io' in lower(v_editor)) = 0 THEN
    RAISE EXCEPTION 'invalid_link';
  END IF;

  -- ── 같은 이메일 + 같은 부문 = 재제출(덮어쓰기) ──
  SELECT id, submit_key INTO v_id, v_key
    FROM 투닝콘테스트_접수
   WHERE lower(contact_email) = v_email
     AND section = v_section
   LIMIT 1;

  IF v_id IS NOT NULL THEN
    UPDATE 투닝콘테스트_접수 SET
      name                = v_name,
      school              = v_school,
      grade               = v_grade,
      class               = v_class,
      contact_type        = v_ctype,
      contact_email       = v_email,
      teacher_phone       = nullif(btrim(coalesce(p_payload->>'teacher_phone', '')), ''),
      teacher_name        = nullif(btrim(coalesce(p_payload->>'teacher_name',  '')), ''),
      parent_phone        = nullif(btrim(coalesce(p_payload->>'parent_phone',  '')), ''),
      topic               = v_topic,
      link_proposal       = nullif(btrim(coalesce(p_payload->>'link_proposal',       '')), ''),
      work_description    = nullif(btrim(coalesce(p_payload->>'work_description',    '')), ''),
      link_novel          = nullif(btrim(coalesce(p_payload->>'link_novel',          '')), ''),
      link_novel_proposal = nullif(btrim(coalesce(p_payload->>'link_novel_proposal', '')), ''),
      link_editor         = v_editor,
      sns_link            = nullif(btrim(coalesce(p_payload->>'sns_link', '')), ''),
      user_agent          = left(coalesce(p_payload->>'user_agent', ''), 500),
      consent             = true,
      updated_at          = now()
    WHERE id = v_id;

    v_status := 'updated';

    -- 과거에 발급되지 않은 건이면 이 시점에 발급
    IF v_key IS NULL THEN
      LOOP
        v_try := v_try + 1;
        v_key := 'TC-' || upper(substr(md5(gen_random_uuid()::text), 1, 4))
                       || '-' || upper(substr(md5(gen_random_uuid()::text), 1, 4));
        BEGIN
          UPDATE 투닝콘테스트_접수 SET submit_key = v_key WHERE id = v_id;
          EXIT;
        EXCEPTION WHEN unique_violation THEN
          IF v_try >= 5 THEN RAISE EXCEPTION 'key_generation_failed'; END IF;
        END;
      END LOOP;
    END IF;

  ELSE
    LOOP
      v_try := v_try + 1;
      v_key := 'TC-' || upper(substr(md5(gen_random_uuid()::text), 1, 4))
                     || '-' || upper(substr(md5(gen_random_uuid()::text), 1, 4));
      BEGIN
        INSERT INTO 투닝콘테스트_접수 (
          name, school, grade, class,
          contact_type, contact_email, teacher_phone, teacher_name, parent_phone,
          section, topic,
          link_proposal, work_description, link_novel, link_novel_proposal, link_editor,
          sns_link, user_agent, consent, submit_key, updated_at
        ) VALUES (
          v_name, v_school, v_grade, v_class,
          v_ctype, v_email,
          nullif(btrim(coalesce(p_payload->>'teacher_phone', '')), ''),
          nullif(btrim(coalesce(p_payload->>'teacher_name',  '')), ''),
          nullif(btrim(coalesce(p_payload->>'parent_phone',  '')), ''),
          v_section, v_topic,
          nullif(btrim(coalesce(p_payload->>'link_proposal',       '')), ''),
          nullif(btrim(coalesce(p_payload->>'work_description',    '')), ''),
          nullif(btrim(coalesce(p_payload->>'link_novel',          '')), ''),
          nullif(btrim(coalesce(p_payload->>'link_novel_proposal', '')), ''),
          v_editor,
          nullif(btrim(coalesce(p_payload->>'sns_link', '')), ''),
          left(coalesce(p_payload->>'user_agent', ''), 500),
          true, v_key, now()
        );
        EXIT;
      EXCEPTION WHEN unique_violation THEN
        -- 접수키 충돌이면 재발급, 이메일+부문 충돌이면 재제출로 처리해야 하므로 오류
        IF v_try >= 5 THEN RAISE EXCEPTION 'submit_failed'; END IF;
      END;
    END LOOP;

    v_status := 'created';
  END IF;

  RETURN jsonb_build_object('status', v_status, 'key', v_key);
END;
$$;

-- =====================================================
-- 5. 조회 RPC — 접수키로만 1건 (이름/이메일 열거 불가)
-- =====================================================
CREATE OR REPLACE FUNCTION public.투닝콘테스트_조회(p_key text)
RETURNS TABLE (
  name       text,
  school     text,
  grade      text,
  section    text,
  topic      text,
  status     text,
  created_at timestamptz,
  updated_at timestamptz
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT s.name, s.school, s.grade, s.section, s.topic, s.status, s.created_at, s.updated_at
    FROM 투닝콘테스트_접수 s
   WHERE s.submit_key = upper(btrim(p_key))
   LIMIT 1;
$$;

-- =====================================================
-- 6. 실행 권한 — anon 은 이 두 함수만 호출 가능
-- =====================================================
REVOKE ALL ON FUNCTION public.투닝콘테스트_제출(jsonb) FROM public;
REVOKE ALL ON FUNCTION public.투닝콘테스트_조회(text)  FROM public;

GRANT EXECUTE ON FUNCTION public.투닝콘테스트_제출(jsonb) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.투닝콘테스트_조회(text)  TO anon, authenticated;

COMMIT;

-- =====================================================
-- 적용 후 확인 쿼리 (선택)
-- =====================================================
-- 1) anon 정책이 모두 제거되었는지
--    SELECT policyname FROM pg_policies WHERE tablename = '투닝콘테스트_접수';   -- 0건이어야 정상
--
-- 2) 컬럼이 추가되었는지
--    SELECT column_name FROM information_schema.columns
--     WHERE table_name = '투닝콘테스트_접수' ORDER BY ordinal_position;
--
-- 3) 접수 기간 전에는 not_open 이 나야 정상 (접수 오픈 전 테스트용)
--    SELECT public.투닝콘테스트_제출('{}'::jsonb);
