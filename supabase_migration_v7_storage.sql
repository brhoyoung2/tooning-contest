-- =====================================================
-- [투닝콘테스트] v7 — Storage 정리 및 진단
--
-- ⚠️ 확인된 상황 (2026-09-03, anon 키로 실측)
--   · submissions 버킷을 충남 공모전과 함께 쓰고 있습니다.
--     webtoon 450개 / webtoon-ai 216개 / novel-ai 95개 파일 존재
--   · anon 키로 파일 "목록 조회"가 가능합니다 (storage.objects SELECT 정책 공개)
--   · 버킷이 public 이라 URL 을 알면 누구나 다운로드할 수 있습니다
--   · v6 에서 만든 'entries/ 경로만 업로드' 정책이 무력화되어 있습니다.
--     (버킷 루트에도 업로드가 성공 — 다른 허용 정책이 함께 존재)
--
--   → 1번(진단)만 SQL 로 실행하면 됩니다. 2번은 대시보드에서 파일을 지우세요.
--   → 3번(하드닝)은 충남 관리자 페이지·심사 스크립트가 목록 API를 쓰는지
--      확인한 뒤 실행하세요. 잘못 적용하면 충남 쪽이 멈출 수 있습니다.
-- =====================================================


-- =====================================================
-- 1. 진단 — 읽기 전용, 안전
--    ⚠️ Supabase SQL Editor 는 "마지막 쿼리" 결과만 보여줍니다.
--       그래서 정책 목록을 맨 아래에 두었습니다.
-- =====================================================

-- 버킷 설정 (참고)
SELECT id, public, file_size_limit, allowed_mime_types
  FROM storage.buckets WHERE id = 'submissions';

-- ★ 이 결과를 알려주세요 — storage.objects 에 걸린 정책 전체
SELECT policyname,
       cmd,
       roles::text            AS roles,
       coalesce(qual, '')       AS using_expr,
       coalesce(with_check, '') AS check_expr
  FROM pg_policies
 WHERE schemaname = 'storage' AND tablename = 'objects'
 ORDER BY cmd, policyname;


-- =====================================================
-- 2. 점검용 테스트 파일 삭제
--    v6 적용 확인 과정에서 업로드된 파일 2개입니다.
--
--    ⚠️ SQL 로는 지울 수 없습니다.
--       Supabase 가 storage.protect_delete() 트리거로 직접 삭제를 막습니다
--       (ERROR 42501: Direct deletion from storage tables is not allowed)
--
--    방법 A) 대시보드 (가장 간단)
--       Storage → submissions 버킷 →
--         · root.pdf                          (버킷 최상위)
--         · entries/_healthcheck-delete-me.pdf
--       두 파일 선택 후 Delete
--
--    방법 B) service_role 키로 Storage API 호출
--       curl -X DELETE -H "Authorization: Bearer <SERVICE_ROLE_KEY>" \
--         "https://mllbsqnrvhvnqvxkpxof.supabase.co/storage/v1/object/submissions/root.pdf"
--       curl -X DELETE -H "Authorization: Bearer <SERVICE_ROLE_KEY>" \
--         "https://mllbsqnrvhvnqvxkpxof.supabase.co/storage/v1/object/submissions/entries/_healthcheck-delete-me.pdf"
--
--       (service_role 키는 절대 프런트엔드·git 에 넣지 마세요)
-- =====================================================


-- =====================================================
-- 3. 하드닝 → supabase_migration_v8_storage_hardening.sql 로 이동
--    진단 결과로 정책 이름이 확정되어, 지울 대상을 정확히 지정한
--    v8 파일을 새로 만들었습니다. 그쪽을 사용하세요.
-- =====================================================
