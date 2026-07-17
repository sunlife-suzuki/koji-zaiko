# 引き継ぎ資料（工事部 在庫管理アプリ / koji-zaiko）

別の端末・ブラウザ（claude.ai/code 等）でこの続きを行うための資料。このリポジトリを開けば、以下の文脈で作業を再開できる。

## 概要・目的
- 工事部の倉庫/置場の在庫管理Webアプリ。監査法人の在庫確認で経理数と現場数の差異が発覚したのが発端。
- 目的＝「モノが動くたびに必ず記録が残る」仕組みで在庫精度を上げ、監査に耐える体制にする。
- 管理責任者は伊藤さん、棚卸し協力は内田さん(工事部)。

## 本番URL
- アプリ: https://koji-zaiko.vercel.app
- 使い方: https://koji-zaiko.vercel.app/help

## 技術構成
- フロント: 単一ページ `index.html`（バニラJS）＋ `help.html`。CDN依存＝supabase-js, Tabler icons。
- バックエンド: Supabase（プロジェクトID `bdomgylhbuvxokppitao` / org `dkvzrkbamtmfatvwkhgg`「サンライフコーポレーション」/ 東京 / 無料プラン）。
  - HTML内の接続キーは公開可能な publishable key（`sb_publishable_...`）。**サービスロール等の秘密鍵はコードに無い**。
- デザイン: インダストリアル（濃紺チャコール×安全色アンバー #EF9F27）。完全レスポンシブ（スマホ=下タブ、PC=左サイドバー）。ダークモード端末追従。入力欄/ボタンは高さ46pxで統一。

## デプロイ / git
- GitHub: https://github.com/sunlife-suzuki/koji-zaiko （main）。
- Vercel と git 連携済み → **main に push すると自動デプロイ**。手動は `vercel --prod` も可。
- 編集はこの `koji-zaiko` フォルダのファイルを直接行い、`git add/commit/push`。

## データモデル（Supabase / public スキーマ）
- `items`（在庫マスタ）: name, unit, initial_stock, reorder_point, location, note, is_active, carryover。
- `transactions`（出入庫）: item_id, tx_date, tx_type(出庫/入庫/返却/処分/棚卸調整), quantity, job_no, counterparty, person, note, attachment_path, created_by, created_at。
- 現在庫 = initial_stock + carryover + Σ(入庫+返却) − Σ(出庫+処分) + Σ(棚卸調整)。棚卸調整のみ数量は符号付き可。
- `app_admins`（管理者メール一覧）。
- RPC: `list_stock()`(会社ユーザー/在庫集計), `list_transactions(from,to)`(管理者/履歴), `is_admin()`, `is_company_user()`, `purge_old_transactions()`。
- RLS: 会社ドメイン `@sunlife-corporation.jp` のJWTのみ。transactions は SELECT=管理者+本人分、INSERT=会社ユーザー、UPDATE/DELETE=本人の当日(JST)分のみ。
- Storage: 非公開バケット `certificates`（処分証明書・写真。会社ユーザーのみ up/down）。
- pg_cron: `purge-old-transactions`（毎日03:00 JST、1年超を carryover に織り込んで削除）。
- app_admins は最後の1人を削除できないトリガーあり（ロックアウト防止）。

## 認証
- 会社メールのマジックリンク（signInWithOtp）。`@sunlife-corporation.jp` のみ。初代管理者=yuki.suzuki@sunlife-corporation.jp。
- Supabase Auth の URL 設定（Site URL / Redirect）に本番URL登録済み。
- ※iOSでホーム画面フルスクリーン(standalone)にすると、メールリンクがSafariで開き別コンテキストになりログイン不可 → 現在は standalone を無効化し「Safariで開く」方式。将来フルスクリーン化するなら6桁コード方式（verifyOtp）に変更が必要。

## 主な機能
- 記録（出庫/入庫/返却/処分）。入庫のみ品名自由入力（無い品名は自動で新規登録）。処分は証明書添付。
- 在庫一覧（自動計算、発注点以下/在庫0は赤表示、CSV/PDF出力）。
- 型式マスタ管理。
- 今日の自分の記録（本人の当日分の訂正・取消）。
- 棚卸し（管理者）: 実数入力→差異→確定で在庫調整。
- 履歴・出力（管理者）: 対象月・区分フィルタ（処分＝廃棄一覧）・CSV/PDF・証明書閲覧・管理者の追加/削除（自分含む、最後の1人は不可）。

## 残タスク / 未決
- 初期棚卸し後に実データ（型式・初期在庫）を登録（運用開始の起点）。
- サンプル型式3件（「(サンプル)」表記）とテスト用トランザクションの掃除。
- 人数拡大時に Microsoft(Azure) サインインへ移行検討（メール送信制限の解消）。
- 将来候補: バーコード/QR読み取り、場所別在庫、月次リマインド等。

## 別環境での続け方
1. この GitHub リポジトリを開く（claude.ai/code もしくは別PCのClaude Code）。
2. 変更 → `git push` で本番自動反映。
3. Supabase/Vercel の管理操作は各サービスに sunlife-suzuki アカウントでログインして実施。
