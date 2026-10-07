# 資材在庫管理システム 再構築仕様書（koji-zaiko）

> この資料は「工事部 資材在庫管理アプリ（koji-zaiko）」で構築した内容を、**別の担当者が一から再構築できる**ように書き出したものです。
> サンライフの本番環境・アカウント・鍵には依存しません。この仕様に沿って、受け手が自分たちの Supabase / Vercel / GitHub アカウント上に同じシステムを作り直せます。
>
> **置き換えが必要な箇所は「★要変更」で明示**しています（会社メールドメイン・接続キー等）。巻末の「付録A」に、そのまま実行できるデータベース構築SQLを同梱しています。

---

## 0. この資料の使い方

1. 「1〜8章」で**何を作るか（仕様）**を理解する。
2. 「9章」で**自社向けに書き換える値**を押さえる。
3. 「10章」の**再構築手順**に沿って、ゼロから環境を立ち上げる。
4. 付録Aの**SQLを実行**すればデータベースは完成。付録BのHTMLの設定値を書き換えてデプロイすればアプリが動く。

本番の実データ（資材・工番・入出庫履歴）は、この仕様書には含めていません。必要であれば別途SQLダンプとして受け渡し可能です（11章参照）。

---

## 1. システム概要と目的

- **何のシステムか**：太陽光パネル等の工事資材を扱う会社の、倉庫・置場の**在庫管理Webアプリ**。
- **目的**：「モノ（資材）が動くたびに必ず記録が残る」仕組みで在庫精度を上げ、**監査（在庫確認）に耐える体制**を作る。経理上の数量と現場の実数の差異をなくすのが発端。
- **利用者**：社内の工事部メンバー（スマホ中心）＋ 管理者（PCで集計・棚卸し・原価確認）。
- **運用イメージ**：
  - 現場担当者がスマホで**出庫/入庫/返却/処分**を記録。
  - 在庫数は記録から**自動計算**（手で在庫数を書き換えない）。
  - 管理者が**棚卸し**で実数と突き合わせ、**履歴/原価**を集計。

---

## 2. 全体アーキテクチャ

```
[ユーザーのスマホ/PC ブラウザ]
        │  （静的HTML + バニラJS。ビルド不要）
        ▼
[Vercel（静的ホスティング）]  index.html / help.html を配信
        │  supabase-js (CDN) 経由で直接アクセス
        ▼
[Supabase]
   ├─ Auth：会社メールのマジックリンク（signInWithOtp）
   ├─ PostgreSQL：items / job_codes / item_serials / transactions / app_admins
   │     └─ RLS（行レベルセキュリティ）＋ SECURITY DEFINER な RPC で集計
   └─ Storage：非公開バケット certificates（処分証明書の写真など）
```

- **サーバーサイドのコードは無い**。フロント（HTML）から Supabase に直接つなぐ構成。
- HTMLに書く接続キーは**公開可能な publishable key**（匿名キー）。秘密鍵（service_role）はHTMLに置かない。
- セキュリティは**すべて Supabase 側の RLS とRPC**で担保する（「会社ドメインのログインユーザーだけが読み書きできる」など）。

---

## 3. 技術スタックと外部依存

| 要素 | 採用 | 備考 |
|---|---|---|
| フロント | 単一ページ `index.html`（バニラJS、フレームワーク無し） | ビルド不要。`help.html` は使い方ページ |
| UIライブラリ | なし（手書きCSS） | インダストリアルな配色 |
| アイコン | Tabler Icons（Webフォント, CDN） | `@tabler/icons-webfont@3.30.0` |
| DBクライアント | supabase-js v2（CDN） | `@supabase/supabase-js@2` |
| バックエンド | Supabase（無料プランで可） | PostgreSQL + Auth + Storage |
| ホスティング | Vercel（無料プランで可） | GitHub連携で push 自動デプロイ |
| ソース管理 | GitHub | `index.html` 等を直接編集 |
| PWA | `manifest.webmanifest` + `icon-512.png` | ホーム画面追加用。※後述の理由で standalone は無効 |

**CDN依存（HTMLの`<head>`）**
```html
<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
<link href="https://cdn.jsdelivr.net/npm/@tabler/icons-webfont@3.30.0/dist/tabler-icons.min.css" rel="stylesheet">
```

**デザイン指針（再現用）**
- 濃紺チャコール背景 × 安全色アンバー `#EF9F27` のアクセント。
- 完全レスポンシブ：**スマホ＝画面下タブ / PC＝左サイドバー**。
- OSのダークモードに追従。入力欄・ボタンは高さ46pxで統一。

---

## 4. 画面・機能仕様

ナビゲーションは全**7画面**。うち3つ（棚卸し・原価・履歴/出力）は**管理者専用**。

| 画面ID | 名称 | 権限 | 役割 |
|---|---|---|---|
| `record` | 記録する（出入庫を記録する） | 全社員 | 出庫/入庫/返却/処分を登録。本人の当日分を一覧・訂正 |
| `stock` | 在庫一覧 | 全社員 | 現在庫を自動計算して表示・CSV/PDF出力 |
| `master` | 資材マスタ（型式マスタ管理） | 全社員 | 資材（型式）の登録・編集。カテゴリ・単価・シリアル管理 |
| `jobmaster` | 工番マスタ（工事コード） | 全社員 | 工事コード（工番）の登録・編集 |
| `stocktake` | 実地棚卸し（差異チェック） | 管理者 | 実数入力→差異→確定で在庫を調整 |
| `cost` | 原価（工番・現場別） | 管理者 | 工番ごとの資材原価を集計・ランキング |
| `admin` | 履歴・出力 | 管理者 | 全履歴の閲覧・出力、管理者の追加/削除 |

### 4-1. 記録する（record）
- **区分**：`出庫` / `入庫` / `返却` / `処分` の4ボタン。
- 入力：資材（型式）、数量、工番（任意）、相手先、担当者、備考、（処分時）証明書写真。
- **入庫のみ品名の自由入力が可能**：マスタに無い品名を入れたら**自動で新規資材を登録**してから入庫。
- **処分**は証明書（写真）を Storage に添付できる。
- シリアル管理品は、対象シリアルを選んで記録できる。
- 画面下に「**今日の自分の記録**」を表示。本人が登録した**当日分のみ**訂正・取消が可能（翌日以降は不可）。

### 4-2. 在庫一覧（stock）
- `list_stock()` RPC で現在庫を取得して表示。
- **発注点以下・在庫0は赤**で強調。
- **カテゴリ**（パネル/ケーブル等）でグルーピング表示でき、**カテゴリ別のPDF**（特定カテゴリのみ、または全体）を出力できる。
- 一覧に**単価・在庫金額**の列を表示。
- この画面から各資材を**インライン編集**（型式・単位・カテゴリ・単価・発注点・置場）できる。
- CSV / PDF 出力。PDFは1ユニット1行の在庫表も出力可能。

### 4-3. 資材マスタ（master）
- 資材（型式）の一覧・登録・編集。**トグルを開いてインライン編集**する方式。
- 項目：型式名、単位、カテゴリ、単価、発注点、置場、備考（**改行可の複数行**）、有効フラグ。
- 編集を保存しても**画面がスクロール先頭に戻らず、保存した位置に留まる**。
- 各資材配下に**シリアル番号**（`item_serials`）を登録・表示。シリアルに注記（割れ・別ロット等）を付けられる。

### 4-4. 工番マスタ（jobmaster）
- 工事コード（工番）の一覧・登録・編集。**全社員が編集可能**（管理者限定ではない）。
- 項目：コード（一意）、部門、種別、契約日、発注者、工事名、場所、出所（取り込み元ラベル）、有効フラグ。
- 記録時の工番入力の選択候補になる。

### 4-5. 実地棚卸し（stocktake）【管理者】
- 各資材の**実数**を入力 → システム在庫との**差異**を表示 → 確定すると、差分を `棚卸調整` のトランザクションとして登録し在庫を実数に合わせる。
- `棚卸調整` だけは数量が**符号付き（＋/−）**を許容。

### 4-6. 原価（cost）【管理者】
- `list_job_costs()` で**工番ごとの資材原価**を集計し、**金額の多い順にランキング**（バー表示）。
- 工番を開くと `job_cost_detail(工番)` で**資材明細**（出庫/返却/正味数量・単価・金額）を表示。
- **原価の単価は「出庫した時点の単価」を採用**（6-2参照）。CSV / PDF 出力可。

### 4-7. 履歴・出力（admin）【管理者】
- `list_transactions(from, to)` で**全履歴**を期間・区分で絞り込み表示。
- `処分` を「廃棄一覧」として抽出。CSV / PDF 出力。証明書写真の閲覧。
- **管理者（app_admins）の追加・削除**。自分自身も操作可能だが、**最後の1人は削除不可**（ロックアウト防止）。

---

## 5. データベース設計

PostgreSQL（Supabase の `public` スキーマ）。全テーブルで**RLS有効**。

### 5-1. items（資材マスタ）
| カラム | 型 | 既定/制約 | 意味 |
|---|---|---|---|
| id | uuid | PK, `gen_random_uuid()` | |
| name | text | NOT NULL | 型式名 |
| unit | text | | 単位（枚/本など） |
| initial_stock | numeric | NOT NULL, 既定0 | 初期在庫 |
| reorder_point | numeric | | 発注点 |
| location | text | | 置場 |
| note | text | | 備考（複数行可） |
| is_active | boolean | NOT NULL, 既定true | 有効フラグ |
| created_at | timestamptz | 既定 now() | |
| carryover | numeric | NOT NULL, 既定0 | 1年超パージ時の繰越在庫（6-4） |
| category | text | | カテゴリ（パネル/ケーブル等） |
| unit_price | numeric | | 単価 |

### 5-2. job_codes（工番マスタ）
| カラム | 型 | 既定/制約 | 意味 |
|---|---|---|---|
| id | uuid | PK | |
| code | text | NOT NULL, **UNIQUE** | 工事コード（工番） |
| department | text | | 部門 |
| kind | text | | 種別 |
| contract_date | date | | 契約日 |
| orderer | text | | 発注者 |
| work_name | text | | 工事名 |
| place | text | | 場所 |
| source | text | | 取り込み元ラベル |
| is_active | boolean | NOT NULL, 既定true | |
| created_at | timestamptz | 既定 now() | |

### 5-3. item_serials（シリアル番号）
| カラム | 型 | 既定/制約 | 意味 |
|---|---|---|---|
| id | uuid | PK | |
| item_id | uuid | NOT NULL, FK→items(id) **ON DELETE CASCADE** | |
| serial | text | NOT NULL, **UNIQUE** | シリアル番号 |
| note | text | | 注記（割れ・別ロット等） |
| created_at | timestamptz | 既定 now() | |

### 5-4. transactions（入出庫履歴）
| カラム | 型 | 既定/制約 | 意味 |
|---|---|---|---|
| id | uuid | PK | |
| item_id | uuid | NOT NULL, FK→items(id) | |
| tx_date | date | NOT NULL, 既定 current_date | 計上日 |
| tx_type | text | NOT NULL, CHECK（下記） | 区分 |
| quantity | numeric | NOT NULL, CHECK（下記） | 数量 |
| job_no | text | | 工番 |
| counterparty | text | | 相手先 |
| person | text | NOT NULL | 担当者 |
| note | text | | 備考 |
| created_by | uuid | 既定 `auth.uid()` | 記録者（authユーザー） |
| created_at | timestamptz | 既定 now() | 記録時刻 |
| attachment_path | text | | 証明書のStorageパス |
| serials | text | | 対象シリアル（記録時のスナップショット） |
| is_test | boolean | NOT NULL, 既定 false | テストデータ印 |
| unit_price | numeric | | **記録時点の単価**（原価計算に使用） |

- **tx_type CHECK**：`出庫 / 入庫 / 返却 / 処分 / 棚卸調整` のいずれか。
- **quantity CHECK**：`出庫/入庫/返却/処分` は `> 0`、`棚卸調整` は `<> 0`（符号付き可）。

### 5-5. app_admins（管理者メール）
| カラム | 型 | 既定/制約 |
|---|---|---|
| email | text | **PK** |
| added_by | text | |
| added_at | timestamptz | NOT NULL, 既定 now() |

- `BEFORE DELETE` トリガー `trg_prevent_last_admin` で**最後の1人は削除不可**。

---

## 6. ビジネスロジック（必ず仕様通りに）

### 6-1. 現在庫の計算（list_stock）
```
現在庫 = initial_stock + carryover
        + Σ(入庫 + 返却)
        − Σ(出庫 + 処分)
        + Σ(棚卸調整)      ← 棚卸調整のみ符号付き
```
在庫数はこの式で**常に計算**する。在庫数を直接保存・上書きしない。

### 6-2. 原価の計算（list_job_costs / job_cost_detail）
- 工番原価 ＝ Σ(`出庫`数量 × その記録の `unit_price`) − Σ(`返却`数量 × `unit_price`)。
- **単価は資材マスタの最新単価ではなく、「出庫トランザクションに記録された unit_price」を使う**（出庫時点の単価で原価を固定するため）。
- よって記録登録時に、その時のマスタ単価を `transactions.unit_price` にコピーして保存すること。

### 6-3. 棚卸調整
- 実数入力で確定したとき、`実数 − システム在庫` を `棚卸調整` として1件登録（＋にも−にもなり得る）。

### 6-4. 1年超の自動パージ（purge_old_transactions）
- 1年を超えた古いトランザクションは、`items.carryover` に正味増減を織り込んでから**削除**する（在庫数は維持したまま履歴だけ圧縮）。
- Supabase の **pg_cron** で毎日実行（例：03:00 JST）。月次PDFを先にアーカイブする運用。

### 6-5. タイムゾーン
- 「本人の当日分のみ訂正可」の**当日判定は Asia/Tokyo（JST）**で行う（RLSの `tx_update_own` / `tx_delete_own` 参照）。

---

## 7. 認証・権限モデル

- **ログイン＝会社メールのマジックリンク**（`supabase.auth.signInWithOtp`）。パスワードなし。
- **会社ドメインのメールだけ**許可。判定は2段構え：
  - フロント：入力メールが会社ドメインで終わるかチェック（`COMPANY_DOMAIN`）。
  - DB：RLSが `is_company_user()`（JWTのメールが会社ドメインか）で全アクセスを制限。★ここが本当の防御。
- **管理者**＝`app_admins` にメールが登録されている会社ユーザー（`is_admin()`）。棚卸し・原価・履歴/出力・管理者管理が解放される。
- **初代管理者**は、環境構築時にSQLで1件だけ直接 `app_admins` に入れて起点を作る（付録 03）。

### PWA/standalone に関する既知の制約（重要）
- iOSでホーム画面に追加して**フルスクリーン(standalone)**にすると、メール内リンクが別コンテキスト（Safari）で開き**ログインが成立しない**。
- そのため現状は **standalone を無効化**し「ブラウザで開く」方式にしている（`manifest` の `display` を `browser`）。
- もしフルスクリーン化したい場合は、マジックリンクではなく**6桁コード方式（`verifyOtp`）**に切り替える必要がある。

---

## 8. RLS / RPC / トリガー / Storage 一覧

**RPC（SECURITY DEFINER）**
| 関数 | 権限チェック | 用途 |
|---|---|---|
| `is_company_user()` | — | JWTメールが会社ドメインか |
| `is_admin()` | — | 会社ユーザー かつ app_admins 登録者か |
| `list_stock()` | 会社ユーザー | 在庫一覧（集計） |
| `list_job_nos()` | （集計のみ） | 最近使った工番候補 |
| `list_job_costs()` | 会社ユーザー | 工番別原価の集計 |
| `job_cost_detail(工番)` | 会社ユーザー | 工番の資材明細 |
| `list_transactions(from,to)` | **管理者のみ** | 全履歴（authユーザーのメール結合） |
| `purge_old_transactions()` | （cron実行） | 1年超を carryover 化して削除 |
| `prevent_last_admin_delete()` | — | 最後の管理者削除を拒否（トリガー関数） |

**RLSポリシー要点**
- `items`：会社ユーザーは SELECT / INSERT / UPDATE 可。
- `job_codes`：会社ユーザーは SELECT と全書込可（**全員が編集できる**仕様）。
- `item_serials`：会社ユーザーは SELECT、**管理者は全操作**。
- `transactions`：SELECT＝**管理者は全件**／本人は自分の分のみ。INSERT＝会社ユーザー。UPDATE・DELETE＝**本人の当日(JST)分のみ**。
- `app_admins`：**管理者のみ** SELECT / INSERT / DELETE。
- `storage.objects`（バケット `certificates`）：会社ユーザー（authenticated）のみ SELECT / INSERT。

**Storage**
- 非公開バケット **`certificates`**（処分証明書の写真等）。

> これらの正確な定義（CREATE文）は**付録A**にそのまま実行できる形で収録。

---

## 9. 自社向けに書き換える値（★要変更）

再構築時に**必ず自社の値へ置換**する箇所：

| 箇所 | 元の値（サンライフ） | 変更内容 |
|---|---|---|
| DB関数 `is_company_user()` 内のドメイン | `%@sunlife-corporation.jp` | **自社のメールドメイン**に変更（付録A 冒頭の注意） |
| `index.html` の `COMPANY_DOMAIN` | `@sunlife-corporation.jp` | 上と**同じ値**に合わせる |
| `index.html` の `SUPABASE_URL` | `https://bdomgylhbuvxokppitao.supabase.co` | 自社の新Supabaseプロジェクトの **Project URL** |
| `index.html` の `SUPABASE_KEY` | `sb_publishable_...`（旧） | 自社プロジェクトの **publishable（anon）key** |
| 初代管理者メール | `yuki.suzuki@sunlife-corporation.jp` | 自社の**最初の管理者のメール**（付録 03） |
| ログイン入力欄の placeholder 等 | `name@sunlife-corporation.jp` | 任意。自社ドメインの例に |
| Supabase Auth の Site URL / Redirect | 旧本番URL | 新しい本番URL（Vercel） |

> **サンライフの既存のURL・接続キー・管理者メールは流用しないでください。** 受け手は必ず自分たちのアカウントで新規に発行した値を使います。

---

## 10. 再構築手順（ゼロから）

### STEP 1. Supabase プロジェクト作成
1. 受け手の Supabase アカウントで**新規プロジェクト**を作成（リージョンは東京など任意、無料プランで可）。
2. 作成後、**Project URL** と **publishable（anon）key** を控える（Settings → API）。

### STEP 2. データベース構築（付録A）
1. Supabase の **SQL Editor** を開く。
2. **付録A 冒頭の `is_company_user()` のドメインを自社ドメインに書き換えてから**、付録Aの `01_schema.sql` を丸ごと実行。
   - テーブル／RPC／RLSポリシー／トリガー／Storageバケット `certificates` が一括で作成される。
3. （任意）初期の資材・工番データが必要なら、別途受け渡すデータSQLを実行（11章）。

### STEP 3. 認証（メール）設定
1. Authentication → **Email（マジックリンク）を有効**化。
2. Authentication → URL Configuration に、**新しい本番URL**（STEP 5で決まるVercelのURL）を Site URL / Redirect URLs として登録。
3. 無料枠のメール送信数には上限があるため、人数が多い場合は**独自SMTP（Resend等）**の設定を推奨。
4. 初代管理者を登録（付録 03 のSQL、`app_admins` に1件）。

### STEP 4. アプリのソース準備
1. 受け手の GitHub に**新規リポジトリ**を作成。
2. `index.html` / `help.html` / `manifest.webmanifest` / `icon-512.png` / `vercel.json` を配置（付録B参照。アイコンは差し替え可）。
3. `index.html` 冒頭の設定値を**自社の値に書き換え**（9章）。

### STEP 5. デプロイ（Vercel）
1. 受け手の Vercel アカウントで、STEP 4 の GitHub リポジトリを **Import**。
2. ビルド設定不要（静的サイト）。デプロイすると本番URLが決まる。
3. その本番URLを **STEP 3-2 の Supabase URL設定に反映**（マジックリンクの戻り先）。
4. 以後は GitHub に push すれば自動で再デプロイ。

### STEP 6. 動作確認
1. 本番URLを開き、自社ドメインのメールでマジックリンク・ログイン。
2. 資材を1件登録 → 入庫 → 在庫一覧に反映されるか。
3. 管理者メールで棚卸し・原価・履歴/出力が見えるか。
4. 非会社ドメインのメールでは弾かれることを確認（RLSの検証）。

---

## 11. 注意点・ハマりどころ（再発防止メモ）

- **在庫数は必ず計算で出す**。どこかに在庫数を保存して直接いじらない。
- **原価は出庫時点の単価**（`transactions.unit_price`）。マスタ単価を後で変えても過去原価は動かない設計。これを守るため、記録登録時にマスタ単価を transactions にコピーすること。
- **RLSが本体の防御**。フロントのドメインチェックは入口の親切機能にすぎない。`is_company_user()` のドメイン変更を忘れると、新会社のユーザーが**全く読み書きできない**（または旧ドメインだけ通る）ので最優先で直す。
- **publishable(anon) key はHTMLに書いてよい**が、**service_role 等の秘密鍵は絶対にHTMLへ書かない**。
- **マジックリンクと standalone の相性問題**（7章）。iOSフルスクリーン化は verifyOtp へ変更が前提。
- **最後の管理者は削除不可**（トリガー）。管理者が1人の状態で消そうとするとエラーになる仕様（正常）。
- `job_codes` は**全社員が編集可能**（意図的な仕様）。限定したい場合は `jc_write_all` ポリシーを `is_admin()` に変更。
- **本番データ（資材・工番・入出庫）の受け渡し**：必要なら、現行DBから `items / job_codes / item_serials / transactions` の INSMENT を書き出したSQLを別ファイルで提供できる（`transactions.created_by` は新環境のauthユーザーを指さないため NULL にして渡す）。データ無しで「空の状態から運用開始」も可能。

---

## 付録A：データベース構築SQL（`01_schema.sql`）

> 新しい Supabase プロジェクトの SQL Editor で、**冒頭の `is_company_user()` のドメインを自社のものに変更してから**、丸ごと実行してください。

同梱ファイル **`handover/01_schema.sql`** を参照（この仕様書と同じフォルダに置いています）。内容は本書 5〜8章の定義そのままです。

## 付録B：アプリのソース

- `index.html`（本体）／`help.html`（使い方）／`manifest.webmanifest`／`icon-512.png`／`vercel.json`
- 設定値（`SUPABASE_URL` / `SUPABASE_KEY` / `COMPANY_DOMAIN`）は `index.html` 冒頭にまとまっています。9章の通り置換してください。

## 付録 03：初代管理者の登録SQL（`03_admin_bootstrap.sql`）

```sql
-- ★ 自社の最初の管理者メールに書き換えて実行
insert into public.app_admins (email, added_by)
values ('admin@YOURCOMPANY.co.jp', 'system:init')
on conflict (email) do nothing;
```
