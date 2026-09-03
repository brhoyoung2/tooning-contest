-- =====================================================
-- [투닝콘테스트] v9 — 관리자 조회 RPC
--   /admin 페이지에서 접수 현황을 볼 수 있게 하는 비밀번호 게이트 함수
--
-- 설계: 충남 가이드 §2-2 의 "관리자 기능은 비밀번호 인자로 게이트" 패턴
--   · 테이블 직접 접근은 여전히 전면 차단
--   · 관리자 조회도 SECURITY DEFINER 함수를 통해서만
--   · 비밀번호가 틀리면 1초 지연 후 예외 (무차별 대입 속도 저하)
--
-- ⚠️ 보안 주의
--   비밀번호가 4자리 숫자라 10,000가지뿐입니다. 지연을 넣어도
--   시간을 들이면 뚫립니다. 실제 운영 전에는 아래 v_pw 값을
--   길고 추측하기 어려운 문자열로 바꾸시길 권합니다.
--   (바꾸면 admin.html 의 입력값도 같이 바꿔야 합니다 — 서버가 최종 판정)
--
-- 실행: Supabase 대시보드 → SQL Editor → 전체 붙여넣기 → Run
-- =====================================================

CREATE OR REPLACE FUNCTION public.투닝콘테스트_관리자목록(p_pw text)
RETURNS TABLE (
  id            uuid,
  created_at    timestamptz,
  updated_at    timestamptz,
  submit_key    text,
  name          text,
  school        text,
  grade         text,
  school_level  text,
  class         text,
  contact_type  text,
  contact_email text,
  teacher_name  text,
  teacher_phone text,
  parent_phone  text,
  section       text,
  topic         text,
  work_description text,
  proposal_text text,
  episodes      jsonb,
  episode_count int,
  board_link    text,
  pdf_url       text,
  status        text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_pw CONSTANT text := '2509';   -- ← 운영 전 변경 권장
BEGIN
  IF p_pw IS DISTINCT FROM v_pw THEN
    PERFORM pg_sleep(1);          -- 무차별 대입 속도 저하
    RAISE EXCEPTION 'unauthorized';
  END IF;

  RETURN QUERY
  SELECT s.id, s.created_at, s.updated_at, s.submit_key,
         s.name, s.school, s.grade, s.school_level, s.class,
         s.contact_type, s.contact_email, s.teacher_name, s.teacher_phone, s.parent_phone,
         s.section, s.topic, s.work_description, s.proposal_text,
         s.episodes,
         CASE WHEN s.episodes IS NULL THEN 0 ELSE jsonb_array_length(s.episodes) END,
         s.board_link, s.pdf_url, s.status
    FROM 투닝콘테스트_접수 s
   ORDER BY s.created_at DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.투닝콘테스트_관리자목록(text) FROM public;
GRANT EXECUTE ON FUNCTION public.투닝콘테스트_관리자목록(text) TO anon, authenticated;


-- =====================================================
-- 적용 후 확인
-- =====================================================
-- 틀린 비밀번호 → unauthorized (1초 지연 후)
--   SELECT * FROM public.투닝콘테스트_관리자목록('0000');
--
-- 맞는 비밀번호 → 접수 목록 (아직 접수 전이면 0건)
--   SELECT count(*) FROM public.투닝콘테스트_관리자목록('2509');
