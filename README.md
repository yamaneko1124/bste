# bsdodge

Brawl Stars (iOS) 用の自動弾除け dylib。外部依存なし。

## ビルド
- GitHub Actions: push すると `bsdodge-dylib` Artifact が出る
- ローカル (macOS): `./build.sh`

## 注入
```
./run.sh BrawlStars.ipa
```
`insert_dylib` と `ldid` が PATH に必要。

## 設定
`~/Documents/dodge.cfg` を置くとデフォルト値を上書きできる。

| キー | デフォルト | 説明 |
|---|---|---|
| radius | 1.6 | 弾との衝突半径 |
| horizon | 0.55 | 予測秒数 |
| strength | 0.9 | 移動強度 (0–1) |
| always | 0 | 1=脅威がなくても毎フレーム Apply |

## ログ
`~/Documents/dodge.log` にクラス名・オフセット・弾リスト取得結果が出る。
クラス名やフィールド名がアップデートで変わった場合は cfg で差し替える。
