;; allisp self specification
;;
;; This file is the canonical requirements and design model for allisp itself,
;; written in allisp's own first-class spec syntax.  It is executable:
;;
;;   bin/allisp run designs/allisp.lisp
;;
;; The 25 requirements are the invariant clauses of one defspec.  Each
;; acceptance criterion is a top-level example whose :context states the
;; normative condition under which the observable holds.  Keeping every clause
;; in a single spec is deliberate: allisp's contradictions are cross-cutting
;; (the execution boundary against the spec-driven pipeline, replay determinism
;; against repository-reading oracles), and probe-spec audits clause pairs only
;; within one spec.
;;
;;   (probe-spec allisp)  actively searches for contradictions between
;;                        invariants, between contexts, and for regions no
;;                        clause determines.  One oracle call, then cached.
;;
;;   (check-spec allisp)  is deliberately NOT run here.  It costs one oracle
;;                        call per invariant clause, and the in/out of a system
;;                        requirement is prose, so most clauses would be
;;                        recorded as :skipped rather than checked.  Run it by
;;                        hand when the examples become mechanically decidable:
;;                        bin/allisp --one-liner '(@use "designs/allisp.lisp") (check-spec allisp)'
;;
;; The final form asks the read-only, repository-exploring oracle to compare
;; this model with the current implementation.  Its result must be
;; evidence-backed Lisp data, not a prose report.

(def specification-metadata
  '(:system allisp
    :kind :self-specification
    :version 2
    :status :normative
    :language :ja
    :sources ("README.md" "DESIGN.md" "docs/language.md"
              "docs/spec-driven.md" "docs/development.md")
    :implementation-root "."
    :test-command "make test"))

;; ---------------------------------------------------------------------------
;; The spec.  Invariant names are the identity of a requirement; probe
;; findings, coverage checks and design traceability all refer to these names.
;; ---------------------------------------------------------------------------

(defspec allisp
  :signature (:in (situation form) :out (observable string))
  :invariants
  ((:sexp-source-of-truth
    "allispは思考、要件、設計、処理をS式のトップレベルフォーム列として読み、評価結果も再読可能なS式として残す。")
   (:deterministic-first
    "特殊形式、束縛済み関数・マクロ・値、許可済みbuiltinだけで解決できるフォームはLLMを呼ばずに評価する。")
   (:lower-unbound-to-code
    "未束縛演算子のフォームは引数を先に評価せず、フォーム全体と必要最小限の依存文脈をLLMへ渡し、値ではなくLispコード一式を生成させる。")
   (:resolution-gate
    "oracle生成コードは全演算子と参照値を決定論的評価器が解決できる場合だけLLM禁止状態で実行し、それ以外は不活性なintermediate-codeとして保持する。")
   (:explicit-lowering-control
    "llm、pure、fix、re-fixにより強制lowering、禁止、単一中間結果の修復、値木全体の再帰修復を選択できる。")
   (:dependency-context
    "oracle文脈は対象と囲みフォームが参照する束縛、関数・マクロ定義、docstring、明示依存を含み、必要時だけファイル全体へ拡張できる。")
   (:read-only-exploration
    "ファイル実行のagentic oracleはプロジェクトルートから関連ファイルを読めるが、書き込みや外部MCPを許可せず、no-exploreで探索を無効化できる。")
   (:persistent-oracle-cache
    "キャッシュキーはprompt版、model、完成promptにより決まり、値でなく生成コードをプロジェクトの.allisp/oracleへ保存し、同一実行条件では再問い合わせせず再評価する。")
   (:errors-as-values
    "通常モードではフォーム失敗をtype、form、detailを持つerror値としてresultへ残し後続を続行し、strictでは最初の失敗で停止し、いずれも失敗時は非0終了する。")
   (:safe-lisp1-core
    "独自readerとメタ循環評価器はCommon Lispに近いS式、Unicode symbol、全角空白、quote系、クロージャ、マクロ、高階関数を扱い、CL全体は公開せずallowlist builtinだけを公開する。")
   (:file-namespace
    "各入力ファイルは新しい環境で独立実行し、@useは呼出元相対のallisp sourceまたはresultを一度だけ読み、定義と復元可能な値を取り込む。")
   (:explicit-file-generation
    "generate-fileはbodyの値を呼出元相対パスへ生成し、source自身を上書きせず、dry-runでは書かず、Lispにはprovenanceを、非Lispには文字列だけを生テキストで書く。")
   (:cli-surface
    "CLIは単一file、directory一括、one-liner、result diff、spec statusを提供し、共通optionを一貫して適用し、成功0、検出差分または実行失敗1、usage error 2、内部・構文失敗3を返す。")
   (:deterministic-result-diff
    "diffはdef-familyを定義名、exampleをspec名とexample名、その他をフォームで対応付け、changed、added、removedをS式で出力しLLMを呼ばない。")
   (:deterministic-logic-search
    "goal、constraint、solveはlogic variable、unification、rule、決定論的constraintを用いて全解を探索し、必要ならtop-levelのgoalだけをloweringする。rule本体にネストした未束縛goalはその探索枝を失敗にする。")
   (:managed-memory-init
    "具体lowering用managed memoryは32または64bit整数配列と初期化bitmapを持ち、write前readを拒否し、externalize時も生contentsを読まない。")
   (:markdown-to-program
    "markdown->lispはfileまたはtextのMarkdownを単一prognのフォーム列へ変換し、既定では実行せず、任意のlisp出力と明示evalを提供する。")
   (:spec-as-data
    "defspecは条項を未評価データとしてschema検査し束縛し、exampleは同一fileの先行defspecへ一意名、in、out、規範context、任意coversとdepends-onをappendする。")
   (:spec-example-consistency
    "check-specは各invariantと各example contextを再利用可能な決定論的predicateへ個別loweringしin/outへ適用し、違反、skip、lowering errorを区別する。")
   (:active-hole-probe
    "probe-specは仕様全体についてinvariant間、context間、両者間、未規定領域、観測不能条件、不当依存を監査し、完全性とevidence-backed findingを不活性データで返す。")
   (:proof-before-derive
    "deriveは対象specと推移spec依存について現在のevaluator、prompt、model、spec hashに一致するcheck成功と完全でfindingなしのprobeを要求し、viaの評価値がresolution gateを通過した場合だけ生成とledger更新を行う。明示ignore-skip以外でskipを通さない。")
   (:derivative-freshness
    "spec statusはLLMなしでledger、source spec、依存、proof metadata、target bytesを検査し、fresh、stale、drifted、missing、invalid、unknownを区別して注意対象があれば終了1にする。")
   (:explicit-external-verification
    "verifyフォームは評価時には登録だけを行い、runのverify flag下で全生成後に外部commandを順番に実行し、結果をresultへ埋め、同一bytesのledger targetだけをverifiedとして刻む。")
   (:trusted-plugin-load
    "pluginはGit URLと任意revisionからproject cacheへ取得し、data-only manifestが指定するASDF systemをtrusted host codeとしてloadしてsyntax macroを登録する。")
   (:regression-and-buildability
    "処理系はASDF systemとして構築でき、外部allisp sourceなしで自動testが完走し、公開機能と失敗境界をtestで固定する。")))

;; ---------------------------------------------------------------------------
;; Acceptance criteria as examples.  :context is not commentary; it is the
;; normative condition that decides whether the observable applies.  Clauses
;; that silently assumed a mode, a flag or a phase now say so, and probe-spec
;; audits those conditions against each other.
;; ---------------------------------------------------------------------------

(example allisp :name :ac-sexp-result
  :in (:given "有効なallispファイル" :when "runで実行する")
  :out "各トップレベルフォームとその値を対応付けたresultを生成する"
  :context "ファイル実行モードで評価が最後まで到達した場合に観測する。one-liner実行はresultもtraceも書かない。"
  :covers (:sexp-source-of-truth))
(example allisp :name :ac-sexp-trace
  :in (:given "LLM呼び出しを含む実行" :when "実行が完了する")
  :out "各呼び出しの入力、生成コード、実行状態、値をtraceへ記録する"
  :context "ファイル実行モードで、キャッシュヒットした呼び出しも記録対象に含む。"
  :covers (:sexp-source-of-truth :persistent-oracle-cache))

(example allisp :name :ac-no-oracle-when-bound
  :in (:given "定義済み演算だけのフォーム" :when "評価する")
  :out "oracle呼び出し数は0である"
  :context "全ての演算子と参照値が特殊形式、allowlist builtin、または現在の環境の束縛で解決できる場合に限る。"
  :covers (:deterministic-first))
(example allisp :name :ac-pure-unbound
  :in (:given "pure内の未束縛フォーム" :when "評価する")
  :out "oracleを呼ばず第一級error値になる"
  :context "pureは動的な禁止であり、内側の全ての評価に及ぶ。"
  :covers (:deterministic-first :explicit-lowering-control))
(example allisp :name :ac-pure-blocks-llm
  :in (:given "pure内でllmに包まれたフォーム" :when "評価する")
  :out "oracleを呼ばず第一級error値になる"
  :context "pureの動的な禁止はllmによる強制loweringより優先する。"
  :covers (:deterministic-first :explicit-lowering-control))

(example allisp :name :ac-normal-order-oracle
  :in (:given "未束縛演算子と評価不能な引数" :when "通常評価する")
  :out "引数評価エラーではなくフォーム全体がoracle対象になる"
  :context "pureの外で、llmによる明示指定がない通常の評価経路で観測する。"
  :covers (:lower-unbound-to-code))
(example allisp :name :ac-single-form-response
  :in (:given "oracle応答" :when "受理する")
  :out "任意のcode fenceと先行proseを寛容に除去した後も単一S式だけを受理し、複数フォームは拒否する"
  :context "除去は応答の包装だけに及び、S式本体は書き換えない。拒否は再試行の対象になる。"
  :covers (:lower-unbound-to-code))
(example allisp :name :ac-effect-position
  :in (:given "効果位置に未束縛フォームがある" :when "評価する")
  :out "意味を保持する最も近い値位置の囲みフォームを一度だけloweringする"
  :context "値が捨てられる位置ではフォーム単体の意味が保存されないため、囲みごと送る。同一の囲みは複数の未束縛フォームを含んでも一度だけ送る。"
  :covers (:lower-unbound-to-code :dependency-context))

(example allisp :name :ac-gate-executed
  :in (:given "全参照を解決できる生成コード" :when "materializeする")
  :out "pure相当で実行しstatusをexecutedにする"
  :context "解決可能性は生成コードに現れる全ての演算子と参照値について判定し、実行中の再loweringは禁止する。"
  :covers (:resolution-gate))
(example allisp :name :ac-gate-intermediate
  :in (:given "未解決演算を含む生成コード" :when "materializeする")
  :out "実行せずwhyとhowを持つintermediate-codeにする"
  :context "一つでも未解決の演算子があれば実行しない。部分実行は行わない。"
  :covers (:resolution-gate))
(example allisp :name :ac-no-fabricated-effect
  :in (:given "メモリ変更、ファイル変更、通信、配備などの未実装効果" :when "oracleがコードを返す")
  :out "効果の成功を値として捏造しない"
  :context "LLMはコード生成だけを担い、効果の実行主体にならない。効果を表すには決定論的builtinか明示的な外部verificationを経由する。"
  :covers (:resolution-gate :lower-unbound-to-code))

(example allisp :name :ac-force-llm
  :in (:given "定義済みフォームをllmで包む" :when "評価する")
  :out "oracleへ送る"
  :context "llmは決定論的に解決できるフォームであってもloweringを強制する。"
  :covers (:explicit-lowering-control))
(example allisp :name :ac-fix-audit-record
  :in (:given "intermediate-code" :when "fixまたはre-fixする")
  :out "導入仮定をcodeに明示したfixed監査レコードを返す"
  :context "Fixモードは不足する前提を既定値で埋めてよいが、埋めた仮定は生成コード内の束縛として現れ、散文に隠れてはならない。"
  :covers (:explicit-lowering-control))
(example allisp :name :ac-fix-rounds-exhausted
  :in (:given "解決しない修復" :when "rounds上限へ達する")
  :out "最後のintermediate-codeを保持して停止する"
  :context "上限はfixでは呼び出し単位、re-fixでは値木のノード単位で数える。"
  :covers (:explicit-lowering-control))

(example allisp :name :ac-context-stability
  :in (:given "無関係な束縛だけを変更する" :when "同じフォームを再実行する")
  :out "そのフォームのoracleキャッシュキーは変わらない"
  :context "文脈同梱は参照関係から決まり、ファイル全体には及ばない。この安定性はcontext file指定がない場合に限る。"
  :covers (:dependency-context :persistent-oracle-cache))
(example allisp :name :ac-context-file
  :in (:given "llmにcontext fileを指定する" :when "promptを構築する")
  :out "現在の入力ファイル全体を文脈に含める"
  :context "明示指定された場合はキャッシュ安定性より文脈の広さを優先する。ファイルのどの編集もキーを変える。"
  :covers (:dependency-context))
(example allisp :name :ac-context-file-one-liner
  :in (:given "one-liner内でllmにcontext fileを指定する" :when "promptを構築する")
  :out "usage errorとして終了2にする"
  :context "one-linerは入力ファイルを持たないため、:context :fileを解決・代替・無視しない。"
  :covers (:dependency-context :cli-surface))

(example allisp :name :ac-claude-readonly-tools
  :in (:given "claude backendのagentic実行" :when "CLI引数を作る")
  :out "Read、Glob、Grepだけを許可しMCP設定を遮断する"
  :context "ファイル実行モードで探索が有効な場合に限る。許可リスト外の書き込み系ツールは非対話モードで自動拒否される。"
  :covers (:read-only-exploration))
(example allisp :name :ac-codex-readonly-sandbox
  :in (:given "codex backendのagentic実行" :when "CLI引数を作る")
  :out "read-only sandboxとephemeral実行を指定する"
  :context "backendが違っても読み取り専用という境界は同一でなければならない。"
  :covers (:read-only-exploration))
(example allisp :name :ac-no-explore
  :in (:given "no-explore" :when "実行する")
  :out "探索用Environment文脈をpromptへ含めない"
  :context "探索の有無はpromptを変えるため、キャッシュキーは自然に分かれる。one-linerはソースファイルを持たないため常にこの形になる。"
  :covers (:read-only-exploration :persistent-oracle-cache))

(example allisp :name :ac-cache-replay
  :in (:given "同一prompt版、model、promptのキャッシュ" :when "再実行する")
  :out "LLM呼び出し0で同じcodeを決定論的にmaterializeする"
  :context "リプレイは保存された生成コードを現在の決定論的環境で再評価する。保存されているのは値ではない。"
  :covers (:persistent-oracle-cache))
(example allisp :name :ac-cache-refresh
  :in (:given "refreshまたはfresh" :when "再実行する")
  :out "既存キャッシュを使わずoracleへ問い合わせる"
  :context "fresh呼び出しは呼び出し時点のリポジトリ状態を反映するため、探索が有効なら結果は決定論的でない。"
  :covers (:persistent-oracle-cache :read-only-exploration))
(example allisp :name :ac-cache-corrupt
  :in (:given "壊れたキャッシュエントリ" :when "読む")
  :out "コードとして実行せずcache missとして安全に扱う"
  :context "キャッシュは信頼できない入力として扱う。読めない内容を成功として素通しすることは許さない。"
  :covers (:persistent-oracle-cache))

(example allisp :name :ac-partial-evaluation
  :in (:given "複数フォームの途中で失敗する" :when "strictなしでrunする")
  :out "error値を記録し後続フォームも評価する"
  :context "既定モード。成功部分はキャッシュ済みなので、再実行は失敗箇所だけを再問い合わせする。"
  :covers (:errors-as-values))
(example allisp :name :ac-strict-halt
  :in (:given "同じ入力" :when "strictでrunする")
  :out "最初の失敗後のフォームを評価しない"
  :context "strictはファイル単位でもディレクトリ一括でも同じ意味を持ち、バッチでは残りのファイルも実行しない。"
  :covers (:errors-as-values :cli-surface))

(example allisp :name :ac-read-print-roundtrip
  :in (:given "readerで読んだフォーム" :when "printして再読する")
  :out "同値なフォームになる"
  :context "readtableはinvertであり、小文字ソースは小文字のまま往復する。全角空白は空白として読む。"
  :covers (:safe-lisp1-core))
(example allisp :name :ac-lisp1-application
  :in (:given "変数位置の関数値" :when "mapcar等へ渡す")
  :out "Lisp-1として適用できる"
  :context "関数と変数の名前空間は単一である。"
  :covers (:safe-lisp1-core))
(example allisp :name :ac-allowlist-boundary
  :in (:given "allowlist外のCL関数名" :when "評価する")
  :out "host関数を直接実行せず未束縛経路へ入る"
  :context "ホスト処理系の全機能が露出しないことが、未束縛検出とoracle境界の前提になる。"
  :covers (:safe-lisp1-core :deterministic-first))

(example allisp :name :ac-use-idempotent
  :in (:given "同じファイルを複数回@useする" :when "一回のrun内で評価する")
  :out "実ファイルの評価は一度だけである"
  :context "冪等性は一回のrunの中で成立する。別のrunは新しい環境から始まる。"
  :covers (:file-namespace))
(example allisp :name :ac-result-replay
  :in (:given "result v2以降のdef-family値" :when "@useする")
  :out "元フォームを再評価せず名前と値を復元する"
  :context "リプレイはoracle呼び出し0で行う。version記録のない旧形式は値を持たないため復元しない。"
  :covers (:file-namespace :sexp-source-of-truth))
(example allisp :name :ac-externalized-object
  :in (:given "externalizeされたhost object" :when "resultを@useする")
  :out "実物として再束縛しない"
  :context "クロージャやmanaged memoryはresultへ実体を残さないため、復元できるのは記述だけである。"
  :covers (:file-namespace :managed-memory-init))

(example allisp :name :ac-generate-lisp-target
  :in (:given "lisp target" :when "生成する")
  :out "generated-by markerと再読可能な値を書く"
  :context "生成先が.lispかつsourceと異なる実体の場合に限る。source自身を指すtargetは自己上書きとして拒否する。provenanceは生成元ファイル、元フォーム、生成時刻を含む。"
  :covers (:explicit-file-generation))
(example allisp :name :ac-generate-non-lisp-target
  :in (:given "非lisp targetと非文字列値" :when "生成する")
  :out "error値にして実行可能または解析対象ファイルへS式を混入しない"
  :context "非.lispターゲットは値を文字列に限り、コメント不可形式のためヘッダを埋め込まない。生成記録はtraceに残る。"
  :covers (:explicit-file-generation))
(example allisp :name :ac-generate-self-overwrite
  :in (:given "sourceと同じ実体を指すtarget" :when "生成する")
  :out "上書きを拒否する"
  :context "判定はパス文字列ではなく実体で行う。"
  :covers (:explicit-file-generation))

(example allisp :name :ac-cli-directory
  :in (:given "directory" :when "runする")
  :out "直下のlispだけをresultとtraceを除外して辞書順に独立実行する"
  :context "サブディレクトリは対象外である。生成物が置かれる場所を再帰すると生成物をソースとして誤実行するため。各ファイルは独自の環境を持つ。"
  :covers (:cli-surface :file-namespace))
(example allisp :name :ac-cli-one-liner
  :in (:given "one-liner" :when "複数フォームを実行する")
  :out "最後の値だけをstdoutへS式表示しresultとtraceを書かない"
  :context "one-linerはソースファイルを持たないため、探索用Environment文脈も持たない。"
  :covers (:cli-surface))
(example allisp :name :ac-cli-out-dir
  :in (:given "out-dir" :when "fileまたはdirectoryをrunする")
  :out "resultとtraceの出力先を変更する"
  :context "ディレクトリ一括でも全ファイル共通の出力先になる。出力パスが衝突した場合は実行順で後のファイルが上書きする。指定がなければ各ファイル自身のoutputへ書く。"
  :covers (:cli-surface))
(example allisp :name :ac-cli-directory-syntax-error
  :in (:given "構文エラーを含むファイルがあるdirectory" :when "strictなしでrunする")
  :out "他ファイルを継続実行し、バッチ全体を通常の実行失敗として終了1にする"
  :context "構文エラーは当該ファイルの失敗として記録する。単一ファイル実行時の終了3規則はディレクトリ一括へは適用しない。"
  :covers (:cli-surface :errors-as-values))
(example allisp :name :ac-cli-usage-error
  :in (:given "command不足または未知command" :when "CLIを起動する")
  :out "usageを表示して終了2にする"
  :context "引数の誤りは実行失敗と区別する。"
  :covers (:cli-surface))
(example allisp :name :ac-cli-internal-error
  :in (:given "option、入力構文、内部処理の例外" :when "CLI最上位へ到達する")
  :out "診断を表示して終了3にする"
  :context "単一ファイル実行では構文エラーはここへ伝播する。ディレクトリ一括ではファイル単位の失敗として捕捉し、他ファイルの実行を妨げない。"
  :covers (:cli-surface :errors-as-values))

(example allisp :name :ac-diff-changed
  :in (:given "異なるresult二つ" :when "diffする")
  :out "差分ごとの構造化S式を出し終了1にする"
  :context "対応付けは名前優先であり、前提編集でフォーム自体が変わっても定義名で追跡できる。LLMは関与しない。"
  :covers (:deterministic-result-diff))
(example allisp :name :ac-diff-identical
  :in (:given "同一result" :when "diffする")
  :out "差分なしで終了0にする"
  :context "終了コードはdiff(1)の規約に従う。"
  :covers (:deterministic-result-diff))

(example allisp :name :ac-solve-all-solutions
  :in (:given "有限なfact、rule、constraint" :when "solveする")
  :out "条件を満たす全てのreified解を返す"
  :context "探索は深さ優先で、解の順序は規則と事実の登録順に従う。"
  :covers (:deterministic-logic-search))
(example allisp :name :ac-solve-pure-constraint
  :in (:given "未束縛演算を含むconstraint" :when "pureなlogic searchで評価する")
  :out "外部効果を実行しない"
  :context "決定論的に評価できない制約は、その探索枝を失敗させるだけで、oracleへは送らない。"
  :covers (:deterministic-logic-search :deterministic-first))
(example allisp :name :ac-solve-nested-goal
  :in (:given "rule本体に未束縛演算を含むネストしたgoal" :when "solveする")
  :out "oracleへ送らずその探索枝を失敗にする"
  :context "lowering対象は呼出し側が明示したtop-levelのgoalだけである。ネストしたgoalを後で実行したい場合は、quoteでデータとして返し、top-level goalとして明示的に再投入する。"
  :covers (:deterministic-logic-search :deterministic-first))

(example allisp :name :ac-memory-uninitialized-read
  :in (:given "未初期化block要素" :when "readする")
  :out "host errorをerror値化し値を返さない"
  :context "初期化済みかどうかはbitmapで判定する。既定値を返す解釈は許さない。"
  :covers (:managed-memory-init))
(example allisp :name :ac-memory-externalize
  :in (:given "blockをresultへexternalizeする" :when "記録する")
  :out "型、幅、長さ、初期化数、process内寿命だけを残す"
  :context "contentsは読まない。resourceの寿命は現在のprocessに限られ、resultから復元できない。"
  :covers (:managed-memory-init))

(example allisp :name :ac-markdown-structured
  :in (:given "Markdown source" :when "変換する")
  :out "散文の言い換えでなく構造化allispフォーム列を返す"
  :context "既存の構文と型を最優先し、捉えられないドメイン構造には小さな宣言的DSLを設計する。一意に変換できない文書はintermediate-codeになる。"
  :covers (:markdown-to-program))
(example allisp :name :ac-markdown-out-guard
  :in (:given "non-lisp outまたはsource自身" :when "出力する")
  :out "書込みを拒否する"
  :context "入力元と出力先の評価はpure相当であり、未束縛はoracleへ送らず即error値にする。"
  :covers (:markdown-to-program :explicit-file-generation))
(example allisp :name :ac-markdown-no-eval
  :in (:given "eval指定なし" :when "変換する")
  :out "生成フォームを実行しない"
  :context "既定では生成物をプログラムとして保持する。traceのstatusはgeneratedになる。"
  :covers (:markdown-to-program :resolution-gate))

(example allisp :name :ac-defspec-schema
  :in (:given "重複またはmalformed clause" :when "defspecする")
  :out "決定論的error値にして仕様を束縛しない"
  :context "schema検査にoracleは関与しない。壊れた仕様の上に派生物が積み上がることを防ぐため、部分的な束縛も行わない。"
  :covers (:spec-as-data))
(example allisp :name :ac-example-identity
  :in (:given "duplicate example名またはinline examples" :when "定義する")
  :out "拒否する"
  :context "identityはspec内のexample名だけである。同一入力で内容の異なる実例は、名前が違えば登録できる。"
  :covers (:spec-as-data))
(example allisp :name :ac-example-depends-on
  :in (:given "depends-on" :when "exampleを登録する")
  :out "同一file先行定義だけを許可し循環を拒否して推移closureをhash対象にする"
  :context "plugin binding依存とdefspec循環は認めない。依存先がdefspecなら証明も再帰的に必要になる。"
  :covers (:spec-as-data :proof-before-derive))

(example allisp :name :ac-check-clause-cache
  :in (:given "単一invariantを編集する" :when "checkを再実行する")
  :out "そのinvariant predicateだけを再loweringする"
  :context "predicateのpromptには当該条項とsignatureしか入らないため、粒度は条項単位になる。実例の追加と編集はLLM呼び出し0で再検査される。"
  :covers (:spec-example-consistency :persistent-oracle-cache))
(example allisp :name :ac-check-skip
  :in (:given "一組のin/outで判定不能な要件" :when "checkする")
  :out "弱い判定へ近似せずskippedに理由を残す"
  :context "冪等性のように単一の(in, out)では決まらない条項が該当する。skipの検証は生成されたtestに対するverifyが受け持つ。"
  :covers (:spec-example-consistency))
(example allisp :name :ac-check-violation
  :in (:given "predicateが偽になるexample" :when "checkする")
  :out "invariantまたはcontextとexampleを名指すspec-violationにする"
  :context "実例を伴わない条項間の矛盾はcheckでは現れない。その検出はprobeが担う。"
  :covers (:spec-example-consistency :active-hole-probe))

(example allisp :name :ac-probe-clean
  :in (:given "監査を完了し穴がない仕様" :when "probeする")
  :out "complete tかつfinding 0を返す"
  :context "completeは監査そのものを完了できたかを表し、findingの有無とは独立である。判定不能はcomplete nilになる。"
  :covers (:active-hole-probe))
(example allisp :name :ac-probe-finding
  :in (:given "矛盾または未規定領域" :when "probeする")
  :out "関係条項をwhyに、具体的修正をhowに持つfindingを返す"
  :context "findingは不活性データであり実行しない。キャッシュ粒度は仕様全体であり、どの条項の編集も再探索を要する。"
  :covers (:active-hole-probe :resolution-gate))
(example allisp :name :ac-probe-focus
  :in (:given "focus付きprobe" :when "実行する")
  :out "部分監査としてderive証明には使わない"
  :context "focusは監査節へ入るためキャッシュキーが分かれる。部分監査は仕様全体について何も保証しない。"
  :covers (:active-hole-probe :proof-before-derive))

(example allisp :name :ac-derive-blocked
  :in (:given "checkまたはfull probeがない、古い、失敗した仕様" :when "deriveする")
  :out "生成とledger更新を行わずproof blockerを返す"
  :context "証明はevaluator、prompt、model、spec hashの完全一致で判定する。違反、probe finding、監査未完了は回避できない。"
  :covers (:proof-before-derive))
(example allisp :name :ac-derive-requires-resolution
  :in (:given "intermediate-codeになるvia評価値" :when "deriveする")
  :out "生成とledger更新を行わずproof blockerを返す"
  :context "checkと完全でfindingなしのprobeが揃っていても、未解決値を正式な派生物として記録しない。未解決内容はresultまたはtraceに残す。"
  :covers (:proof-before-derive :resolution-gate))
(example allisp :name :ac-derive-ignore-skip
  :in (:given "checkがskipだけでprobeはclean" :when "ignore-skipを明示してderiveする")
  :out "無視したskipをproofへ記録する"
  :context "skipを通す経路は明示flagだけであり、無視した事実は後から検査できる形で残る。"
  :covers (:proof-before-derive))
(example allisp :name :ac-derive-ledger
  :in (:given "成功したderive" :when "完了する")
  :out "spec、依存、proof、via、target hashをledgerへ記録する"
  :context "書き出しの挙動、dry-run、非lispターゲットの文字列規約はgenerate-fileと同一である。"
  :covers (:proof-before-derive :explicit-file-generation))

(example allisp :name :ac-status-stale
  :in (:given "specまたは宣言依存を変更する" :when "statusを実行する")
  :out "該当targetをstaleにする"
  :context "条項が未評価データであるため、鮮度判定はソースの再読とhashだけで決まり評価を要さない。LLM呼び出しは0である。"
  :covers (:derivative-freshness :spec-as-data))
(example allisp :name :ac-status-drifted
  :in (:given "生成後のtargetを手編集する" :when "statusを実行する")
  :out "driftedにする"
  :context "手編集した内容は仕様側の条項として書き直す必要がある。再生成で消えるため。"
  :covers (:derivative-freshness))
(example allisp :name :ac-status-unreadable
  :in (:given "ledgerが存在するが読めない、またはproof metadataが現処理系と非互換" :when "statusを実行する")
  :out "成功扱いにせずinvalidまたはunknownとして終了1にする"
  :context "読めないledgerを空のledgerとして扱うことは、証明のない派生物をgateに通す。存在しないledgerとは区別する。"
  :covers (:derivative-freshness :proof-before-derive))

(example allisp :name :ac-verify-inert
  :in (:given "verify flagなし" :when "runする")
  :out "commandを実行せずpending recordを返す"
  :context "評価はレコードの登録だけを行う。外部commandの起動はCLI層の明示flagが担う。"
  :covers (:explicit-external-verification :resolution-gate))
(example allisp :name :ac-verify-failed
  :in (:given "期待exitと異なるcommand" :when "verify flag付きでrunする")
  :out "verification-failed error値と非0終了を返す"
  :context "実行は全フォームの評価と全ファイル生成の後、result書き出しの前に、登録順で行う。strictでは最初の失敗で残りをskippedにして打ち切る。"
  :covers (:explicit-external-verification :errors-as-values))
(example allisp :name :ac-verify-drifted-target
  :in (:given "手編集されたtargetへの成功command" :when "ledgerを更新する")
  :out "verified stampを付けない"
  :context "編集済みファイルに対する検証は仕様について何も証明しないため。"
  :covers (:explicit-external-verification :derivative-freshness))

(example allisp :name :ac-plugin-manifest
  :in (:given "manifest" :when "読む")
  :out "read-evalを無効化しstringのsystemとasdだけを受理する"
  :context "manifestはデータであり、読み取りが実行になってはならない。"
  :covers (:trusted-plugin-load))
(example allisp :name :ac-plugin-revision
  :in (:given "revision指定" :when "取得する")
  :out "detached checkoutし失敗した一時cloneをcache完成物として扱わない"
  :context "cacheへの昇格は取得が完全に成功した場合に限る。"
  :covers (:trusted-plugin-load))
(example allisp :name :ac-plugin-unpinned
  :in (:given "pluginが未固定" :when "利用する")
  :out "remote HEADへ追随する危険が利用者に明示される"
  :context "pluginはtrusted host codeとしてloadされるため、allowlist builtinの境界の外にある。"
  :covers (:trusted-plugin-load :safe-lisp1-core))

(example allisp :name :ac-tests-self-contained
  :in (:given "supported Common Lisp環境と依存" :when "make testを実行する")
  :out "全testが成功する"
  :context "testは外部のallisp sourceファイルを必要とせず完走する。"
  :covers (:regression-and-buildability))
(example allisp :name :ac-single-entrypoint
  :in (:given "CLI実行ファイル" :when "buildまたはRoswell scriptで起動する")
  :out "同じallisp systemとentrypointを使う"
  :context "起動経路が違ってもCLIの意味は同一でなければならない。"
  :covers (:regression-and-buildability :cli-surface))

;; ---------------------------------------------------------------------------
;; Design model.  Traceability now points at invariant names, so the
;; deterministic check below can resolve every reference against the spec.
;; ---------------------------------------------------------------------------

(def allisp-design
  '(:architecture :staged-interpreter
    :principles
    ((:id :DES-001 :name "実行主体の分離"
      :decision "LLMはコード生成だけを担当し、allisp evaluatorまたは明示external verifierだけが実行する。"
      :requirements (:deterministic-first :lower-unbound-to-code :resolution-gate
                     :explicit-external-verification))
     (:id :DES-002 :name "再生可能性"
      :decision "source、prompt、model、生成code、evaluator semanticsを識別し、同一条件はcacheから再評価する。"
      :requirements (:sexp-source-of-truth :dependency-context :persistent-oracle-cache
                     :proof-before-derive :derivative-freshness))
     (:id :DES-003 :name "仕様中心の派生"
      :decision "spec、example、dependencyを正本とし、checkとprobeのproofを通った派生物だけをledger管理する。"
      :requirements (:spec-as-data :spec-example-consistency :active-hole-probe
                     :proof-before-derive :derivative-freshness
                     :explicit-external-verification))
     (:id :DES-004 :name "失敗の可視化"
      :decision "曖昧さはintermediate-code、実行失敗はerror、仕様穴はspec-findings、外部失敗はverification-failedとしてS式に残す。"
      :requirements (:resolution-gate :explicit-lowering-control :errors-as-values
                     :spec-example-consistency :active-hole-probe
                     :explicit-external-verification))
     (:id :DES-005 :name "最小権限"
      :decision "deterministic builtinをallowlist化し、oracle探索をread-onlyにし、効果は明示構文とCLI flagへ隔離する。"
      :requirements (:resolution-gate :read-only-exploration :safe-lisp1-core
                     :explicit-file-generation :explicit-external-verification
                     :trusted-plugin-load)))

    :components
    ((:id :CMP-READER :path "src/reader.lisp"
      :responsibility "allisp readtable、正規化、S式read/print"
      :requirements (:sexp-source-of-truth :safe-lisp1-core))
     (:id :CMP-ENV :path "src/env.lisp"
      :responsibility "Lisp-1 lexical environment、run state、error値"
      :requirements (:deterministic-first :errors-as-values :safe-lisp1-core
                     :file-namespace))
     (:id :CMP-EVAL :path "src/eval.lisp"
      :responsibility "特殊形式、staging、依存文脈、top-level goalだけのlogic lowering、生成、deriveの解決性gate、spec forms"
      :requirements (:deterministic-first :lower-unbound-to-code :resolution-gate
                     :explicit-lowering-control :dependency-context
                     :file-namespace :explicit-file-generation
                     :deterministic-logic-search :markdown-to-program
                     :spec-as-data :spec-example-consistency :active-hole-probe
                     :proof-before-derive :explicit-external-verification))
     (:id :CMP-BUILTINS :path "src/builtins.lisp"
      :responsibility "deterministic allowlist、高階関数、managed memory、spec accessor"
      :requirements (:deterministic-first :safe-lisp1-core :managed-memory-init
                     :spec-as-data))
     (:id :CMP-BACKEND :path "src/backend.lisp"
      :responsibility "claude/codex CLI adapterとread-only探索境界"
      :requirements (:lower-unbound-to-code :read-only-exploration))
     (:id :CMP-CACHE :path "src/cache.lisp"
      :responsibility "oracle cache key用hash、永続code cache、timestamp"
      :requirements (:persistent-oracle-cache))
     (:id :CMP-SPEC :path "src/spec.lisp"
      :responsibility "spec schema補助、dependency hash、derive ledger、status、verification executor"
      :requirements (:spec-as-data :proof-before-derive :derivative-freshness
                     :explicit-external-verification))
     (:id :CMP-DIFF :path "src/diff.lisp"
      :responsibility "resultの安定対応付けと構造化差分"
      :requirements (:deterministic-result-diff))
     (:id :CMP-PLUGIN :path "src/plugin.lisp"
      :responsibility "trusted syntax plugin取得、manifest検査、ASDF load"
      :requirements (:trusted-plugin-load))
     (:id :CMP-RUNNER :path "src/runner.lisp"
      :responsibility "file/directory/one-liner lifecycle、one-linerのfile context拒否、result/trace、共有out-dirの上書き順、verification timing"
      :requirements (:sexp-source-of-truth :read-only-exploration :errors-as-values
                     :file-namespace :cli-surface :explicit-external-verification))
     (:id :CMP-CLI :path "src/cli.lisp"
      :responsibility "command routing、option、one-linerのcontext file usage error、directory構文エラーを含むexit status"
      :requirements (:cli-surface :deterministic-result-diff :derivative-freshness
                     :explicit-external-verification))
     (:id :CMP-TESTS :path "tests/main.lisp"
      :responsibility "言語、staging、spec workflow、CLI境界の回帰test"
      :requirements (:regression-and-buildability)))

    :data-flows
    ((:id :FLOW-EVAL
      :steps (:reader :environment :deterministic-evaluator
              :oracle-on-unbound :resolution-gate :result-and-trace)
      :requirements (:sexp-source-of-truth :deterministic-first
                     :lower-unbound-to-code :resolution-gate
                     :persistent-oracle-cache :errors-as-values))
     (:id :FLOW-SPEC
      :steps (:defspec :example :check-spec :probe-spec :derive
              :verify :spec-status)
      :requirements (:spec-as-data :spec-example-consistency :active-hole-probe
                     :proof-before-derive :derivative-freshness
                     :explicit-external-verification))
     (:id :FLOW-CHAIN
      :steps (:source-run :result-v3 :at-use :restored-bindings)
      :requirements (:file-namespace))
     (:id :FLOW-PLUGIN
      :steps (:git-fetch :detached-checkout :manifest-read :asdf-load
              :syntax-macro-install)
      :requirements (:trusted-plugin-load)))

    :compatibility
    ((:artifact :result :version 3
      :rule "古いversionは再評価せず、versionが保証する範囲だけ復元する。")
     (:artifact :derive-ledger :version 2
      :rule "legacy entryはproof不明としてunknownにする。")
     (:artifact :oracle-cache
      :version-key (:prompt-version :model :complete-prompt)
      :rule "evaluator意味変更時のcache互換性を明示的に判定できなければprompt版を更新する。"))

    :deferred
    ((:id :V2-REPL :item "REPLとwatch mode")
     (:id :V2-RENDER :item "resultからの汎用自然言語renderer")
     (:id :V2-MCP :item "MCP server化")
     (:id :V2-TRACE-FILES :item "oracleが探索したfile一覧のtrace記録"))))

(def implementation-scope
  '(:source-files
    ("allisp.asd" "Makefile" "bin/allisp"
     "src/package.lisp" "src/reader.lisp" "src/env.lisp"
     "src/backend.lisp" "src/cache.lisp" "src/plugin.lisp"
     "src/spec.lisp" "src/eval.lisp" "src/builtins.lisp"
     "src/diff.lisp" "src/runner.lisp" "src/cli.lisp")
    :test-files ("tests/main.lisp")
    :documentation
    ("README.md" "DESIGN.md" "docs/language.md"
     "docs/spec-driven.md" "docs/development.md")
    :exclude
    ("sample/output" "output" ".allisp/oracle" ".allisp/plugins"
     "dist" "V2 deferred items")))

(def audit-criteria
  '(:finding-kinds
    (:requirement-omission
     :design-omission
     :implementation-gap
     :test-gap
     :documentation-drift)
    :severities (:critical :high :medium :low)
    :rules
    ("Read the relevant implementation and tests before reporting a finding."
     "A requirement omission is externally observable behavior or a necessary safety/compatibility rule present in the product but absent from the invariant clauses of the allisp spec."
     "A design omission is an unassigned responsibility, missing boundary, missing failure policy, or incompatible data-flow decision not covered by allisp-design."
     "An implementation gap must cite an invariant clause name and concrete file plus line or function evidence."
     "A test gap requires implemented or required behavior for which no meaningful regression assertion exists."
     "Documentation drift requires two concrete contradictory claims or a claim contradicted by code."
     "Do not report deferred v2 work, style preferences, speculative vulnerabilities, or lack of comments."
     "Deduplicate findings by root cause and prefer the narrowest actionable repair."
     "Set :complete t when the requested repository inspection was completed; findings do not make the audit incomplete. Use nil only when evidence could not be inspected.")
    :return-shape
    (:implementation-audit
     :complete boolean
     :baseline (:command string :status symbol :checks integer)
     :coverage (:invariants integer :design-decisions integer
                :components integer)
     :findings
     ((:id symbol
       :kind symbol
       :severity symbol
       :invariant symbol-or-nil
       :design symbol-or-nil
       :evidence ((:path string :location string :observation string))
       :why string
       :how string)))))

;; ---------------------------------------------------------------------------
;; Deterministic self-check of the model.  No oracle.  Unlike the previous
;; shape-only check, every design reference and every :covers claim is now
;; resolved against the spec's own invariant names, and each invariant must be
;; exercised by at least one example.
;; ---------------------------------------------------------------------------

(def invariant-names (spec-invariants allisp))
(def spec-example-list (spec-examples allisp))
(def design-principles (get-property allisp-design :principles))
(def design-components (get-property allisp-design :components))
(def design-flows (get-property allisp-design :data-flows))
(def design-entries (append design-principles design-components design-flows))

(defun known-invariants? (references)
  (every (lambda (reference) (member reference invariant-names)) references))

(defun entry-references (entry)
  (get-property entry :requirements))

;; Non-destructive concatenation.  mapcan is nconc-based and would splice the
;; :covers and :requirements lists of the quoted model together in place,
;; corrupting the spec it is supposed to inspect.
(defun concat-lists (lists)
  (if (null lists)
      '()
      (append (car lists) (concat-lists (cdr lists)))))

(defun covered-invariants ()
  (concat-lists
   (mapcar (lambda (example) (get-property example :covers)) spec-example-list)))

(def uncovered-invariants
  (let ((covered (covered-invariants)))
    (filter (lambda (name) (not (member name covered))) invariant-names)))

(def undesigned-invariants
  (let ((referenced
          (concat-lists (mapcar (lambda (entry) (entry-references entry))
                                design-entries))))
    (filter (lambda (name) (not (member name referenced))) invariant-names)))

(def model-validation
  (let ((trace-valid
          (every (lambda (entry) (known-invariants? (entry-references entry)))
                 design-entries))
        (covers-valid
          (every (lambda (example)
                   (known-invariants? (get-property example :covers)))
                 spec-example-list))
        (every-invariant-exemplified (equal? uncovered-invariants '()))
        (every-invariant-designed (equal? undesigned-invariants '())))
    (list :model-validation
          :status
          (if (and trace-valid covers-valid
                   every-invariant-exemplified every-invariant-designed)
              :passed
              :failed)
          :invariants (length invariant-names)
          :examples (length spec-example-list)
          :design-principles (length design-principles)
          :components (length design-components)
          :checks
          (list :trace-valid trace-valid
                :covers-valid covers-valid
                :every-invariant-exemplified every-invariant-exemplified
                :every-invariant-designed every-invariant-designed)
          :uncovered uncovered-invariants
          :undesigned undesigned-invariants)))

;; ---------------------------------------------------------------------------
;; Active search for contradictions and unspecified regions.  One oracle call
;; over the whole spec: holes live in pairs of clauses, so the audit and its
;; cache key are deliberately whole-spec.  Findings are inert data.
;; ---------------------------------------------------------------------------

(def spec-holes (probe-spec allisp))

;; ---------------------------------------------------------------------------
;; Semantic conformance audit.  The operator is intentionally undefined:
;; allisp delegates this judgment to the read-only repository-exploring
;; oracle.  :context :file makes this complete self-spec the audit input.
;; ---------------------------------------------------------------------------

(def current-implementation-audit
  (llm
    (audit-current-allisp-implementation
      :metadata specification-metadata
      :spec allisp
      :design allisp-design
      :scope implementation-scope
      :criteria audit-criteria
      :baseline '(:command "make test"
                  :status :passed
                  :checks 424)
      :instruction
      "Inspect the repository at the current revision. Return quoted structured data matching :return-shape. Report only evidence-backed omissions or gaps; every finding must cite a path and function or line. Invariant and design omissions are first-class findings, not just implementation bugs.")
    :context :file))
