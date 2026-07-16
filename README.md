# Allisp

定義済みのフォームは決定論的に評価する。
定義のないフォームは、LLM オラクルが擬似実行する Lisp 処理系である。

```lisp
(defun average (numbers)
  (/ (reduce (lambda (total number) (+ total number))
             numbers :initial-value 0)
     (length numbers)))

(def samples '(12 18 15))

(average samples)                                ; 定義済み → 15

(summarize-metrics :samples samples)             ; 未定義 → LLM が S 式を返す
```

`defmacro` と `defun` を増やすほど、評価できる範囲は決定論的になる。
未定義の思考は LLM が補う。
オラクルの結果は永続キャッシュするため、同じ入力を再実行すると決定論的にリプレイできる。

## 公開・利用について

このリポジトリには個人用の設定、IDE 設定、オラクルキャッシュ、実行結果を含めない。
これらは `.gitignore` の対象であり、生成物には入力内容やローカルパスが含まれる場合があるため、公開前に内容を確認すること。
ライセンスは [MIT License](LICENSE) である。

- 言語仕様（実行境界、`llm`、`pure`、`@use`、エラー値、キャッシュ）：[docs/language.md](docs/language.md)
- 開発ガイド（テスト、ソース構成、バックエンドの差し替え）：[docs/development.md](docs/development.md)
- 設計決定の経緯：[DESIGN.md](DESIGN.md)
- 決定論、LLM、マクロを混在させる実行例：[sample/README.md](sample/README.md)

## 実行方法

リポジトリ内のサンプルは、外部の allisp ソースに依存しない。
次の dry-run は LLM を呼び出さずに実行できる。

```sh
bin/allisp run sample/01-deterministic.lisp --dry-run
```

```sh
allisp run <file.lisp>               # 実行
allisp run <file.lisp> --dry-run     # LLM を呼ばず、オラクルに渡る箇所を表示
allisp run <file.lisp> --refresh     # キャッシュを無視して全オラクルを再実行
allisp run <file.lisp> --strict      # 最初のエラーで停止（既定ではエラー値化して継続）
allisp run <file.lisp> --model opus  # 既定のモデルを変更（sonnet | opus | haiku）
allisp --one-liner "(+ 1 2)"         # 文字列内の S 式を評価し、最後の値を表示
```

`--one-liner` には複数のフォームを渡せる。
各フォームを順に評価し、最後の値だけを標準出力へ S 式で表示する。
ファイルは生成せず、LLM キャッシュにはカレントプロジェクトの `.allisp/oracle/` を使う。
`--dry-run`、`--refresh`、`--strict`、`--model` も併用できる。

## 評価結果のコード生成

**`generate-file` マクロ**は、body の最終評価値を一つのトップレベル S 式として別ファイルへ書き出す。

```lisp
(generate-file "generated/add-two.lisp"
  (synthesize-adder :increment 2))  ; 未定義のため LLM が defun を返す
```

出力先の相対パスは、呼び出し元ファイルを基準に解決する。
LLM が `(defun add-two (x) (+ x 2))` を返すと、`generated/add-two.lisp` には次の三つのフォームを書き出す。

1. `generated-by` マクロの定義
2. 生成元、元フォーム、生成時刻を記録する `generated-by` 呼び出し
3. `(defun add-two (x) (+ x 2))`

生成ファイルを評価すると、生成情報は `*generated-by*` に plist として束縛される。
`--dry-run` は評価境界と出力予定パスだけを表示し、ファイルを作成しない。

**入力**：allisp 形式の `.lisp` ファイル一つ。
トップレベルの各 S 式を先頭から順に評価する。
`(@use "相対パス")` で他ファイルの定義を継承できる。

**出力**：入力ファイルと同じディレクトリの `output/` に二つのファイルを生成する。

```
your_folder/
├── bar.lisp                  # 入力
└── output/
    ├── bar.result.lisp       # 全トップレベル式の評価結果（result :n K :form … :value …）
    └── bar.trace.lisp        # 全オラクル呼び出しの記録（hash / model / hit または miss / 値）
```

プロジェクトルートの `.allisp/oracle/` には、オラクルキャッシュが蓄積される。
このキャッシュによって、再実行を決定論的にリプレイできる。
詳細は [言語仕様](docs/language.md) を参照。
ルートは入力ファイルから上方向に `.allisp/` または `.git/` を探して決める。
どちらもなければ、入力ファイルのディレクトリを使う。

**終了コード**：`0` はエラーなし、`1` はエラー値または `--strict` による停止、`2` は使い方の誤り、`3` は内部エラーを表す。

## ビルド

必要な環境は次のとおり。

- [Roswell](https://github.com/roswell/roswell)（SBCL の管理用）。
  `brew install roswell` で導入する。
- [Claude Code](https://claude.com/claude-code) の CLI（LLM オラクルの呼び出し用）。
  事前に認証する必要がある。
- 依存ライブラリ（ironclad、fiveam）。
  初回実行時に Quicklisp が自動取得する。

```sh
cd /path/to/allisp
make test      # テストスイートを実行
make install   # ~/.local/bin/allisp に bin/allisp への symlink を作成
make build     # 依存込みの単一実行ファイル dist/allisp を生成
make clean     # dist/ を削除
```

- **`bin/allisp`**：Roswell スクリプト。
  ソースの変更が即座に反映されるため、日常の実行に向く。
- **`dist/allisp`**：`save-lisp-and-die` イメージ。
  Roswell と Quicklisp を必要としない自己完結バイナリである。
  変更後は `make build` で再生成する。
