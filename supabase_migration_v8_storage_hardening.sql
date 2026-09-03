-- =====================================================
-- [투닝콘테스트] v8 — Storage 하드닝 (정책 이름 확정판)
--
-- 진단 결과(2026-09-03) submissions 버킷에 걸린 정책은 4개였습니다.
--
--   INSERT  submissions_anon_insert      {anon}  bucket_id='submissions'        ← 경로 제한 없음
--   INSERT  투닝콘테스트_제출물_업로드    {anon}  bucket_id='submissions'
--                                                AND name LIKE 'entries/%'
--   SELECT  submissions_public_read      {anon}  bucket_id='submissions'        ← 목록 열거 허용
--   SELECT  투닝콘테스트_제출물_공개읽기  {anon}  bucket_id='submissions'        ← 목록 열거 허용
--
-- 정책은 OR 로 합쳐지므로, 경로 제한 없는 submissions_anon_insert 때문에
-- 'entries/ 만 허용' 규칙이 무력화되어 버킷 루트에도 업로드가 됩니다.
-- SELECT 정책 두 개 때문에 anon 키로 파일 목록 전체가 조회됩니다
-- (충남 제출물 webtoon 450 / webtoon-ai 216 / novel-ai 95개 포함).
--
-- ⚠️ 실행 전 확인
--   · 충남 공모전이 아직 "접수 중"이면 2번 블록을 함께 실행하세요.
--     이미 마감됐다면 2번은 건너뛰어 업로드를 완전히 닫는 편이 안전합니다.
--   · 충남 관리자 페이지가 Storage "목록 API"를 쓰고 있다면 3번 실행 후
--     그 화면이 비어 보일 수 있습니다. 그 경우 맨 아래 롤백으로 되돌리세요.
--     (파일 다운로드는 public 버킷이라 정책과 무관하게 계속 됩니다)
-- =====================================================


-- =====================================================
-- 1. 경로 제한 없는 업로드 정책 제거
--    → 이후 업로드는 'entries/%' 로만 가능 (투닝콘테스트_제출물_업로드)
-- =====================================================
DROP POLICY IF EXISTS "submissions_anon_insert" ON storage.objects;


-- =====================================================
-- 2. (선택) 충남 경로 업로드를 계속 허용해야 할 때만 실행
--    충남 공모전이 마감됐다면 실행하지 마세요.
-- =====================================================
-- CREATE POLICY "충남_제출물_업로드" ON storage.objects
--   FOR INSERT TO anon, authenticated
--   WITH CHECK (
--     bucket_id = 'submissions'
--     AND (name LIKE 'webtoon/%' OR name LIKE 'webtoon-ai/%' OR name LIKE 'novel-ai/%')
--   );


-- =====================================================
-- 3. 목록 열거 차단
--    SELECT 정책을 없애면 /object/list 가 빈 배열을 반환합니다.
--    public 버킷이라 /object/public/... 직접 접근(다운로드)은 그대로 동작하므로
--    접수 폼의 getPublicUrl 저장 방식과 심사용 열람에는 영향이 없습니다.
-- =====================================================
DROP POLICY IF EXISTS "submissions_public_read"        ON storage.objects;
DROP POLICY IF EXISTS "투닝콘테스트_제출물_공개읽기"   ON storage.objects;


-- =====================================================
-- 4. 적용 결과 확인
-- =====================================================
SELECT policyname, cmd, roles::text AS roles,
       coalesce(qual, '') AS using_expr,
       coalesce(with_check, '') AS check_expr
  FROM pg_policies
 WHERE schemaname = 'storage' AND tablename = 'objects'
   AND (coalesce(qual, '') LIKE '%submissions%'
     OR coalesce(with_check, '') LIKE '%submissions%')
 ORDER BY cmd, policyname;

-- 기대 결과: INSERT 정책 1개(투닝콘테스트_제출물_업로드)만 남음
--            (2번을 실행했다면 충남_제출물_업로드 포함 2개)
--            SELECT 정책 0개


-- =====================================================
-- ✅ 적용 확인 완료 (2026-09-03, anon 키 실측)
--    1) /object/list submissions        → []        목록 열거 차단
--    2) /object/list prefix=webtoon     → []        충남 파일도 열거 불가
--    3) POST submissions/root2.pdf      → 403 RLS   루트 업로드 차단
--    4) POST submissions/webtoon/x.pdf  → 403 RLS   충남 경로 업로드 차단
--    5) POST submissions/entries/....pdf→ 409 중복  접수 경로는 정책 통과(정상)
--    6) GET  /object/public/submissions/entries/....pdf → 200  다운로드 유지
--
--    ※ 2번 블록(충남 업로드 허용)은 실행하지 않은 상태입니다.
--      충남이 다시 접수를 받아야 한다면 그때 실행하세요.
-- =====================================================


-- =====================================================
-- 롤백 (문제가 생겼을 때 원래대로)
-- =====================================================
-- CREATE POLICY "submissions_anon_insert" ON storage.objects
--   FOR INSERT TO anon WITH CHECK (bucket_id = 'submissions');
--
-- CREATE POLICY "submissions_public_read" ON storage.objects
--   FOR SELECT TO anon USING (bucket_id = 'submissions');


-- =====================================================
-- 참고 — 이번 조치와 무관하지만 알아두실 정책
-- =====================================================
-- tp_owner_update_delete : ALL / {authenticated} / owner = auth.uid()
--   버킷을 가리지 않는 정책입니다. 로그인 사용자가 자기가 올린 파일을
--   모든 버킷에서 수정·삭제할 수 있습니다. 저희 접수는 anon 업로드라
--   owner 가 비어 있어 해당되지 않지만, 다른 서비스와 공유되는 프로젝트라는
--   점은 염두에 두세요.
