# quint_driver

Ruby のシステムを [Quint](https://github.com/quint-co/quint) の仕様に照らしてテストします。
仕様は各コマンドが何をすべきかを決めます。
テストは同じコマンドを本物のシステムで動かし、1 手ごとに両者を比べます。

手順の選び方は 2 つあり、どちらも同じドライバーを使います。

- **トレース再生。** `quint run --mbt` がトレースを書き、各トレースを 1 手ずつシステムで動かします。手順は Quint が選ぶので、深い状態にすぐ届きます。
- **Hegel。** [Hegel](https://github.com/meganemura/hegel-ruby) が、仕様がいま許すアクションから 1 手ずつ選びます。システムが仕様と食い違うと、Hegel は失敗を短いコマンド列まで縮めます。

仕様は Quint の JSON IR から読み、Ruby のプロセスの中で評価します。
そのため Hegel の 1 手で別のプロセスは起動しません。

## インストール

```ruby
# Gemfile
gem "quint_driver", github: "meganemura/quint_driver"
gem "hegeltest", "= 0.4.1" # Hegel アダプターを使うときだけ
```

トレース再生とモデルは `require "quint_driver"` で読み込みます。
必要なのは Ruby 3.3 以降だけで、ほかの gem は要りません。

Hegel アダプターは `require "quint_driver/hegel"` で読み込みます。
こちらには hegeltest 0.4.1 が必要で、hegeltest は Ruby 3.4 以降を必要とします。
この gem は hegeltest に依存しないので、自分の Gemfile に追加してください。

この gem は `quint` コマンドを呼びます。
使うコマンドは `QUINT` で指定します(手元にインストールしたものなど)。
指定がなければ `npx --yes @informalsystems/quint@0.33.0` を実行するので、Node.js と、初回は npm レジストリへの接続が必要です。
オフラインなどで npx が quint を取得できないときは、そのことを伝えて `QUINT` の指定を促す `QuintDriver::QuintFailed` を投げます。

`Spec.new` は、1 つのプロセスの中で、ファイルと quint コマンドの組ごとに 1 回だけコンパイルします。
ファイルの中身か、ファイルが import するファイルの中身が変わると、もう一度コンパイルします。
ファイルのどのモジュールもこのコンパイルを使うので、同じファイルの別の `main:` で `Spec.new` や `Quint.simulate` を呼んでも node は動きません。
同じファイルを複数のスレッドが同時に求めても、コンパイルは 1 回で、ほかのスレッドはそれを待ちます。
そのため、並列のテストに自前のメモは要りません。

`Quint.simulate` は、Quint の Rust 評価器が見つかれば、node を通さずに直接実行します。
探すのは、quint が `QUINT_HOME/rust-evaluator-v0.7.0/` にダウンロードしたものです(`QUINT_HOME` の指定がなければ `~/.quint`)。
別の評価器を使うときは `QUINT_EVALUATOR` にそのパスを指定します。
空の文字列を指定すると、代わりに `quint run` を実行します。
どちらの方法でも、同じシードからは同じトレースができます。
この gem が読めるのは、quint 0.33.0 が使う評価器 v0.7.0 の入出力の形だけです。
別の形で答える評価器では `QuintDriver::QuintFailed` を投げます。
評価器が見つからないとき、または `step:` がモジュールのアクションを指していないときは、`quint run` を実行します。

### エージェント向けのスキル

[quint_driver スキル](skills/quint_driver/SKILL.md)は、仕様の形、ドライバー、トレース再生、モデルの確認、Hegel の順にコーディングエージェントを案内します。
[`skills`](https://github.com/vercel-labs/skills) CLI(Node.js 22.20 以降)でインストールします。
このリポジトリは非公開なので、次のコマンドには GitHub へのアクセスが必要です。

```sh
npx skills add meganemura/quint_driver
```

```sh
npx skills add meganemura/quint_driver --skill quint_driver
```

```sh
npx skills add meganemura/quint_driver -g
```

```sh
npx skills add meganemura/quint_driver -a claude-code
```

`--skill` はこのスキルを選び、`-g` はすべてのプロジェクトに入れ、`-a` は 1 つのエージェントを対象にします。
`-y` を付けると確認を省きます。

コピーやシンボリックリンクで入れることもできます。

```sh
mkdir -p .agents/skills
ln -s /path/to/quint_driver/skills/quint_driver .agents/skills/quint_driver
```

`.claude/skills/` と `.cursor/skills/` でも同じです。

## ドライバーを書く

ドライバーは、仕様のアクションをシステムで動かし、システムの状態を仕様の言葉で読み戻します。

```ruby
class LoansDriver
  # 仕様のアクションを 1 つ動かします。どの手順も最初は "init" です。
  # +picks+ は nondet の値で、たとえば { "m" => "m1", "b" => "b2" } です。
  def step(action, picks)
    @outcome = "Done"
    case action.delete_suffix("_refused")
    when "init" then @loans = Loans.new
    when "borrow" then @loans.borrow(picks.fetch("m"), picks.fetch("b"))
    when "give_back" then @loans.give_back(picks.fetch("b"))
    end
  rescue Loans::Refused => refusal
    @outcome = [ "Refused", refusal.reason.to_s ]
  end

  # 仕様の変数を素の Ruby の値で返します。ここで返した変数だけを比べます。
  def state
    { "holder" => %w[b1 b2 b3].to_h { [ _1, @loans.holder(_1) || "" ] }, "outcome" => @outcome }
  end
end
```

素の値の対応は次のとおりです。
Quint の集合は `Set`、マップは `Hash`、タプルとリストは `Array`、レコードは文字列のキーを持つ `Hash` です。
直和型はタグになり、値を持つときは `[タグ, 値]` になります。

仕様、システム、ドライバーをそろえた例は [examples/loans](examples/loans) にあります。

## 動かす

```ruby
require "quint_driver"

spec = QuintDriver::Spec.new("loans.qnt", main: "loans")

# トレース再生: Quint が手順を選びます。
QuintDriver::Quint.simulate("loans.qnt", traces: 50, max_steps: 20, seed: "1") do |path|
  QuintDriver::Trace.replay(path, LoansDriver.new)
end

# Hegel が手順を選び、失敗を縮めます。
require "quint_driver/hegel"
machine = QuintDriver.machine(spec, driver: -> { LoansDriver.new }, invariants: %i[one_book_each])
Hegel.test(test_cases: 100) { |tc| Hegel::Stateful.run(machine.new, tc) }
```

どちらも、食い違った変数と、`init` からドライバーが動かした手順を並べて `QuintDriver::Mismatch` を投げます。
この手順を順に動かせば、失敗をもう一度起こせます。
どの値も、集合の要素とハッシュのキーを並べ替えて表示します。
そのため、仕様の側とドライバーの側は、レコードを同じキーの順で表示します。
メッセージは `trace:` の行で終わります。
`Quint.simulate` から戻ったあとは、再生したファイルはもう消えています。
そのため、この行はトレースをファイル名と、同じトレースをもう一度書く呼び出しで示します。
例えば `trace: trace_0.itf.json of Quint.simulate("loans.qnt", traces: 50, max_steps: 20, seed: "1", step: "step", backend: "rust")` です。
ブロックの中で捕まえても、メッセージは同じです。
同じ事柄を `trace`、`seed`、`written_by` としても持っています。
ブロックの中で自分のコードが投げた `Mismatch` も、ブロックを出るときに同じ `trace:` の行を得ます。
例えば、再生のあとに自分で確かめた結果です。
投げるときはメッセージだけを渡します（`raise QuintDriver::Mismatch, "..."`）。
実際に走ったトレースは gem が示すので、`Mismatch.new` はトレース、シード、呼び出しを受け取りません。
自分で用意したトレースファイルを再生したときは、そのパスを示します。
その手が選ばなかった選択値、つまり Quint の `None` は `picks` にありません。
なくてもよい選択値は `picks["name"]` で読み、そのときは `nil` です。
欠かせない選択値は `picks.fetch("name")` で読みます。
`Trace.replay` は、走らせたステップを `action`、`picks`、`expected` の状態とともに返すので、トレースがどこまで届いたかを数えられます。
再生の様子を見るときは `Trace.replay` に `log: $stdout` を渡します。
ドライバーが動かす前に、`step 1 borrow {"b" => "b1", "m" => "m2"}` のように各ステップを書き出します。
Minitest のテストでも RSpec の example でも同じコードで動きます。
RSpec で自分の example から値を引くときは `Hegel::Syntax::Methods` を include してください。
Rails アプリでは、トランザクションのフィクスチャーは example ごとに一度だけロールバックします。
そのため、1 つの example のすべてのトレースと Hegel のすべてのテストケースが、テスト用データベースを共有します。
ドライバーの `init` で行を消すか、トレースとテストケースごとに `ActiveRecord::Base.transaction(requires_new: true, joinable: false) { ...; raise ActiveRecord::Rollback }` で包んでください。
スキルには両方の書き方と、セーブポイントを joinable にしてはいけない理由があります。
machine 自体には不要です。

ステップが投げたエラーは、`Mismatch` ではなく `QuintDriver::StepRaised` になります。
エラーはドライバー自身のコードからも、その下のシステムからも来ます。
ドライバーの例は、選んだ値の名前が `m` なのに `picks.fetch("member")` と書いたときの `KeyError` です。
このとき、仕様とシステムはまだ比べられていません。
メッセージは ``quint: at step 1 `borrow` {"b" => "b2", "m" => "m2"}, the step raised KeyError: key not found: "member"`` のようにステップとエラーを示します。
続く `raised in:` の行は、`raised in: loans_driver.rb:6:in 'Hash#fetch'` のように、投げた場所にいちばん近いプロジェクトのフレームを示します。
パスは、実行を始めたディレクトリからの相対パスです。
gem、Ruby のライブラリ、quint_driver の中のフレームは飛ばすので、gem が投げたエラーでは、その gem を呼んだ自分の行を示します。
すべてのフレームを飛ばしたときは、その行が `raised in: no frame of the project; every frame is in a gem, in Ruby's library, or in quint_driver` と示します。
そのときはバックトレースを読んでください。
Hegel のもとでは、ステップの番号は Hegel のレポートがその手に付けた番号（`Step 2: take` など）で、再生と同じく `init` はステップ 0 です。
そのあとに `init` からの手順を並べます。
再生では、最後に同じ `trace:` の行が付きます。
バックトレースはそのエラーのもので、`cause` はそのエラーです。

`Quint.simulate` は、ファイル名と同じ名前のモジュールを動かします。
同じファイルの別のモジュールを動かすときは `main:` を渡します。
`Spec.new` に渡すのと同じ名前です。
quint が失敗したときや見つからないときは、`Spec.new` と `Quint.simulate` が quint の理由を添えて `QuintDriver::QuintFailed` を投げます。

ある状態に至る手順を試すときは、その状態で成り立つ定義の名前を `reach:` に渡します。
例えば `val two_on_loan = BOOKS.filter(b => onLoan(holder, b)).size() == 2` なら `reach: "two_on_loan"` です。
各トレースは、その定義が初めて成り立つ状態で終わり、`Quint.simulate` はそこに至ったトレースだけを渡します。
Quint は `not(two_on_loan)` を不変条件として確かめ、それが破れたところでトレースを止めます。
どのトレースも至らなかったときは、`quint: no trace of 20 reached two_on_loan within 1 steps; raise max_steps or traces` のように `QuintDriver::QuintFailed` を投げます。

`Quint.test(path, "lendTest", seed: "1") { |trace| ... }` は、`run lendTest = init.then(borrow("m1", "b1")).then(give_back("b1"))` のような名前付きの run のトレースを書き、そのファイルを渡します。
run がファイルの別のモジュールにあるときは `main:` を渡します。
quint test は `mbt::actionTaken` を書かないので、仕様は各ステップが取ったアクションを自分で記録する必要があります。
[Choreo](https://github.com/informalsystems/choreo) の仕様がそうしています。
記録には、タグがアクションを名指し、レコードが選択値を持つ直和型の変数を使います。
例えば `taken: Borrow({ m: m, b: b })` です。
その変数へのパスを `Trace.replay` の `action:` に渡します。
ドライバーが答える状態が変数の中にあるときは、そのパスを `state:` に渡します。
例えば Choreo の仕様の 1 つの変数の `system` フィールドです。
そのとき、ドライバーの `state` はそのレコードかマップを返します。
`test/recorded.qnt` はこの形の小さな仕様で、`test/trace_test.rb` の `RecordedDriver` がそのドライバーです。

```ruby
QuintDriver::Quint.test("test/recorded.qnt", "lendTest", seed: "1") do |trace|
  QuintDriver::Trace.replay(trace, RecordedDriver.new, state: %w[s books], action: %w[s taken])
end
```

ドライバーは `step("Init", {})`、続いて `step("Borrow", { "m" => "m1", "b" => "b1" })` のように呼ばれます。
失敗は、トレースを `trace: test_0.itf.json of Quint.test("test/recorded.qnt", "lendTest", seed: "1")` と示します。
quint の中で run そのものが失敗したときは、quint の報告を添えて `QuintDriver::QuintFailed` を投げます。
モジュールにない run の名前なら、`quint: no run is named lend in recorded; it has lendTest, unlentTest` のように、モジュールにある run を並べます。
アクションのないトレース、例えば `action:` なしで再生した quint test のトレースは、パスを求める `QuintDriver::Unsupported` を投げます。

`QuintDriver.machine` のオプションは次のとおりです。

- `step:` は手の一覧を持つアクションで、既定は `"step"` です。各手は名前のあるアクションを呼ぶ必要があります。引数は `nondet x = S.oneOf()` から取ります。選択肢と `any` を一つの `all` で囲んだ手（`all { nondet x = S.oneOf() any { add(x), sub(x) } }` など）は、`any` のアクションで手を進めます。モジュールにないアクションを `step:` に渡すと、モジュールのアクションを並べた `ArgumentError` を投げます（`quint: no action is named steps; the module has counting, init, step`）。
- `invariants:` は、毎手のあとに成り立つべき仕様の `val` の名前です。
- `choose:` は Hegel が手を引く方法です。`:rule`(既定)はアクションを選び、仕様が許さなければ捨てます。最短の手順まで縮みます。`:rotate` は許されないアクションの番を次の許されるアクションに回します。少ないテストケースで深い状態に届きますが、縮めた手順に余分な手が残ることがあります。
Hegel の失敗の報告は、引いた値を nondet の選択値の名前で示します。
`:rotate` では `rule` と `move` です。
一つのテストケースで同じ名前を二度以上引くと、引いた順に番号が付きます（`m_1 = "m2"`、`m_2 = "m1"`）。
一度しか引かない名前には番号が付きません（`m = "m2"`）。

各テストケースは、machine が始まるとき、Hegel の最初のステップより前に、ドライバーの `init` で新しいシステムから始めます。
そのため `init` で失敗するドライバーは、Hegel のレポートにステップが 1 つもない形で失敗します。
縮める処理は同じ手順を何度も求めるので、システムが一度一致した手順は再び動かしません。
これは、同じ手順にはシステムが毎回同じ答えを返すことを前提にしています。
食い違った手順は、毎回システムで動かし直します。

Hegel の実行には Quint のシード値がありません。
Hegel のレポートは、`reproduce_failure: "AXicXYmhDQAADMJWu/3/70BgQJCmvdEWPwRiKlCBBwzbAGE="` のような値で終わります。
それを `Hegel.test` の `reproduce_failure:` に渡すと、その失敗したケースだけを同じメッセージでもう一度動かします。

## Ruby のモデルを確かめる

Hegel のやり方は、仕様の Ruby での評価を信じています。
モデルもドライバーと同じ受け答えをするので、Quint 自身のトレースに照らして確かめられます。
別のモジュールやファイルから定義やアクションを import するモジュールは、quint が動かすときと同じく、それを自分のものとして読みます。
そのモジュールには、コンパイルが 1 回増えます。

```ruby
QuintDriver::Quint.simulate("loans.qnt", traces: 200, max_steps: 30, seed: "7") do |path|
  QuintDriver::Trace.replay(path, spec.model)
end
```

モデルが評価できるのは、コマンドごとにアクションを書く仕様が使う演算子です。
集合 (`fold` と `i.to(j)` を含む)、マップ、レコード、タプル、リスト、`match` 付きの直和型、整数、真偽値です。
マップでは `Map`、`get`、`keys`、`put`、`mapBy`、`set`、`setBy`、`setToMap` を評価します。
リストは Ruby の Array になります。
リストでは `List`、`append`、`concat`、`head`、`tail`、`length`、`nth`、`indices`、`replaceAt`、`slice`、`range`、`select`、`foldl`、`foldr` を評価します。
Quint の組み込みのドキュメントに `foldr` はありません。
ただし Quint の二つの評価器はどちらも右から畳み込み、要素を先に渡します（`(x, acc) => ...`）。
モデルも同じようにします。
整数では `+`、`-`、`*`、単項の `-`、比較を評価します。
`/` と `%` は両辺が負でないときだけ評価します。
Quint は負の値を割ったときの丸めを決めていないからです。
Quint の二つの評価器はゼロに向けて切り捨て（`-7 % 2` は `-1`）、Ruby は小さい方へ丸めます（`-7 % 2` は `1`）。
そのため、モデルは違う答えを出さずに、負の値を断ります。
空のリストの `head`、末尾より先の `nth`、キーが重なる組の `setToMap` のように、Quint のドキュメントが未定義とする演算では、モデルは答えを選ばずに `QuintDriver::Unsupported` を投げます。
マップに無いキーでの `get`、`set`、`setBy` も、Quint の評価器がそこで止まるので、`QuintDriver::Unsupported` を投げます。
ただし `slice(l, l.length(), l.length())` は、Quint の二つの評価器と同じく `[]` です。
`powerset` など、それ以外の演算子は `QuintDriver::Unsupported` を投げるので、足りない仕様ははっきり失敗します。
アクションを名指ししない step の枝も同じです。
そのメッセージには、その枝を持つアクションの名前が入ります。
例えば `step` が `counting` をその場で開くときは、`quint: counting assigns n' in an arm that names no action; name every action in step` です。
メッセージには、その演算子を書いたアクションか定義の名前が入ります。
例えば `quint: no evaluation for operator powerset in subsets` です。
nondet の定義域にある演算子では、それを選ぶアクションを示します。
`step` がその場で開くアクションのこともあります。

モデルは `Spec#model` で作ります。
モデルは quint がコンパイルした IR の形を信用するので、`Model.new` は private です。
トレースは選択値を素の値で渡し、モデルはその定義域から同じ値に読める値を取るので、直和型の選択値も `match` で使えます。

`model.moves(rule)` は、`spec.rules("step")` のルールがモデルの今の状態で許す手を、`[アクション, 選択値, 次の状態]` の形で、決まった順に並べます。
`model.enter(次の状態)` でその手を取ります。
Hegel のマシンはこの方法で手を選びます。
`model.value(node, env)` は、IR のノードを一つ、または文字列が名指す定義を、今の状態で評価します。
評価できない演算子のメッセージは、ルールの定義域や引数なら、それを書いたアクションを示します。
仕様のどの定義にもないノードなら、メッセージはノードが `outside any definition` だと示します。
`rule.fixed` は、どの状態でも、先の選択値がどれでも同じ集合になる定義域の名前の集合です。
Quint の effect が変数を読まないと示し、先の選択値の名前も使わない定義域がそれにあたります。
`:rule` の Hegel のマシンは、そうした定義域をマシンごとに一度だけ評価します。

## 開発

```sh
bundle install
bundle exec bin/test    # Minitest
bundle exec rspec       # RSpec
```

Hegel のテストは `test/hegel/` と `spec/hegel/` にあります。
Ruby 3.3 では hegeltest を除き、残りを動かします。

```sh
BUNDLE_WITHOUT=hegel bundle install
BUNDLE_WITHOUT=hegel bundle exec bin/test test/*_test.rb
BUNDLE_WITHOUT=hegel bundle exec rspec --exclude-pattern "spec/hegel/**/*_spec.rb"
```

テストは `quint` を実行します。
`QUINT` を指定すると `npx` を使いません。

## ライセンス

MIT
