# allisp 言語セマンティクス

設計決定の経緯は [DESIGN.md](../DESIGN.md) に記録している。
この文書では、確定した言語仕様を示す。

## LLM を呼び出す実行境界

評価器は、フォームが定義済みかどうかで実行経路を分ける。
この **段階評価境界** により、LLMによるコード生成とLisp処理系による実行を分離する。

1. **定義済みのフォーム**：特殊形式、`defun`、`defmacro`、`define`、`def` で定義した名前、許可リストにあるビルトインは決定論的に評価する。
   ビルトインには、算術、比較、リスト、文字列、`mapcar`、`filter`、`reduce` などの高階関数、`get-property`、`equal?` を含む。
2. **未束縛フォーム**：演算子に定義がないフォームは、引数を評価せずフォーム全体を LLM に渡す。
   LLMの役割は値や実行成功を捏造することではなく、意図を一つのLisp式へloweringすることだけである。
3. **実行ゲート**：生成された式に現れる演算子と値を決定論的評価器がすべて解決できる場合だけ、LLMフォールバックを禁止した状態でその式を評価する。
   リストデータを返すコードは、裸のリストではなく `(quote (...))` または `(list ...)` でなければならない。
4. **中間コード**：一意なプログラムを生成できない場合、または生成コードに未束縛演算子が残る場合は、実行せず `(intermediate-code ...)` として返す。
5. **効果位置のエスカレーション**：`(let ((x 1)) (mystery x) (+ x 1))` のように値を捨てる位置の未束縛式は、loweringに必要な意味を失わないよう、囲むフォーム全体を一回だけコード生成対象にする。

LLMはメモリ確保、ファイル変更、ネットワークアクセス、デプロイ、メッセージ送信などが成功したと主張してはならない。実際の効果が発生するのは、生成コードが評価器に実装済みの演算だけで構成され、実行ゲートを通過した場合に限る。

```lisp
;; memory-alloc と memory-block が未定義なら実行されない
(memory-alloc 1 :int)
;; =>
(intermediate-code
  :source (memory-alloc 1 :int)
  :reason
  (:why "generated code contains operators that the evaluator cannot resolve"
   :how "define memory-block using deterministic Lisp operations, then run another lowering pass")
  :generated (memory-block :type :int :length 1))
```

`memory-block` の具体的なloweringとして、allispはプロセス内のmanaged memoryを提供する。

```lisp
(allocate-memory-block
  :element-type :int
  :integer-width 32
  :length 1
  :initialization :uninitialized)
```

これはSBCLのspecialized arrayを実際に確保するが、初期化bitmapを別に持つため、`memory-block-read`は`memory-block-write`前の要素を読み出さない。resultへのexternalizeも生のcontentsを読まず、型、幅、長さ、初期化済み要素数、プロセス内寿命だけを記録する。

## オラクルに渡す文脈

オラクルに渡すプロンプトには、評価器が依存解析した情報を自動で含める。

- 対象フォームと、それを囲むトップレベルフォームが参照するシンボルの束縛値
- 該当するマクロと関数の定義元ソース。
  docstring と `@use` で読み込んだ定義も含む。
- 囲むトップレベルフォーム全体

既定ではファイル全体を渡さない。
ファイル全体を渡すと、関係のない変更でもキャッシュキーが変わり、コストも増えるためである。
`(llm <form> :context :file)` を指定すると、明示的にファイル全体を渡せる。

## オラクルの探索（agentic oracle）

ファイル実行では、オラクルのサブプロセスに読み取り専用ツール（Read / Glob / Grep）を許可し、プロジェクトルートを作業ディレクトリとして起動する。
プロンプトにはソースファイルのパスとプロジェクトルートを記した Environment 節が入り、オラクルは回答前に、フォームが参照するファイル（`basis` や `@use` の相対パスなど）や周辺ファイルを自分で読んで文脈を集める。
これは、依存解析で同梱できるのが環境内の束縛だけであり、思考 DSL がファイルパスで指す外部文脈には届かないことを補うためである。

- `--no-explore` を指定すると探索を止め、同梱文脈だけからコードを生成する。
  探索の有無でプロンプトが変わるため、キャッシュキーは自動的に分かれる。
- fresh なオラクル呼び出しは「呼び出し時点のリポジトリ状態」を反映したコードを生成する。
  キャッシュからのリプレイは同じ生成コードを決定論的評価器で再評価する。周辺ファイルが変わってもコードは変わらない。再生成させたいときは `--refresh` か `(llm :fresh t)` を使う。
- one-liner 実行には起点となるソースファイルがないため、Environment 節は付かない。

## 明示的に実行経路を選ぶフォーム

通常の実行境界では不足する場合は、次のフォームで経路を指定する。

```lisp
(llm <form> :model :opus :fresh t :context :file)  ; 強制的にオラクルへ渡す
;;   :model   この式だけモデルを指定する（:sonnet | :opus | :haiku）
;;   :fresh   キャッシュを無視して再実行する
;;   :context :file でファイル全体を文脈に含める

(pure <body>...)      ; オラクルを禁止する。未束縛フォームはただちにエラー値となる

(fix <form> :rounds 2 :model :opus)  ; intermediate-code なら仮定を補って再 lowering する

(@use "path.lisp")    ; 呼び出し元からの相対パスを評価し、すべての定義を継承する（冪等）
```

`intermediate-code` は特殊形式だが、その内容を評価しない不活性なデータである。
`:reason` は必ず `(:why <停止理由> :how <具体的な解決方法>)` を持つ。旧形式の文字列reasonやLLMが片方を省略した結果も、評価器がこの形式へ正規化する。
追加の定義・制約・選択肢を用意した後、`(llm (intermediate-code ...))` と明示すれば次のlowering段階へ進められる。

**`fix`** は intermediate-code を人手なしで先へ進めるフォームである。`(fix <form>)` は `<form>` を評価し、値が intermediate-code のときだけ **Fix モード**のオラクルを最大 `:rounds` 回（既定 2）呼ぶ。Fix モードでは `:reason` の `:how` を指示として扱い、不足している前提・選択を最も妥当な既定値で埋めることが許可される。ただし導入した仮定はすべて生成コード内の束縛（`let` など）として明示しなければならない。実行に至ると値は

```lisp
(fixed :source <元フォーム> :code <生成コード> :value <評価値>)
```

となり、`:code` を読めば **fix が何を勝手に仮定したか**を検査できる（`(get-property x :value)` で値だけ取り出せる）。修正が不要な値は素通しし、全巡未解決なら最後の intermediate-code が返る。曖昧さを止まって報告してほしい場面では `llm` のまま、既定値で構わないからとにかく実行可能な形まで進めたい場面では `fix` を使う。

オラクルの生成コードには**アンチ散文規則**が課される。束縛から導出できる数値・件数・比較・予測は、文字列リテラルに書かず、束縛を参照する評価可能な部分式として生成する（例: 成長予測は「約98件/分」という散文ではなく `(* peak (expt (+ 1 growth) 4))`）。導出値は常に評価器が計算するため検算可能で、前提の変更に追従する。文字列は計算不能な判断にのみ使う。

## 結果ファイルの再利用（chain）

実行が生成する `output/foo.result.lisp` は、そのまま `@use` の対象にできる。
result ファイルの各フォーム `(result :v 2 :n K :form F :value V)` は組み込みの `result` フォームとして評価され、`:form` を再評価せず、`:value` を未評価のデータとして扱う。
したがって **リプレイはオラクルを一度も呼ばない**。

```lisp
;; 上流 plan.lisp — 公開したい値に def で名前を付ける
(def CONCLUSION (plan_dsl ...))

;; 下流 — result ファイルを読み込むと、名前がそのまま復元される
(@use "./output/plan.result.lisp")
(to-markdown CONCLUSION)
```

- `:form` が `def`（`defvar` / `defparameter` / `define` の変数形を含む）のとき、その名前を `:value` で再束縛する。
  このために `def` は束縛した値を返す（[方言](#方言)参照）。
- `defun` / `defmacro` は復元しない。クロージャはファイルに保存できず、
  `:value` には `(closure name)` のようなプレースホルダしか残らないためである。
  関数も含めて継承したい場合は、result ファイルではなく元のソースを `@use` する。
- 名前のない式の値には、直近の result の値を指す `last-result` でアクセスできる。
- `:v` キーは result 形式のバージョンである。`:v` を持たない旧形式（v1）は
  `def` の値を記録していないため、名前の復元は行わない。
  元ソースを再実行（全キャッシュヒット）すれば新形式で再生成される。
- この仕様により `result` は予約語になった。ユーザー DSL の演算子名には使えない。

## 結果ファイルの差分（allisp diff）

`allisp diff <old.result.lisp> <new.result.lisp>` は 2 つの result ファイルを比較し、どの前提の変更がどの結論を変えたかを表示する。LLM は呼ばない。

```sh
allisp run plan.lisp --out-dir before/
# 前提を編集して再実行（依存するオラクル式だけが再思考される）
allisp run plan.lisp --out-dir after/
allisp diff before/plan.result.lisp after/plan.result.lisp
```

- `def` 系のフォームは**定義名**で対応付ける。前提を編集するとフォーム自体が変わるため、フォームの同一性では照合できない。それ以外のフォームはフォーム自身で照合し、同一フォームの重複は出現順で対応付ける。
- 差分は 1 件につき 1 つの S 式で出力される: `(changed :name <定義名> :old <旧値> :new <新値>)`、def 系以外は `:name` の代わりに `:form <フォーム>`。片方にしかない式は `(added ...)` / `(removed ...)`。
- exit code は同一なら 0、差分があれば 1（`diff(1)` と同じ規約）。

## 評価結果をファイルに書き出すマクロ

`generate-file` は、評価した Lisp フォームを別の Lisp ファイルとして保存する。
**`generate-file` マクロ**は `<body>` を順に評価し、最後の値を一つのトップレベル S 式として書き出す。

```lisp
(generate-file "path.lisp" <body>...)
```

- 相対パスは呼び出し元ファイルを基準に解決する。
  one-liner から呼び出す場合はカレントディレクトリを基準にする。
- 生成先のディレクトリがなければ作成する。
  呼び出し元ファイル自身を上書きしようとするとエラーになる。
- 評価値がエラー値の場合は書き出さない。
- 複数のトップレベルフォームを生成する場合は、値を `(progn <form>...)` にする。
- `--dry-run` を指定した場合はファイルを作成しない。
- **書き出し先が `.lisp` 以外の場合、値は文字列でなければならず、生テキストとしてそのまま書き出す**（末尾に改行がなければ補う）。
  Python やシェルスクリプトなど S 式でないコードへ落とし込む chain の終端に使う。
  コメント構文が形式ごとに異なる（JSON にはない）ため生成履歴ヘッダは埋め込まず、生成の記録は trace に残る。
  文字列以外の値は `:generated-text-not-string` のエラー値になる。
  `.lisp` 以外への書き出しでは、`<body>` 評価中のオラクル呼び出しに「Lisp文字列リテラルを一つ生成する」ルールが自動で加わる
  （プロンプトが変わるため、該当呼び出しは通常評価とは別のキャッシュエントリになる）。

```lisp
;; 抽象 DSL の結論を Python スクリプトに落とし込む
(@use "./output/plan.result.lisp")
(generate-file "generated/review.py"
  (lower-to-python CONCLUSION))   ; 未定義 → LLM が Python コードの文字列を返す
```

生成ファイルの先頭には、次の情報を自動で挿入する。

1. `generated-by` マクロの定義
2. `(generated-by generate-file :source ... :form ... :generated-at ...)` マーカー

マーカーを評価すると、`*generated-by*` に `:generator`、`:source`、`:form`、`:generated-at` を持つ plist を束縛する。
ツールはソース上のマーカー、または評価後の `*generated-by*` によって自動生成コードを識別できる。

## Markdown を allisp に変換する（markdown->lisp）

`markdown->lisp` は、markdown で書かれたプロンプト・指示・手順書をオラクルに変換させ、allisp のプログラムとして取り込む特殊形式である。

```lisp
(markdown->lisp <source> [:from :file|:text] [:out <path.lisp>]
                [:model <m>] [:fresh t] [:eval t])
```

- **入力元**: `<source>` は既定（`:from :file`）では呼び出し元ファイル基準の markdown ファイルパス。`:from :text` を指定すると `<source>` の文字列自体を markdown 文書として扱う。`:from "doc.md"` のようにパス文字列を直接渡してもよい（このとき `<source>` は不要）。
- 入力元と `:out` は**決定論的に評価**される。未束縛のシンボルを渡してもオラクルには送られず、即座にエラー値になる。
- **出力先**: `:out` を指定すると、変換したフォーム列を `.lisp` ファイルとして書き出す（`generate-file` と同じ `generated-by` マーカー付き。`.lisp` 以外のパスはエラー値）。省略時は書き出さない。
- 値は変換された**トップレベルフォームのリスト**（未評価のプログラム）。`:eval t` を指定すると `@use` と同様に各フォームを現在の環境で順に評価し、`def` などの定義を取り込む。
- `:model` / `:fresh` は `llm` と同じ。変換は通常のオラクル機構（キャッシュ・trace・`--dry-run`・リトライ）に乗る。文書全文がプロンプトに含まれるため、文書が変われば自然に別のキャッシュエントリになる。

変換のオラクルには**散文禁止**の規則が課される。文書を文字列として言い換えることは禁止され、見出し・指示・箇条書き・表・制約はすべて構造化された S 式（`def` / `defun` / `defmacro`、キーワード plist、シンボル、数値）になる。既存の構文と型を最優先で使い、それで捉えられないドメイン構造には小さな宣言的 DSL を設計する（未束縛演算子は後段のオラクルが lowering する）。自然言語文字列は計算不能な内容（引用文など）に限られる。文書から一意に変換できない場合は `intermediate-code` が返り、何も書き出されない。

```lisp
;; 手順書をプログラム化して保存し、そのまま定義も取り込む
(markdown->lisp "runbook.md" :out "generated/runbook.lisp" :eval t)
```

## 非決定的な論理探索

`goal` で事実と規則を登録し、`solve` で Prolog 風の深さ優先探索を行える。
`?` で始まるシンボルは論理変数である。`solve` の値は、各解を `:変数名` の plist で表したリストになる。

```lisp
(goal parent (alice bob))
(goal parent (bob carol))
(goal ancestor (?x ?y) (parent ?x ?y))
(goal ancestor (?x ?y) (parent ?x ?z) (ancestor ?z ?y))

(solve (ancestor alice ?who))
;; => ((:who bob) (:who carol))
```

`goal` の頭部は `(goal (parent alice bob))` のように一つの述語フォームで書いてもよい。規則の本体には、他のゴールと `(constraint <式>)` を混在できる。制約は必要な論理変数が束縛された時点で、オラクルを使わず決定論的に評価される。偽、未束縛変数、または決定論的に評価できない式は、その探索枝を失敗させる。

```lisp
(goal age (bob 20))
(goal adult (?person)
  (age ?person ?years)
  (constraint (>= ?years 18)))

(solve (adult ?person))
;; => ((:person bob))
```

## エラー値

失敗した式は **エラー値** として result に埋め込み、残りの評価を続ける。
この部分評価により、ある式が失敗しても成功した式の結果を確認できる。

```lisp
(error :type :oracle-failure :form (...) :detail "...")
```

`:type` には、`:oracle-failure`、`:unbound-in-pure`、`:use-not-found`、`:not-a-function`、`:host-error` などが入る。
`:oracle-failure` は、三回再試行しても S 式を得られなかったことを表す。

エラー値が一つでもあれば、終了コードは非ゼロになる。
成功した式の結果はキャッシュ済みなので、再実行時には失敗箇所だけを再問い合わせできる。
`--strict` を指定すると、最初のエラーで停止する。

## 永続オラクルキャッシュ

オラクルの結果は、次のパスに保存する。

```
<プロジェクトルート>/.allisp/oracle/<sha256>.lisp
```

- キャッシュキーは、プロンプト版、モデル、完成したプロンプト全体から計算した sha256 である。
  プロンプトには参照定義、束縛、囲むトップレベルフォーム、対象フォームが含まれる。
  そのため、意味のある依存が変わった式だけを無効化できる。
- プロジェクトルートは、対象ファイルから上方向に `.allisp/` または `.git/` を探し、最初に見つかったディレクトリに決める。
  どちらもなければ対象ファイルのディレクトリを使う。
- 各キャッシュファイルは、`:form`、`:code`（生成されたLispコード）、`:raw`（生の応答）、`:model`、`:timestamp` を持つ自己記述的な plist である。
  キャッシュヒット時は`:code`を現在の決定論的環境でもう一度評価する。評価済みの値や副作用成功の主張をリプレイするものではない。
  Git で管理すれば、LLM の応答履歴として追跡できる。
- キャッシュを捨てるときは `.allisp/` を削除する。
  `--refresh` と `(llm :fresh t)` を使えば、対象を限定して再実行できる。

## 方言

- **Lisp-1**：関数と変数は単一の名前空間を共有するため、`(mapcar f list)` と書ける。
- 小文字のソースは小文字のまま往復する（readtable `:invert`）。
  `→` などの記号もシンボルとして使える。
- quote、backquote、comma は独自の reader macro により、`(quote ...)`、`(quasiquote ...)`、`(unquote ...)`、`(unquote-splicing ...)` の平リストとして読まれる。
- `(def name expr)` は `expr` を評価して束縛する。
  `(def name f1 f2 ...)` はフォーム列を未評価のデータとして束縛するため、散文的な定数表にも使える。
  `def` 系の評価値は**束縛した値**である（CL と異なり名前ではない）。
  result ファイルに値が記録され、chain で復元できるようにするためである。
  `defun` / `defmacro` は従来どおり名前を返す。
- マクロの `&key` は、引数が奇数個の場合やキーワード以外が混ざる場合もエラーにしない。
  思考用 DSL の自由な記法を許容するためである。
- `t` と `nil` 以外の CL シンボルは見えない。
  許可リストにない名前は、確実にオラクルへ渡る。
- **特殊形式**：`quote`、`quasiquote`、`if`、`cond`、`when`、`unless`、`let`、`let*`、`lambda`、`progn`、`and`、`or`、`defun`、`define`、`defmacro`、`def`、`defvar`、`defparameter`、`setq`、`setf`、`push`、`incf`、`decf`、`@use`、`llm`、`pure`、`fix`、`defer`、`deprecate`、`result`、`intermediate-code`、`markdown->lisp`
- **managed memory組み込み**：`allocate-memory-block`、`memory-block-write`、`memory-block-read`、`managed-memory-block-p`

### 保留・非推奨の判断

- `(defer code :reason reason ...)` は `code` を評価せず、コードと評価済みのメタデータを
  `(defer code :reason value ...)` として返す。`code` は結果に残るため、保留した判断を後から
  再開できる。
- `(deprecate code :reason reason ...)` は `code` を通常どおり評価し、評価結果を
  `(deprecate value :deprecated t :reason value ...)` として返す。これにより、非推奨である
  こととその理由を、評価後も結果 S 式に残せる。
- **組み込みマクロ**：`generate-file`、`goal`、`constraint`、`solve`
