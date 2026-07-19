# 仕様を正本にする — 仕様駆動生成ガイド

このガイドは、allisp ファイルを**仕様の正本**(source of truth)として書き、
可読ドキュメント・テスト・実装のすべてを LLM に生成させるワークフローの使い方を説明する。
新しい構文は登場しない。`def` / `generate-file` / 未束縛フォームのオラクル
lowering という既存の仕組みの組み合わせ方のガイドである。

動くサンプルは [sample/12-spec-as-source.lisp](../sample/12-spec-as-source.lisp)。
以下の説明はこのサンプルを題材にする。

## なぜ仕様を S 式で書くのか

自然言語の仕様書は正本になれない。書いた瞬間から実装とずれ始め、
ずれても誰も気づかず、読む人ごとに解釈が変わる。

このワークフローでは立場を逆にする。

- **手で書くのは仕様だけ**。不変条件と実例を `def` の束縛として形式的に書く。
- 人間が読むドキュメント、CI が走らせるテスト、実装コードは、
  すべて仕様**から**生成される派生物とする。派生物を手で直したくなったら、
  それは仕様に足りない条項がある合図である。
- 生成はオラクルキャッシュに乗るため、仕様が変わらない限り
  派生物はバイト同一に再生成される(LLM 呼び出しゼロ・$0)。
  **派生物が正本からドリフトしない**ことを、規律ではなくキャッシュが保証する。

```
spec.lisp(手書きの正本)
  ├─ generate-file → spec.md        (可読ドキュメント)
  ├─ generate-file → test_*.py      (テストオラクル)
  ├─ generate-file → impl.py        (テストをパスする実装)
  └─ (llm (query-spec ...))         (仕様への問い合わせ)
```

## ステップ 1: 仕様を書く

仕様は普通の `def` 束縛である。決まった構文はないが、
**不変条件(`:invariants`)と実例(`:examples`)を分けて持つ** plist が扱いやすい。

```lisp
(def slugify-spec
  '(:function slugify
    :module "slugify"
    :signature (:in (title string) :out (slug string))
    :invariants
    ((:only-chars "the slug contains only lowercase ascii letters, digits, and single hyphens")
     (:no-edge-hyphen "the slug never starts or ends with a hyphen")
     (:collapse "every maximal run of non-alphanumeric characters becomes one hyphen")
     (:idempotent "slugify(slugify(x)) equals slugify(x)"))
    :examples
    ((:in "Hello, World!" :out "hello-world")
     (:in "  READY  to   SHIP  " :out "ready-to-ship")
     (:in "v2.0 (beta)" :out "v2-0-beta"))))
```

書き方のコツ:

- **不変条件には名前を付ける**(`:no-edge-hyphen` など)。
  生成されるテスト関数名や、後述の問い合わせ結果がこの名前で仕様を指せるようになる。
- **実例は境界を選ぶ**。実例はそのままテストの assertion になる。
  「普通の入力」だけでなく、連続空白・記号混じりなど解釈が割れそうな入力を入れる。
- 条項の文は英語でも日本語でもよいが、1 条項 = 1 文にする。
  複文はオラクルの解釈余地を増やす。

## ステップ 2: 派生物を生成するフォームを書く

生成は 3 つの `generate-file` フォームで宣言する。
中身の `document-spec` / `lower-to-pytest` / `implement-to-pass` は
**どこにも定義されていない**。未束縛フォームなので全体がオラクルに渡り、
LLM がコードを生成する(これが allisp の通常の実行境界である。
[language.md](language.md) 参照)。名前は自由だが、意図が伝わる動詞句にする。

```lisp
;; 1. 可読ドキュメント。読み手と形式を引数で指定する。
(generate-file "output/slugify-spec.md"
  (document-spec
    :spec slugify-spec
    :audience "a developer implementing or reviewing slugify"
    :format "markdown with an Invariants section and an Examples table"))

;; 2. テストオラクル。実例 → assertion、不変条件 → プロパティ検査になる。
(generate-file "output/test_slugify.py"
  (lower-to-pytest
    :spec slugify-spec
    :import-from "slugify"))

;; 3. 実装。テストの後に置くこと(後述)。
(generate-file "output/slugify.py"
  (implement-to-pass
    :spec slugify-spec
    :test-file "output/test_slugify.py"
    :language "python 3, standard library only"))
```

押さえておく点:

- **`:spec slugify-spec` と束縛を参照させる**。オラクルのプロンプトには
  フォームが参照する束縛値が自動同梱されるので、仕様全文が LLM に届く。
  同時にこの参照がキャッシュキーに入るため、仕様を編集すると
  参照しているフォームだけが自動的に再生成対象になる。
- **書き出し先が `.lisp` 以外なら、値は文字列 1 つ**という
  `generate-file` の規約(language.md 参照)がそのまま効く。
  オラクルには「Lisp 文字列を 1 つ生成する」ルールが自動で付くので、
  Python や Markdown の全文が 1 つの文字列として返る。
- **テスト → 実装の順に書く**。トップレベルフォームは上から順に評価され、
  ファイルはその場で書き出される。オラクルは読み取り専用ツール(Read/Glob/Grep)で
  リポジトリを探索できるため、実装の生成時には
  直前に生成されたテストファイルを実際に読んでから書ける。

## ステップ 3: 実行して検証する

```sh
bin/allisp run sample/12-spec-as-source.lisp     # 初回: オラクル 4 呼び出し
python3 -m pytest sample/output/test_slugify.py  # 生成された実装 vs 生成されたテスト
bin/allisp run sample/12-spec-as-source.lisp     # 再実行: 4 ヒット、LLM 呼び出しゼロ
```

pytest の実行は allisp の外で行う。allisp は生成コードの実行を
決定論的評価器で解決できる Lisp に限定しており(DESIGN.md 決定19)、
Python の実行はあなた(または CI)の仕事である。
「テストが通ること」の確認までをパイプラインに入れたい場合は、
上の 2 行目をそのまま CI のステップにすればよい。

まず LLM を呼ばずに境界だけ確認したいときは dry-run を使う。

```sh
bin/allisp run sample/12-spec-as-source.lisp --dry-run
```

どのフォームがオラクル行きか、どのパスに書き出す予定かだけが表示される。

## ステップ 4: 仕様に問い合わせる

仕様への質問は、散文ではなく形式モデル(= 仕様の束縛)に対して行う。

```lisp
(llm
  (query-spec
    :spec slugify-spec
    :question "Is the empty string a legal slug when the title has no alphanumeric characters?"
    :return-shape '(:answer symbol :because string)))
```

仕様が答えを一意に定めていれば、`:return-shape` どおりの値が返る。
**定めていなければ、オラクルは答えをでっち上げずに `intermediate-code` を返す**。
サンプルの質問は意図的に未規定の角(全記号タイトル)を突いており、実際の返り値は:

- `:reason` の `:why` — `:collapse`(全体が 1 本のハイフンになる)と
  `:no-edge-hyphen`(端のハイフン禁止)が矛盾すること
- `:reason` の `:how` — `(:in "!!!" :out "")` のような `:examples` を
  追加すれば決着すること
- `:candidates` — あり得る 2 つの解釈(トリムして空文字列 / 未定義とする)

つまり**問い合わせが仕様の穴の検出器になる**。散文の仕様書に聞けば
それらしい答えが返ってきて穴は隠れるが、形式モデルに聞くと穴が名指しされる。

## ステップ 5: 仕様を直す → 差分だけ再生成される

`:how` に従って仕様に 1 条項(例: `(:in "!!!" :out "")`)を足して再実行すると:

- `slugify-spec` を参照する 4 フォームは、プロンプトが変わるので
  キャッシュミスになり再生成される。ドキュメント・テスト・実装が
  新しい条項に追従する。
- 仕様を参照しないフォームがあれば、それはキャッシュヒットのまま動かない。

これが「1 条項の編集は、それに依存する派生物だけを再考させる」の実体である。
逆に、生成された Python やドキュメントを手で直しても次の再生成で消える。
**直したい内容は必ず仕様側の条項として書く**こと。

関連コマンド:

```sh
bin/allisp run spec.lisp --refresh          # 仕様を変えずに全派生物を再考させる
allisp diff output/old.result.lisp output/new.result.lisp
                                            # どの前提の変更がどの結論を変えたか
```

オラクルキャッシュ(`.allisp/oracle/`)を Git にコミットしておくと、
チームの誰が再実行しても同じ派生物が同じバイト列で再現される。

## つまずきやすい点

- **生成フォームの名前が定義済みとかぶる**: `document` や `implement` のような
  短い名前が将来 `defun` されると、オラクル行きだったフォームが決定論的評価に
  変わってしまう。`lower-to-pytest` のような具体的な動詞句を推奨する。
- **`generate-file` の非 `.lisp` ターゲットに文字列以外が返った**:
  エラー値になる。`:format` や `:language` で出力形式を明示すると安定する。
- **実装がテストを読んでくれない**: 探索は既定で有効だが、`--no-explore` を
  付けると無効になる。また `:test-file` のパスは呼び出し元ファイル基準の
  相対パスをそのまま文字列で渡す。
- **問い合わせが毎回 `intermediate-code` になる**: 仕様が本当に未規定である
  合図。`:how` の指示どおり条項を足すのが正道だが、既定値で埋めて先に進みたい
  場合は `(fix <form>)` が使える(language.md の `fix` 参照。導入した仮定は
  生成コード内に明示的に束縛される)。

## 関連ドキュメント

- 実行境界・`generate-file`・`fix`・キャッシュの正確な仕様: [language.md](language.md)
- 設計上の位置づけ(決定19・24): [DESIGN.md](../DESIGN.md)
- 逆方向(既存の markdown 文書 → allisp プログラム): language.md の `markdown->lisp`
