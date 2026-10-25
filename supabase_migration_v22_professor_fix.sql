-- =====================================================
-- [투닝콘테스트] v22 — 교수 심사 보완 (v21 이후 실서버 검증에서 발견)
--
--   1) 상장 이미지(PNG)가 버킷에서 거부되던 문제
--      submissions 버킷의 허용 파일 형식에 image/png 가 없어서
--      '완료하고 전달' 의 업로드 단계가 415(invalid_mime_type)로 실패했습니다.
--      기존에 허용된 형식은 그대로 두고 image/png 만 추가합니다.
--
--   2) 새 테이블의 직접 접근 권한 회수
--      RLS 덕분에 행은 보이지 않았지만(빈 배열) anon 에게 테이블 권한이
--      남아 있었습니다. 접수 테이블과 같은 방식으로 권한 자체를 회수합니다.
--      RPC 는 SECURITY DEFINER 라서 영향이 없습니다.
--
-- 전제: v21 실행 완료
-- 성격: 비파괴 · 여러 번 실행해도 안전
-- 실행: Supabase 대시보드 → SQL Editor → 전체 붙여넣기 → Run
-- =====================================================

-- 1) 버킷 허용 형식에 image/png 추가 (제한이 걸려 있는 경우에만)
UPDATE storage.buckets
   SET allowed_mime_types = (
         SELECT array_agg(DISTINCT m)
           FROM unnest(allowed_mime_types || ARRAY['image/png']) AS m)
 WHERE id = 'submissions'
   AND allowed_mime_types IS NOT NULL;

-- 2) 직접 접근 권한 회수
REVOKE ALL ON 투닝콘테스트_심사위원 FROM anon, authenticated;
REVOKE ALL ON 투닝콘테스트_배정     FROM anon, authenticated;
REVOKE ALL ON 투닝콘테스트_상장     FROM anon, authenticated;

-- =====================================================
-- 적용 후 확인
-- =====================================================
SELECT id, allowed_mime_types, file_size_limit
  FROM storage.buckets WHERE id = 'submissions';
-- → allowed_mime_types 에 image/png 가 보이면 정상
--
-- 이 SQL 을 실행한 뒤 터미널에서 상장 업로드 검증을 다시 돌립니다.
