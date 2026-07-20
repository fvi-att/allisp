# 仕様を正本にする

このガイドは、allisp ファイルを**仕様の正本**(source of truth)として書き、
可読ドキュメント、テスト、実装のすべてを LLM に生成させるワークフローの使い方を説明する。
中心となるのは仕様専用の構文である。

- `defspec`：仕様を第一級の値として束縛する(スキーマ検査付き)
- `check-spec`：不変条件と実例の矛盾を、派生物を作る前に検出する
- `derive`：派生物を生成し、派生関係を台帳に記録する
- `verify` + `allisp run --verify`：生成したテストの実行までをパイプラインに含める
- `allisp spec status`：仕様の変更と派生物の手編集を後から検出する
- `probe-spec`：仕様の穴(未規定の角、条項間の矛盾)を能動的に探索する

構文の正確な仕様は [language.md](language.md) の「仕様の第一級構文」節にある。
動くサンプルは sample/13〜16 で、
[sample/16-verify-pipeline.lisp](../sample/16-verify-pipeline.lisp) が一気通貫の実例である。
なお、専用構文を使わず `def` の plist と `generate-file` だけで同じ運用を組むこともできる
([sample/12-spec-as-source.lisp](../sample/12-spec-as-source.lisp))。
専用構文はその素の書き方と値レベルで互換であり、検査、台帳、監査を上乗せする。

## なぜ仕様を S 式で書くのか

自然言語の仕様書は正本になれない。書いた瞬間から実装とずれ始め、
ずれても誰も気づかず、読む人ごとに解釈が変わる。

このワークフローでは立場を逆にする。

- **手で書くのは仕様だけ**。不変条件と実例を `defspec` の条項として形式的に書く。
- 人間が読むドキュメント、CI が走らせるテスト、実装コードは、
  すべて仕様**から**生成される派生物とする。派生物を手で直したくなったら、
  それは仕様に足りない条項がある合図である(手で直しても `spec status` が検出し、
  次の再生成で消える)。
- 生成はオラクルキャッシュに乗るため、仕様が変わらない限り
  派生物はバイト同一に再生成される(LLM 呼び出しゼロ、$0)。
  **派生物が正本からドリフトしない**ことを、規律ではなくキャッシュと台帳が保証する。

```
spec.lisp(手書きの正本)
  ├─ (check-spec ...)             仕様自体の整合性検査
  ├─ (derive ... :via ...) ×3     spec.md / test_*.py / impl.py を生成 + 台帳記録
  ├─ (verify "pytest ...")        --verify 付き実行でテストまで通す
  └─ (probe-spec ...)             仕様の穴を能動探索
```

## ステップ 1: defspec で仕様を書く

```lisp
(defspec slugify
  :module "slugify"
  :signature (:in (title string) :out (slug string))
  :invariants
  ((:only-chars "the slug contains only lowercase ascii letters, digits, and single hyphens")
   (:no-edge-hyphen "the slug never starts or ends with a hyphen")
   (:collapse "every maximal run of non-alphanumeric characters becomes one hyphen")
   (:idempotent "slugify(slugify(x)) equals slugify(x)")))

(example slugify :name :hello-world
  :in "Hello, World!" :out "hello-world"
  :context "ASCII slug policy applies to an ordinary title.")
(example slugify :name :ready
  :in "  READY  to   SHIP  " :out "ready-to-ship"
  :context "ASCII slug policy applies to an ordinary title.")
(example slugify :name :version
  :in "v2.0 (beta)" :out "v2-0-beta"
  :context "ASCII slug policy applies to an ordinary title.")
```

条項は評価されないデータであり、束縛前に決定論的に検査される。
条項名の重複、`(:name "1文")` 形でない不変条件、壊れた top-level example は
エラー値になり、**何も束縛されない**。壊れた仕様の上に派生物が積み上がることはない。

書き方のコツは素の書き方と同じである。

- **不変条件には名前を付ける**(`:no-edge-hyphen` など)。検査の違反報告、
  `probe-spec` の発見、生成されるテスト関数名がこの名前で仕様を指す。
- **実例は名前と context を持つ**。context は補足ではなく規範的要件であり、
  同じ入力でも背景が違えば複数の出力を登録できる。実装が条件を判別できない場合は
  probe が `:unobservable-context-condition` を報告する。
- 1 条項 = 1 文にする。複文はオラクルの解釈余地を増やす。

## ステップ 2: check-spec で仕様自体を検査する

派生物を作る前に、仕様が自分の実例と矛盾していないかを検査する。

```lisp
(check-spec slugify)
```

各不変条件と、各 distinct context が `(lambda (in out) ...)` 述語に lowering され、
全実例へ決定論的に適用される。`(example ... :in "!!!" :out "")` のような実例を足した瞬間に、
`:collapse`(全体が 1 本のハイフンになる)と `:no-edge-hyphen`(端のハイフン禁止)の
矛盾が「どの条項がどの実例で偽か」として名指しされる。

- invariant 述語のキャッシュは**条項単位**、context 述語は
  signature + context + covers 単位である。
- 冪等性のように 1 組の (in, out) では判定できない条項は、
  弱い検査に近似されず `:skipped` に理由付きで記録される。
  そうした条項の検証は、生成されたテストと実装に対する `verify`(ステップ 4)が受け持つ。

## ステップ 3: derive で派生物を生成する

derive の前に focus なしの完全監査も実行する。

```lisp
(probe-spec slugify)
```

derive は現在の spec/example/dependency hash に一致する check と、
`:complete t`・findings 0 の probe 証明がなければ停止する。

生成は `derive` で宣言する。書き出しの挙動は `generate-file` と同一で、
加えて「何がどの仕様から派生したか」が台帳(`.allisp/derive.lisp`)に記録される。

```lisp
;; 1. 可読ドキュメント
(derive "output/slugify-spec.md"
  :from slugify
  :via (document-spec
         :spec slugify
         :audience "a developer implementing or reviewing slugify"
         :format "markdown with an Invariants section and an Examples table"))

;; 2. テストオラクル
(derive "output/test_slugify.py"
  :from slugify
  :via (lower-to-pytest :spec slugify :import-from "slugify"))

;; 3. 実装。テストの後に置く(オラクルは直前に生成されたテストを読める)
(derive "output/slugify.py"
  :from slugify
  :via (implement-to-pass
         :spec slugify
         :test-file "output/test_slugify.py"
         :language "python 3, standard library only"))
```

`:via` の `document-spec` / `lower-to-pytest` / `implement-to-pass` は
**どこにも定義されていない**未束縛フォームであり、全体がオラクルに渡って
LLM がコードを生成する(これが allisp の通常の実行境界である)。
`:via` が仕様の束縛を参照するため、仕様全文がプロンプトに自動同梱され、
同時にキャッシュキーに入る。仕様を編集すると、参照している derive だけが
再生成対象になる。

`:from` に仕様名を書くことで台帳に条項ハッシュが記録され、
後述の `spec status` が鮮度を判定できるようになる。

## ステップ 4: verify でテストまで通す

生成したテストの実行は allisp の評価器の仕事ではない(実行主体は決定論的評価器か
外部ツール、という言語の原則がある)。`verify` はコマンドを**登録するだけ**の
不活性なフォームで、実行は CLI の明示フラグが担う。

```lisp
(verify "python3 -m pytest output/test_slugify.py"
  :targets ("output/test_slugify.py" "output/slugify.py"))
```

```sh
bin/allisp run spec.lisp --verify
```

`--verify` を付けると、全フォームの評価と全ファイル生成の後に、登録順に
コマンドが実行される(cwd はソースファイルのディレクトリ)。テストが失敗すると
result 上の `verify` フォームの値がエラー値になり、終了コードが非ゼロになる。
CI はこの 1 行だけを見ればよい。成功すると `:targets` の台帳エントリに
verified が刻まれ、`spec status` に表示される。

`--verify` を付けない実行では何も実行されず、レコードは `:status :pending` のまま残る。

## ステップ 5: spec status で鮮度を見張る

```sh
allisp spec status
```

台帳の各派生物について 1 S 式が出る。LLM は呼ばれない。

- `(fresh :target ... :verified t)`：仕様も派生物も生成時のまま。テスト済み
- `(stale :target ... :from slugify)`：仕様の条項が変わった。ソースを再実行すれば解消
  (仕様以外が原因で再実行しても、キャッシュリプレイでバイト同一に戻る)
- `(drifted :target ...)`：派生物が手編集された。**直したい内容は仕様側の条項として書く**
- `(missing ...)` / `(unknown ...)`：派生物が消えた / 記録ソースに defspec が見つからない

全 fresh なら exit 0、それ以外は 1 なので、CI のゲートにそのまま置ける。

## ステップ 6: probe-spec で穴を探し、仕様を直す

検査(ステップ 2)は実例に触れた矛盾しか検出できない。実例が届いていない角は、
オラクルに能動的に探索させる。

```lisp
(probe-spec slugify)
```

返り値は発見のリストで、各発見は `intermediate-code` の形をしている。
`:why` が矛盾・沈黙する invariant/example 名を、`:how` が決着させる具体的な
top-level `example` または invariant 改訂を指す。
**オラクルは答えをでっち上げない**。仕様が決めていないことは、
穴として名指しされる。散文の仕様書に聞けばそれらしい答えが返ってきて
穴は隠れるが、形式モデルに聞くと穴が名指しされる。

`:how` に従って example を足すか矛盾する invariant を改訂して再実行すると、

- その条項に依存する `check-spec` の述語と `derive` の派生物だけが
  キャッシュミスになり、再生成される。
- 依存しないフォームはキャッシュヒットのまま動かない。
- `probe-spec` 自体は仕様全体をプロンプトに含むため再探索される
  (穴は条項の組に宿るので、これは意図した粒度である)。

これが「1 条項の編集は、それに依存する検査と派生物だけを再考させる」の実体である。

関連コマンド:

```sh
bin/allisp run spec.lisp --refresh          # 仕様を変えずに全派生物を再考させる
allisp diff output/old.result.lisp output/new.result.lisp
                                            # どの条項の変更がどの結論を変えたか
```

オラクルキャッシュ(`.allisp/oracle/`)と台帳(`.allisp/derive.lisp`)を Git に
コミットしておくと、チームの誰が再実行しても同じ派生物が同じバイト列で再現され、
鮮度の判定も共有される。

## つまずきやすい点

- **`:via` のフォーム名が定義済みとかぶる**: `document` や `implement` のような
  短い名前が将来 `defun` されると、オラクル行きだったフォームが決定論的評価に
  変わってしまう。`lower-to-pytest` のような具体的な動詞句を推奨する。
- **check-spec が全条項 `:skipped` になる**: 条項が実例単体で判定できない形
  (実装や複数呼び出しに言及する形)で書かれている合図。実例 1 組で判定できる
  言い方に直すか、その条項の検証は `verify` に任せる。
- **`verify` を書いたのにテストが走らない**: 実行には `--verify` フラグが必要である。
  フラグなしの実行では `:status :pending` のまま残る(これは仕様であり、
  評価器が外部コードを勝手に実行しないための境界である)。
- **spec status が `unknown` を返す**: 台帳に記録されたソースファイルの中に
  `(defspec 名前 ...)` が見つからない場合の報告。鮮度判定は記録ソース内の
  defspec に限られるため、`@use` 先で定義した仕様は判定できない。
- **`derive` の非 `.lisp` ターゲットに文字列以外が返った**: エラー値になる。
  `:format` や `:language` で出力形式を明示すると安定する。
- **probe-spec が毎回同じ発見を返す**: 発見の `:how` を仕様に反映していない合図。
  条項を足せば、その発見は次の探索で消える。既定値で埋めて先に進みたい場合は
  `(fix <form>)` が使える(language.md の `fix` 参照)。

## 関連ドキュメント

- 構文の正確な仕様: [language.md](language.md) の「仕様の第一級構文」節
- 設計上の位置づけ(決定24、26〜29): [DESIGN.md](../DESIGN.md)
- 専用構文を使わない素の書き方: [sample/12-spec-as-source.lisp](../sample/12-spec-as-source.lisp)
- 逆方向(既存の markdown 文書 → allisp プログラム): language.md の `markdown->lisp`
