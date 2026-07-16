# allisp 開発ガイド

## テスト

```sh
make test    # fiveam（ros run + ql:quickload :allisp/tests を実行）
```

テストは、reader の往復、決定論的な評価、`defmacro` と quasiquote の展開、高階ビルトインを検証する。
さらに、正規順序オラクル、効果位置のエスカレーション、キャッシュをまたぐヒット、`(llm)` の強制、`(pure)` の遮断、文脈の同梱、`@use`、プロジェクトルートの検出を検証する。
`generate-file` では、生成元メタデータ、再読込後の実行、dry-run を検証する。
コードフェンスの除去、パースの再試行、エラー値を返して評価を継続する動作も対象にする。
LLM は `mock-backend` に置き換えるため、テストは LLM を呼び出さずに完結する。

## ソース構成

```
src/
├── package.lisp    # allisp と allisp.user（ユーザーコードは空パッケージで読む）
├── reader.lisp     # :invert readtable、独自の quote と quasiquote の reader、S 式の印字
├── env.lisp        # 環境、クロージャ、マクロ、run 状態、エラー値
├── backend.lisp    # backend-complete protocol（Claude Code CLI とテスト用 mock）
├── cache.lisp      # sha256 キーによる永続キャッシュ
├── plugin.lisp     # Git/ASDF プラグインの取得とホスト実装の構文マクロ登録
├── eval.lisp       # メタ循環評価器、特殊形式、オラクル、文脈の同梱、エスカレーション
├── builtins.lisp   # CL の許可リストにあるビルトイン
├── runner.lisp     # run-file、run-one-liner、result と trace の書き出し
└── cli.lisp        # allisp run
tests/main.lisp     # fiveam スイート
bin/allisp          # Roswell スクリプト
Makefile            # test、build、install、clean
```

## バックエンドの差し替え

LLM 呼び出しは **`backend-complete` generic function** で抽象化している。

```lisp
(defgeneric backend-complete (backend prompt &key model))
```

現行実装の `claude-cli-backend` は、`claude -p --model <m>` をサブプロセスとして実行する。
Anthropic API を直接呼び出す実装に切り替える場合は、このメソッドを実装したクラスを追加する。
そのインスタンスを `run-file` または `run-one-liner` の `:backend` に渡せばよい。
キャッシュキーはプロンプトとモデルから決まる。
このため、同じプロンプトとモデルを使うバックエンド間ではキャッシュを共有する。

## 構文プラグイン

起動時に `--plugin <git-url[#revision]>` を渡すと、allisp はリポジトリを
プロジェクトの `.allisp/plugins/` に取得し、ASDF システムをロードする。プラグインは
ホスト Common Lisp を実行するため、信頼できるリポジトリだけを指定する。運用では URL の
末尾に完全なコミットハッシュを `#` で指定して固定する。

```sh
bin/allisp run thought.lisp \
  --plugin 'https://github.com/acme/allisp-review-syntax.git#<commit-sha>'
```

リポジトリのルートには、通常の `.asd` に加え、ロード対象を明示する
`.allisp-plugin/plugin.lisp` を置く。

```lisp
(:system "acme-allisp-review-syntax"
 :asd "acme-allisp-review-syntax.asd")
```

ASDF システムは `allisp` に依存させ、専用パッケージから `define-syntax-macro` を import
する。展開関数は未評価の allisp 引数を受け取り、評価器が実行する allisp フォームを一つ
返す。これは SBCL のコンパイル済み ASDF コンポーネントとして配布・テストでき、プラグイン
間のシンボル衝突も避けられる。

```lisp
;; acme-allisp-review-syntax.asd
(asdf:defsystem "acme-allisp-review-syntax"
  :depends-on ("allisp")
  :serial t
  :components ((:file "syntax")))

;; syntax.lisp
(defpackage #:acme.allisp.review-syntax
  (:use #:cl)
  (:import-from #:allisp #:define-syntax-macro))
(in-package #:acme.allisp.review-syntax)

(define-syntax-macro when-present ((value form) &body body)
  `(let ((,value ,form))
     (when ,value ,@body)))
```

この例により、allisp 側では `(when-present (report (read-report id)) ...)` と書ける。
外部マクロは各評価環境の生成時に登録され、通常の allisp `defmacro` と同様に展開される。

## ビルド時の Roswell の問題

`ros build` は、現行環境（Roswell 24.10.115、SBCL 2.5.11）では Roswell 側の core 生成バグにより失敗する。
エラーは named-readtables の readtable iterator で発生する。
そのため `make build` は、`sb-ext:save-lisp-and-die` を直接呼び出して `dist/allisp` を生成する。
Roswell がこの問題を修正した場合は、`ros build bin/allisp` に戻せる。

## v2 の候補

- REPL と watch モード
- `result.lisp` から自然言語のレポートを生成する機能（現行の `output/*.txt` に相当するレンダリング層）
- Claude Code から評価器を呼び出す MCP サーバー
- 式の種別に応じたモデルの自動振り分け
- オラクルプロンプトの言語固定。
  現状では Claude Code CLI がユーザー環境の設定を継承するため、英語のソースに日本語で返答することがある。
