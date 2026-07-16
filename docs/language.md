# allisp 言語セマンティクス

設計決定の経緯は [DESIGN.md](../DESIGN.md) に記録している。
この文書では、確定した言語仕様を示す。

## LLM を呼び出す実行境界

評価器は、フォームが定義済みかどうかで実行経路を分ける。
この **実行境界** により、同じ Lisp ファイルに決定論的な計算と LLM による擬似実行を混在させる。

1. **定義済みのフォーム**：特殊形式、`defun`、`defmacro`、`define`、`def` で定義した名前、許可リストにあるビルトインは決定論的に評価する。
   ビルトインには、算術、比較、リスト、文字列、`mapcar`、`filter`、`reduce` などの高階関数、`get-property`、`equal?` を含む。
2. **未束縛フォーム**：演算子に定義がないフォームは、引数を評価せずフォーム全体を LLM に渡す。
   LLM が返した S 式を値として使うため、正規順序で評価する。
   `(calculation (- 40 :work-hours))` のようにキーワードを含む擬似算術が決定論的評価器で失敗しないのは、この経路に渡るためである。
3. **効果位置のエスカレーション**：`(let ((x 1)) (mystery x) (+ x 1))` のように値を捨てる位置の未束縛式は、囲むフォーム全体を一回だけ LLM に渡す。
   未束縛式だけを渡すと、LLM はその副作用を実行できず、後続のフォームに影響を反映できないためである。

## オラクルに渡す文脈

オラクルに渡すプロンプトには、評価器が依存解析した情報を自動で含める。

- 対象フォームと、それを囲むトップレベルフォームが参照するシンボルの束縛値
- 該当するマクロと関数の定義元ソース。
  docstring と `@use` で読み込んだ定義も含む。
- 囲むトップレベルフォーム全体

既定ではファイル全体を渡さない。
ファイル全体を渡すと、関係のない変更でもキャッシュキーが変わり、コストも増えるためである。
`(llm <form> :context :file)` を指定すると、明示的にファイル全体を渡せる。

## 明示的に実行経路を選ぶフォーム

通常の実行境界では不足する場合は、次のフォームで経路を指定する。

```lisp
(llm <form> :model :opus :fresh t :context :file)  ; 強制的にオラクルへ渡す
;;   :model   この式だけモデルを指定する（:sonnet | :opus | :haiku）
;;   :fresh   キャッシュを無視して再実行する
;;   :context :file でファイル全体を文脈に含める

(pure <body>...)      ; オラクルを禁止する。未束縛フォームはただちにエラー値となる

(@use "path.lisp")    ; 呼び出し元からの相対パスを評価し、すべての定義を継承する（冪等）
```

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

生成ファイルの先頭には、次の情報を自動で挿入する。

1. `generated-by` マクロの定義
2. `(generated-by generate-file :source ... :form ... :generated-at ...)` マーカー

マーカーを評価すると、`*generated-by*` に `:generator`、`:source`、`:form`、`:generated-at` を持つ plist を束縛する。
ツールはソース上のマーカー、または評価後の `*generated-by*` によって自動生成コードを識別できる。

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
- 各キャッシュファイルは、`:form`、`:value`、`:raw`（生の応答）、`:model`、`:timestamp` を持つ自己記述的な plist である。
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
- マクロの `&key` は、引数が奇数個の場合やキーワード以外が混ざる場合もエラーにしない。
  思考用 DSL の自由な記法を許容するためである。
- `t` と `nil` 以外の CL シンボルは見えない。
  許可リストにない名前は、確実にオラクルへ渡る。
- **特殊形式**：`quote`、`quasiquote`、`if`、`cond`、`when`、`unless`、`let`、`let*`、`lambda`、`progn`、`and`、`or`、`defun`、`define`、`defmacro`、`def`、`defvar`、`defparameter`、`setq`、`setf`、`push`、`incf`、`decf`、`@use`、`llm`、`pure`、`defer`、`deprecate`

### 保留・非推奨の判断

- `(defer code :reason reason ...)` は `code` を評価せず、コードと評価済みのメタデータを
  `(defer code :reason value ...)` として返す。`code` は結果に残るため、保留した判断を後から
  再開できる。
- `(deprecate code :reason reason ...)` は `code` を通常どおり評価し、評価結果を
  `(deprecate value :deprecated t :reason value ...)` として返す。これにより、非推奨である
  こととその理由を、評価後も結果 S 式に残せる。
- **組み込みマクロ**：`generate-file`、`goal`、`constraint`、`solve`
