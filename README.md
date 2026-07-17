# 工事部 資材在庫管理アプリ (koji-zaiko)

倉庫・置場の在庫を、モノが動くたびに記録する社内Webアプリ。監査対応（在庫精度向上）を目的とする。

- 本番URL: https://koji-zaiko.vercel.app
- 使い方: https://koji-zaiko.vercel.app/help

## 構成
- `index.html` … アプリ本体（単一ページ）。記録(出庫/入庫/返却/処分)・在庫一覧・型式マスタ・棚卸し・履歴/出力
- `help.html` … 使い方ページ
- `manifest.webmanifest` / `icon-512.png` … ホーム画面アイコン等
- `vercel.json` … Vercel設定
- バックエンド: Supabase（DB・認証・ストレージ）。HTML内の接続キーは公開可能な publishable key

## デプロイ
- GitHub連携済み。`main` への push で Vercel が自動デプロイ。
- 手動デプロイも可: このフォルダで `vercel --prod`

## メモ
- ログインは会社メール（@sunlife-corporation.jp）のマジックリンク。
- 記録は原則追記のみ。本人の当日分のみ訂正・取消可。1年超の記録は自動削除（月次PDFがアーカイブ）。
