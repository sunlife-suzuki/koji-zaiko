-- =====================================================================
-- koji-zaiko 初代管理者の登録  [03_admin_bootstrap.sql]
-- 01_schema.sql を実行した後に、1回だけ実行してください。
-- ★ 自社の最初の管理者メールに書き換えること。
--   このメールのユーザーが「管理者」として、棚卸し・原価・履歴/出力・
--   管理者の追加/削除を使えるようになります。
-- =====================================================================
insert into public.app_admins (email, added_by)
values ('admin@YOURCOMPANY.co.jp', 'system:init')
on conflict (email) do nothing;
