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
-- 1. 진단 — 현재 storage 정책 확인 (읽기 전용, 안전)
-- =====================================================
SELECT policyname, cmd, roles, qual, with_check
  FROM pg_policies
 WHERE schemaname = 'storage' AND tablename = 'objects'
 ORDER BY cmd, policyname;

-- 버킷 설정
SELECT id, public, file_size_limit, allowed_mime_types
  FROM storage.buckets WHERE id = 'submissions';


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
-- 3. 하드닝 (충남 의존성 확인 후 실행)
--    ① 업로드는 entries/ 경로로만
--    ② 목록 조회 차단 — 공개 URL 직접 접근은 그대로 동작합니다
--       (public 버킷의 /object/public/... 경로는 정책과 무관)
-- =====================================================
-- 아래 블록의 주석을 해제하고 실행하세요.
--
-- -- submissions 버킷을 대상으로 하는 기존 정책을 모두 제거
-- DO $$
-- DECLARE r record;
-- BEGIN
--   FOR r IN
--     SELECT policyname FROM pg_policies
--      WHERE schemaname = 'storage' AND tablename = 'objects'
--        AND (coalesce(qual, '') LIKE '%submissions%'
--          OR coalesce(with_check, '') LIKE '%submissions%')
--   LOOP
--     EXECUTE format('DROP POLICY %I ON storage.objects', r.policyname);
--   END LOOP;
-- END $$;
--
-- -- 업로드: entries/ 경로에만, 새 파일 생성만
-- CREATE POLICY "투닝콘테스트_제출물_업로드" ON storage.objects
--   FOR INSERT TO anon, authenticated
--   WITH CHECK (bucket_id = 'submissions' AND name LIKE 'entries/%');
--
-- -- 충남 경로 업로드가 아직 필요하면 아래도 함께 생성하세요
-- -- CREATE POLICY "충남_제출물_업로드" ON storage.objects
-- --   FOR INSERT TO anon, authenticated
-- --   WITH CHECK (bucket_id = 'submissions'
-- --               AND (name LIKE 'webtoon/%' OR name LIKE 'webtoon-ai/%' OR name LIKE 'novel-ai/%'));
--
-- -- SELECT 정책은 만들지 않습니다 → 목록 열거 차단
-- --   · 공개 URL(/storage/v1/object/public/submissions/...) 은 계속 열립니다
-- --   · 심사·관리자 도구는 service_role 키로 접근하세요
--
-- -- UPDATE/DELETE 정책도 만들지 않습니다 (덮어쓰기·삭제 차단 — 이미 정상 동작 중)


-- =====================================================
-- 4. 적용 후 확인
-- =====================================================
-- 목록이 차단되었는지 (anon 키로):
--   curl -X POST '<URL>/storage/v1/object/list/submissions' \
--        -H 'apikey: <ANON>' -H 'Authorization: Bearer <ANON>' \
--        -H 'Content-Type: application/json' -d '{"prefix":"","limit":10}'
--   → 빈 배열 [] 이면 차단 성공
--
-- 업로드가 여전히 되는지 (entries/ 경로):
--   curl -X POST '<URL>/storage/v1/object/submissions/entries/test.pdf' \
--        -H 'apikey: <ANON>' -H 'Authorization: Bearer <ANON>' \
--        -H 'Content-Type: application/pdf' --data-binary @test.pdf
--   → 200 이면 정상
