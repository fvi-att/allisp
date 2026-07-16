---
name: allisp
description: allisp(思考Lisp処理系)で .lisp ファイルまたは単発の S 式を実行する。allisp ファイルの実行、one-liner、擬似実行、評価、dry-run、再思考(refresh)、結果の要約を頼まれたときに使用。引数例 /allisp <file> [--dry-run|--refresh|--strict|--model opus]
---

# allisp 実行スキル

allisp は「定義があるものは決定論的に評価し、未定義のものは LLM オラクルが擬似実行する」
Lisp 処理系。このスキルは、ユーザーの依頼内容を allisp の引数に翻訳して実行し、
結果を要約して報告するためのもの。

## 0. バイナリの解決

```sh
command -v allisp
```

PATH になければ、allisp リポジトリ内の `bin/allisp` を使う。
リポジトリ自体も見つからなければ `make install` が必要であることを伝える。

## 1. 引数への翻訳

このスキルの引数(`/allisp` の後ろ)にファイルパスやフラグが直接書かれていれば、
それをそのまま `allisp run` に渡す。自然言語の依頼は次の表で翻訳する:

| 依頼の内容 | コマンド |
|---|---|
| 「実行して」「評価して」「擬似実行して」 | `allisp run <file>` |
| 「どこが LLM 行きか」「コスト見積り」「予告」 | `allisp run <file> --dry-run` |
| 「考え直して」「再思考」「キャッシュ無視で」 | `allisp run <file> --refresh` |
| 「厳格に」「エラーで止めて」 | `allisp run <file> --strict` |
| 「opus で」「もっと深く考えさせて」 | `allisp run <file> --model opus` |
| 「この S 式を直接評価」 | `allisp --one-liner "<form>"` |
| 特定の式だけ再思考したい | ソースのその式を `(llm <式> :fresh t)` で包むことを提案 |

ファイルが曖昧な場合は、現在のワークスペース内の `.lisp` ファイルを探し、
`output/` と `.allisp/` 以下を除外した候補をユーザーに確認する。
フラグは併用可(例: `--refresh --model opus`)。

## 2. 実行手順

1. **必ず最初に `--dry-run`** を実行してオラクル行き箇所の数を把握する(LLM を呼ばず数秒で終わる)。
   - キャッシュ未整備のオラクル数が **10 を超える**場合、1 回あたり 10〜45 秒 ×件数の時間と
     サブスクリプション消費が発生する。件数と見積り時間をユーザーに伝えてから本実行する。
2. 本実行はバックグラウンドで走らせる(`run_in_background`)。進捗は
   `[allisp] oracle #N miss/hit ...` 行で追える。
3. `--refresh` は**全キャッシュを捨てて再生成**する重い操作。ユーザーが明示的に
   再思考を求めたときだけ使う。

## 3. 結果の読み方と報告

終了コード: `0` 成功 / `1` エラー値あり(部分評価は完了している) / `2` 引数誤り / `3` 内部エラー。

出力は入力ファイルの隣の `output/` に生成される:

- `<name>.result.lisp` — 各トップレベル式の `(result :n K :form <元の式> :value <評価値>)`
- `<name>.trace.lisp` — 全オラクル呼び出しの記録(hash / model / hit・miss / 値)

報告時は result.lisp を読み、次を要約する:

1. 統計行(フォーム数、オラクル miss/hit、エラー数)
2. **オラクルが返した `:value` の中身**(特に conclusion / finding / root-cause 系)。
   決定論的に定義を束縛しただけの結果(closure 等)は省いてよい
3. `(error :type ... :form ... :detail ...)` があれば全件列挙し、対処を提案
   (`:oracle-failure` → 再実行で失敗箇所のみ再問い合わせされる /
    `:unbound-in-pure` → pure 内の未定義 / `:use-not-found` → @use のパス誤り)

## 4. 知っておくべきセマンティクス(要約)

- 再実行はキャッシュにより決定論的リプレイ(全 hit なら 1 秒未満)。編集した式だけが再問い合わせになる
- キャッシュはプロジェクトルートの `.allisp/oracle/` に蓄積される
- `(@use "相対パス")` で他ファイルの定義を継承する
- `(generate-file "path.lisp" body...)` は最終評価値を別ファイルへ書き出し、
  `generated-by` マーカーで生成元を記録する。`--dry-run` 時は書き出さない
- `--one-liner` は最後の評価値を標準出力へ表示し、result / trace ファイルは生成しない
- 詳細仕様: リポジトリ内の `docs/language.md`、設計判断: `DESIGN.md`
