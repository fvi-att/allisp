;; allisp self specification
;;
;; This file is the canonical requirements and design model for allisp itself.
;; It is executable:
;;
;;   bin/allisp run designs/allisp.lisp
;;
;; The first audit is deterministic and checks the model's schema and
;; traceability.  The final form asks the read-only, repository-exploring
;; oracle to compare this model with the current implementation.  Its result
;; must be evidence-backed Lisp data, not a prose report.

(def specification-metadata
  '(:system allisp
    :kind :self-specification
    :version 1
    :status :normative
    :language :ja
    :sources ("README.md" "DESIGN.md" "docs/language.md"
              "docs/spec-driven.md" "docs/development.md")
    :implementation-root "."
    :test-command "make test"))

(def allisp-requirements
  '(
    (:id :REQ-001
     :title "S式を正本とする"
     :statement "allispは思考、要件、設計、処理をS式のトップレベルフォーム列として読み、評価結果も再読可能なS式として残す。"
     :acceptance
     ((:id :AC-001-1 :given "有効なallispファイル"
       :when "runで実行する"
       :then "各トップレベルフォームとその値を対応付けたresultを生成する")
      (:id :AC-001-2 :given "LLM呼び出しを含む実行"
       :when "実行が完了する"
       :then "各呼び出しの入力、生成コード、実行状態、値をtraceへ記録する"))
     :priority :must)

    (:id :REQ-002
     :title "決定論的評価を優先する"
     :statement "特殊形式、束縛済み関数・マクロ・値、許可済みbuiltinだけで解決できるフォームはLLMを呼ばずに評価する。"
     :acceptance
     ((:id :AC-002-1 :given "定義済み演算だけのフォーム"
       :when "評価する" :then "oracle呼び出し数は0である")
      (:id :AC-002-2 :given "pure内の未束縛フォーム"
       :when "評価する" :then "oracleを呼ばず第一級error値になる"))
     :priority :must)

    (:id :REQ-003
     :title "未束縛フォームをコードへloweringする"
     :statement "未束縛演算子のフォームは引数を先に評価せず、フォーム全体と必要最小限の依存文脈をLLMへ渡し、値ではなくLispコード一式を生成させる。"
     :acceptance
     ((:id :AC-003-1 :given "未束縛演算子と評価不能な引数"
       :when "通常評価する" :then "引数評価エラーではなくフォーム全体がoracle対象になる")
      (:id :AC-003-2 :given "oracle応答"
       :when "受理する" :then "任意のcode fenceと先行proseを寛容に除去した後も単一S式だけを受理し、複数フォームは拒否する")
      (:id :AC-003-3 :given "効果位置に未束縛フォームがある"
       :when "評価する" :then "意味を保持する最も近い値位置の囲みフォームを一度だけloweringする"))
     :priority :must)

    (:id :REQ-004
     :title "生成コードに実行ゲートを設ける"
     :statement "oracle生成コードは全演算子と参照値を決定論的評価器が解決できる場合だけLLM禁止状態で実行し、それ以外は不活性なintermediate-codeとして保持する。"
     :acceptance
     ((:id :AC-004-1 :given "全参照を解決できる生成コード"
       :when "materializeする" :then "pure相当で実行しstatusをexecutedにする")
      (:id :AC-004-2 :given "未解決演算を含む生成コード"
       :when "materializeする" :then "実行せずwhyとhowを持つintermediate-codeにする")
      (:id :AC-004-3 :given "メモリ変更、ファイル変更、通信、配備などの未実装効果"
       :when "oracleがコードを返す" :then "効果の成功を値として捏造しない"))
     :priority :must)

    (:id :REQ-005
     :title "lowering経路を明示制御できる"
     :statement "llm、pure、fix、re-fixにより強制lowering、禁止、単一中間結果の修復、値木全体の再帰修復を選択できる。"
     :acceptance
     ((:id :AC-005-1 :given "定義済みフォームをllmで包む"
       :when "評価する" :then "oracleへ送る")
      (:id :AC-005-2 :given "intermediate-code"
       :when "fixまたはre-fixする" :then "導入仮定をcodeに明示したfixed監査レコードを返す")
      (:id :AC-005-3 :given "解決しない修復"
       :when "rounds上限へ達する" :then "最後のintermediate-codeを保持して停止する"))
     :priority :must)

    (:id :REQ-006
     :title "依存文脈を追跡する"
     :statement "oracle文脈は対象と囲みフォームが参照する束縛、関数・マクロ定義、docstring、明示依存を含み、必要時だけファイル全体へ拡張できる。"
     :acceptance
     ((:id :AC-006-1 :given "無関係な束縛だけを変更する"
       :when "同じフォームを再実行する" :then "そのフォームのoracleキャッシュキーは変わらない")
      (:id :AC-006-2 :given "llmにcontext fileを指定する"
       :when "promptを構築する" :then "現在の入力ファイル全体を文脈に含める"))
     :priority :must)

    (:id :REQ-007
     :title "リポジトリ探索を読み取り専用にする"
     :statement "ファイル実行のagentic oracleはプロジェクトルートから関連ファイルを読めるが、書き込みや外部MCPを許可せず、no-exploreで探索を無効化できる。"
     :acceptance
     ((:id :AC-007-1 :given "claude backendのagentic実行"
       :when "CLI引数を作る" :then "Read、Glob、Grepだけを許可しMCP設定を遮断する")
      (:id :AC-007-2 :given "codex backendのagentic実行"
       :when "CLI引数を作る" :then "read-only sandboxとephemeral実行を指定する")
      (:id :AC-007-3 :given "no-explore"
       :when "実行する" :then "探索用Environment文脈をpromptへ含めない"))
     :priority :must)

    (:id :REQ-008
     :title "oracle応答を永続キャッシュする"
     :statement "キャッシュキーはprompt版、model、完成promptにより決まり、値でなく生成コードをプロジェクトの.allisp/oracleへ保存し、同一実行条件では再問い合わせせず再評価する。"
     :acceptance
     ((:id :AC-008-1 :given "同一prompt版、model、promptのキャッシュ"
       :when "再実行する" :then "LLM呼び出し0で同じcodeを決定論的にmaterializeする")
      (:id :AC-008-2 :given "refreshまたはfresh"
       :when "再実行する" :then "既存キャッシュを使わずoracleへ問い合わせる")
      (:id :AC-008-3 :given "壊れたキャッシュエントリ"
       :when "読む" :then "コードとして実行せずcache missとして安全に扱う"))
     :priority :must)

    (:id :REQ-009
     :title "エラーを値として扱い部分評価する"
     :statement "通常モードではフォーム失敗をtype、form、detailを持つerror値としてresultへ残し後続を続行し、strictでは最初の失敗で停止し、いずれも失敗時は非0終了する。"
     :acceptance
     ((:id :AC-009-1 :given "複数フォームの途中で失敗する"
       :when "strictなしでrunする" :then "error値を記録し後続フォームも評価する")
      (:id :AC-009-2 :given "同じ入力"
       :when "strictでrunする" :then "最初の失敗後のフォームを評価しない"))
     :priority :must)

    (:id :REQ-010
     :title "安全なLisp-1コアを提供する"
     :statement "独自readerとメタ循環評価器はCommon Lispに近いS式、Unicode symbol、全角空白、quote系、クロージャ、マクロ、高階関数を扱い、CL全体は公開せずallowlist builtinだけを公開する。"
     :acceptance
     ((:id :AC-010-1 :given "readerで読んだフォーム"
       :when "printして再読する" :then "同値なフォームになる")
      (:id :AC-010-2 :given "変数位置の関数値"
       :when "mapcar等へ渡す" :then "Lisp-1として適用できる")
      (:id :AC-010-3 :given "allowlist外のCL関数名"
       :when "評価する" :then "host関数を直接実行せず未束縛経路へ入る"))
     :priority :must)

    (:id :REQ-011
     :title "ファイル単位の名前空間と明示importを持つ"
     :statement "各入力ファイルは新しい環境で独立実行し、@useは呼出元相対のallisp sourceまたはresultを一度だけ読み、定義と復元可能な値を取り込む。"
     :acceptance
     ((:id :AC-011-1 :given "同じファイルを複数回@useする"
       :when "一回のrun内で評価する" :then "実ファイルの評価は一度だけである")
      (:id :AC-011-2 :given "result v2以降のdef-family値"
       :when "@useする" :then "元フォームを再評価せず名前と値を復元する")
      (:id :AC-011-3 :given "externalizeされたhost object"
       :when "resultを@useする" :then "実物として再束縛しない"))
     :priority :must)

    (:id :REQ-012
     :title "派生ファイル生成を明示化する"
     :statement "generate-fileはbodyの値を呼出元相対パスへ生成し、source自身を上書きせず、dry-runでは書かず、Lispにはprovenanceを、非Lispには文字列だけを生テキストで書く。"
     :acceptance
     ((:id :AC-012-1 :given "lisp target"
       :when "生成する" :then "generated-by markerと再読可能な値を書く")
      (:id :AC-012-2 :given "非lisp targetと非文字列値"
       :when "生成する" :then "error値にして実行可能または解析対象ファイルへS式を混入しない")
      (:id :AC-012-3 :given "sourceと同じ実体を指すtarget"
       :when "生成する" :then "上書きを拒否する"))
     :priority :must)

    (:id :REQ-013
     :title "CLI実行面を提供する"
     :statement "CLIは単一file、directory一括、one-liner、result diff、spec statusを提供し、共通optionを一貫して適用し、成功0、検出差分または実行失敗1、usage error 2、内部・構文失敗3を返す。"
     :acceptance
     ((:id :AC-013-1 :given "directory"
       :when "runする" :then "直下のlispだけをresultとtraceを除外して辞書順に独立実行する")
      (:id :AC-013-2 :given "one-liner"
       :when "複数フォームを実行する" :then "最後の値だけをstdoutへS式表示しresultとtraceを書かない")
      (:id :AC-013-3 :given "out-dir"
       :when "fileまたはdirectoryをrunする" :then "resultとtraceの出力先を変更する")
      (:id :AC-013-4 :given "command不足または未知command"
       :when "CLIを起動する" :then "usageを表示して終了2にする")
      (:id :AC-013-5 :given "option、入力構文、内部処理の例外"
       :when "CLI最上位へ到達する" :then "診断を表示して終了3にする"))
     :priority :must)

    (:id :REQ-014
     :title "result差分を決定論的に表示する"
     :statement "diffはdef-familyを定義名、exampleをspec名とexample名、その他をフォームで対応付け、changed、added、removedをS式で出力しLLMを呼ばない。"
     :acceptance
     ((:id :AC-014-1 :given "異なるresult二つ"
       :when "diffする" :then "差分ごとの構造化S式を出し終了1にする")
      (:id :AC-014-2 :given "同一result"
       :when "diffする" :then "差分なしで終了0にする"))
     :priority :must)

    (:id :REQ-015
     :title "制約探索を決定論的に行う"
     :statement "goal、constraint、solveはlogic variable、unification、rule、決定論的constraintを用いて全解を探索し、必要なら未束縛の大域goalだけをloweringする。"
     :acceptance
     ((:id :AC-015-1 :given "有限なfact、rule、constraint"
       :when "solveする" :then "条件を満たす全てのreified解を返す")
      (:id :AC-015-2 :given "未束縛演算を含むconstraint"
       :when "pureなlogic searchで評価する" :then "外部効果を実行しない"))
     :priority :should)

    (:id :REQ-016
     :title "managed memoryの未初期化readを防ぐ"
     :statement "具体lowering用managed memoryは32または64bit整数配列と初期化bitmapを持ち、write前readを拒否し、externalize時も生contentsを読まない。"
     :acceptance
     ((:id :AC-016-1 :given "未初期化block要素"
       :when "readする" :then "host errorをerror値化し値を返さない")
      (:id :AC-016-2 :given "blockをresultへexternalizeする"
       :when "記録する" :then "型、幅、長さ、初期化数、process内寿命だけを残す"))
     :priority :should)

    (:id :REQ-017
     :title "Markdownをallisp programへ変換する"
     :statement "markdown->lispはfileまたはtextのMarkdownを単一prognのフォーム列へ変換し、既定では実行せず、任意のlisp出力と明示evalを提供する。"
     :acceptance
     ((:id :AC-017-1 :given "Markdown source"
       :when "変換する" :then "散文の言い換えでなく構造化allispフォーム列を返す")
      (:id :AC-017-2 :given "non-lisp outまたはsource自身"
       :when "出力する" :then "書込みを拒否する")
      (:id :AC-017-3 :given "eval指定なし"
       :when "変換する" :then "生成フォームを実行しない"))
     :priority :should)

    (:id :REQ-018
     :title "仕様を第一級データとして定義する"
     :statement "defspecは条項を未評価データとしてschema検査し束縛し、exampleは同一fileの先行defspecへ一意名、in、out、規範context、任意coversとdepends-onをappendする。"
     :acceptance
     ((:id :AC-018-1 :given "重複またはmalformed clause"
       :when "defspecする" :then "決定論的error値にして仕様を束縛しない")
      (:id :AC-018-2 :given "duplicate example名またはinline examples"
       :when "定義する" :then "拒否する")
      (:id :AC-018-3 :given "depends-on"
       :when "exampleを登録する" :then "同一file先行定義だけを許可し循環を拒否して推移closureをhash対象にする"))
     :priority :must)

    (:id :REQ-019
     :title "仕様と実例の整合性を検査する"
     :statement "check-specは各invariantと各example contextを再利用可能な決定論的predicateへ個別loweringしin/outへ適用し、違反、skip、lowering errorを区別する。"
     :acceptance
     ((:id :AC-019-1 :given "単一invariantを編集する"
       :when "checkを再実行する" :then "そのinvariant predicateだけを再loweringする")
      (:id :AC-019-2 :given "一組のin/outで判定不能な要件"
       :when "checkする" :then "弱い判定へ近似せずskippedに理由を残す")
      (:id :AC-019-3 :given "predicateが偽になるexample"
       :when "checkする" :then "invariantまたはcontextとexampleを名指すspec-violationにする"))
     :priority :must)

    (:id :REQ-020
     :title "仕様の矛盾と穴を能動探索する"
     :statement "probe-specは仕様全体についてinvariant間、context間、両者間、未規定領域、観測不能条件、不当依存を監査し、完全性とevidence-backed findingを不活性データで返す。"
     :acceptance
     ((:id :AC-020-1 :given "監査を完了し穴がない仕様"
       :when "probeする" :then "complete tかつfinding 0を返す")
      (:id :AC-020-2 :given "矛盾または未規定領域"
       :when "probeする" :then "関係条項をwhyに、具体的修正をhowに持つfindingを返す")
      (:id :AC-020-3 :given "focus付きprobe"
       :when "実行する" :then "部分監査としてderive証明には使わない"))
     :priority :must)

    (:id :REQ-021
     :title "派生前に仕様proofを要求する"
     :statement "deriveは対象specと推移spec依存について現在のevaluator、prompt、model、spec hashに一致するcheck成功と完全でfindingなしのprobeを要求し、明示ignore-skip以外でskipを通さない。"
     :acceptance
     ((:id :AC-021-1 :given "checkまたはfull probeがない、古い、失敗した仕様"
       :when "deriveする" :then "生成とledger更新を行わずproof blockerを返す")
      (:id :AC-021-2 :given "checkがskipだけでprobeはclean"
       :when "ignore-skipを明示してderiveする" :then "無視したskipをproofへ記録する")
      (:id :AC-021-3 :given "成功したderive"
       :when "完了する" :then "spec、依存、proof、via、target hashをledgerへ記録する"))
     :priority :must)

    (:id :REQ-022
     :title "派生成果物の鮮度とdriftを検査する"
     :statement "spec statusはLLMなしでledger、source spec、依存、proof metadata、target bytesを検査し、fresh、stale、drifted、missing、invalid、unknownを区別して注意対象があれば終了1にする。"
     :acceptance
     ((:id :AC-022-1 :given "specまたは宣言依存を変更する"
       :when "statusを実行する" :then "該当targetをstaleにする")
      (:id :AC-022-2 :given "生成後のtargetを手編集する"
       :when "statusを実行する" :then "driftedにする")
      (:id :AC-022-3 :given "ledgerが存在するが読めない、またはproof metadataが現処理系と非互換"
       :when "statusを実行する" :then "成功扱いにせずinvalidまたはunknownとして終了1にする"))
     :priority :must)

    (:id :REQ-023
     :title "外部verificationを明示実行する"
     :statement "verifyフォームは評価時には登録だけを行い、runのverify flag下で全生成後に外部commandを順番に実行し、結果をresultへ埋め、同一bytesのledger targetだけをverifiedとして刻む。"
     :acceptance
     ((:id :AC-023-1 :given "verify flagなし"
       :when "runする" :then "commandを実行せずpending recordを返す")
      (:id :AC-023-2 :given "期待exitと異なるcommand"
       :when "verify flag付きでrunする" :then "verification-failed error値と非0終了を返す")
      (:id :AC-023-3 :given "手編集されたtargetへの成功command"
       :when "ledgerを更新する" :then "verified stampを付けない"))
     :priority :must)

    (:id :REQ-024
     :title "trusted syntax pluginを明示ロードする"
     :statement "pluginはGit URLと任意revisionからproject cacheへ取得し、data-only manifestが指定するASDF systemをtrusted host codeとしてloadしてsyntax macroを登録する。"
     :acceptance
     ((:id :AC-024-1 :given "manifest"
       :when "読む" :then "read-evalを無効化しstringのsystemとasdだけを受理する")
      (:id :AC-024-2 :given "revision指定"
       :when "取得する" :then "detached checkoutし失敗した一時cloneをcache完成物として扱わない")
      (:id :AC-024-3 :given "pluginが未固定"
       :when "利用する" :then "remote HEADへ追随する危険が利用者に明示される"))
     :priority :should)

    (:id :REQ-025
     :title "回帰検証と開発可能性を維持する"
     :statement "処理系はASDF systemとして構築でき、外部allisp sourceなしで自動testが完走し、公開機能と失敗境界をtestで固定する。"
     :acceptance
     ((:id :AC-025-1 :given "supported Common Lisp環境と依存"
       :when "make testを実行する" :then "全testが成功する")
      (:id :AC-025-2 :given "CLI実行ファイル"
       :when "buildまたはRoswell scriptで起動する" :then "同じallisp systemとentrypointを使う"))
     :priority :must)
    ))

(def allisp-design
  '(:architecture :staged-interpreter
    :principles
    ((:id :DES-001 :name "実行主体の分離"
      :decision "LLMはコード生成だけを担当し、allisp evaluatorまたは明示external verifierだけが実行する。"
      :requirements (:REQ-002 :REQ-003 :REQ-004 :REQ-023))
     (:id :DES-002 :name "再生可能性"
      :decision "source、prompt、model、生成code、evaluator semanticsを識別し、同一条件はcacheから再評価する。"
      :requirements (:REQ-001 :REQ-006 :REQ-008 :REQ-021 :REQ-022))
     (:id :DES-003 :name "仕様中心の派生"
      :decision "spec、example、dependencyを正本とし、checkとprobeのproofを通った派生物だけをledger管理する。"
      :requirements (:REQ-018 :REQ-019 :REQ-020 :REQ-021 :REQ-022 :REQ-023))
     (:id :DES-004 :name "失敗の可視化"
      :decision "曖昧さはintermediate-code、実行失敗はerror、仕様穴はspec-findings、外部失敗はverification-failedとしてS式に残す。"
      :requirements (:REQ-004 :REQ-005 :REQ-009 :REQ-019 :REQ-020 :REQ-023))
     (:id :DES-005 :name "最小権限"
      :decision "deterministic builtinをallowlist化し、oracle探索をread-onlyにし、効果は明示構文とCLI flagへ隔離する。"
      :requirements (:REQ-004 :REQ-007 :REQ-010 :REQ-012 :REQ-023 :REQ-024)))

    :components
    ((:id :CMP-READER :path "src/reader.lisp"
      :responsibility "allisp readtable、正規化、S式read/print"
      :requirements (:REQ-001 :REQ-010))
     (:id :CMP-ENV :path "src/env.lisp"
      :responsibility "Lisp-1 lexical environment、run state、error値"
      :requirements (:REQ-002 :REQ-009 :REQ-010 :REQ-011))
     (:id :CMP-EVAL :path "src/eval.lisp"
      :responsibility "特殊形式、staging、依存文脈、logic、生成、spec forms"
      :requirements (:REQ-002 :REQ-003 :REQ-004 :REQ-005 :REQ-006
                     :REQ-011 :REQ-012 :REQ-015 :REQ-017 :REQ-018
                     :REQ-019 :REQ-020 :REQ-021 :REQ-023))
     (:id :CMP-BUILTINS :path "src/builtins.lisp"
      :responsibility "deterministic allowlist、高階関数、managed memory、spec accessor"
      :requirements (:REQ-002 :REQ-010 :REQ-016 :REQ-018))
     (:id :CMP-BACKEND :path "src/backend.lisp"
      :responsibility "claude/codex CLI adapterとread-only探索境界"
      :requirements (:REQ-003 :REQ-007))
     (:id :CMP-CACHE :path "src/cache.lisp"
      :responsibility "oracle cache key用hash、永続code cache、timestamp"
      :requirements (:REQ-008))
     (:id :CMP-SPEC :path "src/spec.lisp"
      :responsibility "spec schema補助、dependency hash、derive ledger、status、verification executor"
      :requirements (:REQ-018 :REQ-021 :REQ-022 :REQ-023))
     (:id :CMP-DIFF :path "src/diff.lisp"
      :responsibility "resultの安定対応付けと構造化差分"
      :requirements (:REQ-014))
     (:id :CMP-PLUGIN :path "src/plugin.lisp"
      :responsibility "trusted syntax plugin取得、manifest検査、ASDF load"
      :requirements (:REQ-024))
     (:id :CMP-RUNNER :path "src/runner.lisp"
      :responsibility "file/directory/one-liner lifecycle、result/trace、verification timing"
      :requirements (:REQ-001 :REQ-007 :REQ-009 :REQ-011 :REQ-013 :REQ-023))
     (:id :CMP-CLI :path "src/cli.lisp"
      :responsibility "command routing、option、exit status"
      :requirements (:REQ-013 :REQ-014 :REQ-022 :REQ-023))
     (:id :CMP-TESTS :path "tests/main.lisp"
      :responsibility "言語、staging、spec workflow、CLI境界の回帰test"
      :requirements (:REQ-025)))

    :data-flows
    ((:id :FLOW-EVAL
      :steps (:reader :environment :deterministic-evaluator
              :oracle-on-unbound :resolution-gate :result-and-trace)
      :requirements (:REQ-001 :REQ-002 :REQ-003 :REQ-004 :REQ-008 :REQ-009))
     (:id :FLOW-SPEC
      :steps (:defspec :example :check-spec :probe-spec :derive
              :verify :spec-status)
      :requirements (:REQ-018 :REQ-019 :REQ-020 :REQ-021 :REQ-022 :REQ-023))
     (:id :FLOW-CHAIN
      :steps (:source-run :result-v3 :at-use :restored-bindings)
      :requirements (:REQ-011))
     (:id :FLOW-PLUGIN
      :steps (:git-fetch :detached-checkout :manifest-read :asdf-load
              :syntax-macro-install)
      :requirements (:REQ-024)))

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
     "A requirement omission is externally observable behavior or a necessary safety/compatibility rule present in the product but absent from allisp-requirements."
     "A design omission is an unassigned responsibility, missing boundary, missing failure policy, or incompatible data-flow decision not covered by allisp-design."
     "An implementation gap must cite a requirement id and concrete file plus line or function evidence."
     "A test gap requires implemented or required behavior for which no meaningful regression assertion exists."
     "Documentation drift requires two concrete contradictory claims or a claim contradicted by code."
     "Do not report deferred v2 work, style preferences, speculative vulnerabilities, or lack of comments."
     "Deduplicate findings by root cause and prefer the narrowest actionable repair."
     "Set :complete t when the requested repository inspection was completed; findings do not make the audit incomplete. Use nil only when evidence could not be inspected.")
    :return-shape
    (:implementation-audit
     :complete boolean
     :baseline (:command string :status symbol :checks integer)
     :coverage (:requirements integer :design-decisions integer
                :components integer)
     :findings
     ((:id symbol
       :kind symbol
       :severity symbol
       :requirement symbol-or-nil
       :design symbol-or-nil
       :evidence ((:path string :location string :observation string))
       :why string
       :how string)))))

;; Deterministic self-check of the requirements/design model.
(defun entry-has-fields? (entry fields)
  (every (lambda (field)
           (not (eq (get-property entry field :default :field-absent)
                    :field-absent)))
         fields))

(defun entry-ids (entries)
  (mapcar (lambda (entry) (get-property entry :id)) entries))

(defun unique-values? (values)
  (= (length values) (length (remove-duplicates values))))

(defun all-known-requirements? (references known)
  (every (lambda (reference) (member reference known)) references))

(def requirement-ids (entry-ids allisp-requirements))
(def design-principles (get-property allisp-design :principles))
(def design-components (get-property allisp-design :components))
(def design-flows (get-property allisp-design :data-flows))

(def model-validation
  (let ((requirement-shape
          (every (lambda (entry)
                   (entry-has-fields?
                    entry '(:id :title :statement :acceptance :priority)))
                 allisp-requirements))
        (acceptance-shape
          (every (lambda (entry)
                   (every (lambda (criterion)
                            (entry-has-fields?
                             criterion '(:id :given :when :then)))
                          (get-property entry :acceptance)))
                 allisp-requirements))
        (requirement-id-unique
          (unique-values? requirement-ids))
        (acceptance-id-unique
          (unique-values?
           (mapcan (lambda (entry)
                     (entry-ids (get-property entry :acceptance)))
                   allisp-requirements)))
        (principle-shape
          (every (lambda (entry)
                   (entry-has-fields?
                    entry '(:id :name :decision :requirements)))
                 design-principles))
        (component-shape
          (every (lambda (entry)
                   (entry-has-fields?
                    entry '(:id :path :responsibility :requirements)))
                 design-components))
        (trace-valid
          (every
           (lambda (entry)
             (all-known-requirements?
              (get-property entry :requirements) requirement-ids))
           (append design-principles design-components design-flows))))
    (list :model-validation
          :status
          (if (and requirement-shape acceptance-shape
                   requirement-id-unique acceptance-id-unique
                   principle-shape component-shape trace-valid)
              :passed
              :failed)
          :requirements (length allisp-requirements)
          :acceptance-criteria
          (length
           (mapcan (lambda (entry)
                     (get-property entry :acceptance))
                   allisp-requirements))
          :design-principles (length design-principles)
          :components (length design-components)
          :checks
          (list :requirement-shape requirement-shape
                :acceptance-shape acceptance-shape
                :requirement-id-unique requirement-id-unique
                :acceptance-id-unique acceptance-id-unique
                :principle-shape principle-shape
                :component-shape component-shape
                :trace-valid trace-valid))))

;; Semantic conformance audit.  The operator is intentionally undefined:
;; allisp delegates this judgment to the read-only repository-exploring
;; oracle.  :context :file makes this complete self-spec the audit input.
(def current-implementation-audit
  (llm
    (audit-current-allisp-implementation
      :metadata specification-metadata
      :requirements allisp-requirements
      :design allisp-design
      :scope implementation-scope
      :criteria audit-criteria
      :baseline '(:command "make test"
                  :status :passed
                  :checks 424)
      :instruction
      "Inspect the repository at the current revision. Return quoted structured data matching :return-shape. Report only evidence-backed omissions or gaps; every finding must cite a path and function or line. Requirement and design omissions are first-class findings, not just implementation bugs.")
    :context :file))
