-- =====================================================
-- [투닝콘테스트] v16 — 접수 조회에 '최신' 정보 포함
--
--   v15 부터 재접수할 때마다 새 접수번호가 발급됩니다.
--   그래서 참가자가 예전 접수번호로 조회하면 옛 내용이 나옵니다.
--
--   이 조회 RPC 는 접수번호로 참가자를 찾은 뒤,
--   그 참가자의 접수 전체를 최신순으로 돌려줍니다.
--   · is_latest : 마지막 접수(= 심사 대상) 여부
--   · queried   : 참가자가 입력한 그 접수번호인지
--   · seq/total : 몇 번째 접수인지 / 전체 몇 건인지
--
--   참가자 식별은 관리자 목록과 동일하게 '연락 이메일 + 이름' 입니다.
--   (개인정보 보호를 위해 이메일·연락처는 반환하지 않습니다)
--
-- 전제: v15 실행 완료
-- 성격: 비파괴 · 여러 번 실행해도 안전
-- 실행: Supabase 대시보드 → SQL Editor → 전체 붙여넣기 → Run
-- =====================================================

DROP FUNCTION IF EXISTS public.투닝콘테스트_조회(text);

CREATE FUNCTION public.투닝콘테스트_조회(p_key text)
RETURNS TABLE (
  submit_key text,
  name       text,
  school     text,
  grade      text,
  section    text,
  topic      text,
  status     text,
  created_at timestamptz,
  is_latest  boolean,
  queried    boolean,
  seq        int,
  total_seq  int
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  WITH target AS (
    SELECT lower(coalesce(contact_email, id::text)) AS ident,
           lower(btrim(coalesce(name, '')))          AS nm
      FROM 투닝콘테스트_접수
     WHERE submit_key = upper(btrim(p_key))
     LIMIT 1
  ),
  mine AS (
    SELECT s.*,
           row_number() OVER (ORDER BY s.created_at) AS rn,
           count(*)     OVER ()                      AS cnt
      FROM 투닝콘테스트_접수 s, target t
     WHERE lower(coalesce(s.contact_email, s.id::text)) = t.ident
       AND lower(btrim(coalesce(s.name, ''))) = t.nm
  )
  SELECT m.submit_key, m.name, m.school, m.grade, m.section, m.topic, m.status, m.created_at,
         (m.rn = m.cnt)                                AS is_latest,
         (m.submit_key = upper(btrim(p_key)))          AS queried,
         m.rn::int                                     AS seq,
         m.cnt::int                                    AS total_seq
    FROM mine m
   ORDER BY m.created_at DESC
   LIMIT 20;
$$;

REVOKE ALL ON FUNCTION public.투닝콘테스트_조회(text) FROM public;
GRANT EXECUTE ON FUNCTION public.투닝콘테스트_조회(text) TO anon, authenticated;


-- =====================================================
-- 적용 후 확인
-- =====================================================
-- 존재하지 않는 번호 → 0건
--   SELECT * FROM public.투닝콘테스트_조회('TC-0000-0000');
--
-- 실제 번호 → 그 참가자의 접수 전체가 최신순으로 나오고
--             is_latest / queried 로 구분됩니다
--   SELECT submit_key, topic, seq, total_seq, is_latest, queried
--     FROM public.투닝콘테스트_조회('TC-XXXX-XXXX');
