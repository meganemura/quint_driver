# quint_driver

quint_driver は、Ruby のコードを [Quint](https://github.com/quint-co/quint) の仕様に照らしてテストします。
仕様は各コマンドが何をすべきかを決め、quint_driver は同じコマンドをコードで動かして、1 手ごとに両者を比べます。

## Rails アプリでのクイックスタート

### gem を追加する

```ruby
# Gemfile
group :test do
  gem "quint_driver", require: false
end
```

```sh
bundle install
npm install --global @informalsystems/quint@0.33.0
```

quint_driver には Ruby 3.3 以降が必要です。
この gem は `QUINT` が指す `quint` コマンドを呼ぶので、下の実行では `QUINT=quint` を指定します。
シェルのプロファイルに `export QUINT=quint` を書けば、指定を省けます。
`QUINT` の指定がなければ `npx --yes @informalsystems/quint@0.33.0` を実行します。
このときは初回に quint(43 MB)をダウンロードし、その後も毎回 node を 1 回多く起動します。
初回の quint の実行では、quint の Rust 評価器も GitHub から `~/.quint` にダウンロードします。
ネットワークがこのダウンロードを止めるときは、[スキル](skills/quint_driver/SKILL.md#install)に手で取得する方法があります。

### 最初のモデルを選ぶ

`state` や `status` のような状態の列と、それを変えるメソッドを持つモデルを選びます。
たとえば `Order#cancel` や `Loan#approve` です。
最近のコミットが状態を変えたモデルから始めるとよいでしょう。
仕様がその変更を確かめるからです。
そのようなコミットは `git log --oneline -- app/models` で一覧できます。
いくつもの入り口にまたがるバグを探すなら、[バグを探す](#バグを探す)を見てください。
`bundle exec quint_driver targets` は、アプリの中で探す価値が高いファイルを順に並べます。

下の手順では `Loan` を使います。
新しいローンは `"pending"` で、`Loan#approve(officer)` はそれを `"approved"` にします。
`Loan`、ドライバーの `init` が作るレコード、メソッド、状態の名前を、自分のものに置き換えてください。

### 仕様を書く

```quint
// spec/quint/loan_state.qnt
// A loan starts pending. Approving it once makes it approved, and
// approving it again leaves it approved.
module loan_state {
  var state: str

  action init = state' = "pending"
  action approve = all { state == "pending", state' = "approved" }
  action approve_refused = all { state == "approved", state' = state }

  action step = any { approve, approve_refused }
}
```

`var` は列です。
`init` は新しいレコードが持つ値です。
ほかのアクションはそれぞれメソッドの 1 回の呼び出しで、最初の条件は、その呼び出しがアクションのとおりに動くときを決めます。
`approve` は保留中のローンを承認済みにし、`approve_refused` は承認済みのローンをそのままにします。
`step` は、トレースが選ぶアクションを並べます。
`Quint.simulate` はファイルと同じ名前のモジュールを動かすので、2 つの名前をそろえます。

### ドライバーを書く

```ruby
# spec/quint/loan_state_driver.rb
# Runs each action of loan_state.qnt on a Loan and reads its state back.
class LoanStateDriver
  def step(action, _picks)
    case action
    when "init"
      borrower = Borrower.create!(name: "Ada", limit_cents: 20_000)
      @loan = Loan.create!(borrower: borrower, amount_cents: 500)
    when "approve", "approve_refused"
      @loan.approve({name: "Grace", senior: true})
    end
  end

  def state = {"state" => @loan.reload.state}
end
```

`step` は 1 つのアクションを本物のレコードで動かします。
`init` がレコードを作り、ほかのアクションはメソッドを呼びます。
`state` は、データベースから読み戻した仕様の変数を返します。

### example を書く

```ruby
# spec/quint/loan_state_spec.rb
require "rails_helper"
require "quint_driver"
require_relative "loan_state_driver"

RSpec.describe Loan, type: :model do
  # The transactional fixture rolls back once, after the example. Each trace
  # rolls back to a savepoint of its own, so no trace sees the rows of another.
  def rolled_back
    ActiveRecord::Base.transaction(requires_new: true, joinable: false) do
      yield
      raise ActiveRecord::Rollback
    end
  end

  it "moves its state the way loan_state.qnt says" do
    QuintDriver::Quint.simulate("spec/quint/loan_state.qnt", traces: 20, max_steps: 5, seed: "1") do |trace|
      rolled_back { QuintDriver::Trace.replay(trace, LoanStateDriver.new) }
    end
  end
end
```

Quint は最大 5 手のトレースを 20 本書き、各トレースは新しいローンで動きます。

### example を動かす

```sh
QUINT=quint bundle exec rspec spec/quint/loan_state_spec.rb
```

## 実行結果

次の出力は、`Borrower` と `Loan` のモデルを持つ小さなサンプルアプリ(貸し出し窓口)のものです。

```text
.

Finished in 0.60298 seconds (files took 0.88104 seconds to load)
1 example, 0 failures
```

どのトレースも、テストのデータベースにローンを作り、承認し、もう一度承認して、1 手ごとに状態を読み戻しました。
どの手の後でも、ローンの状態は仕様と同じでした。

次に、あるコミットが新しいローンを下書きにします。

```diff
--- a/app/models/loan.rb
+++ b/app/models/loan.rb
   def mark_pending
-    self.state ||= "pending"
+    self.state ||= "draft"
   end
```

```sh
QUINT=quint bundle exec rspec spec/quint/loan_state_spec.rb
```

```text
F

Failures:

  1) Loan moves its state the way loan_state.qnt says
     Failure/Error: rolled_back { QuintDriver::Trace.replay(trace, LoanStateDriver.new) }

     QuintDriver::Mismatch:
       quint: after step 0 `init` {}, the driver differs from the trace
         state: trace "pending", driver "draft"
       steps:
         init {}
       trace: trace_0.itf.json of Quint.simulate("spec/quint/loan_state.qnt", traces: 20, max_steps: 5, seed: "1", step: "step", backend: "rust")
     # ./spec/quint/loan_state_spec.rb:18:in 'block (4 levels) in <top (required)>'
     # ./spec/quint/loan_state_spec.rb:11:in 'block in RSpec::ExampleGroups::Loan#rolled_back'
     # ./spec/quint/loan_state_spec.rb:10:in 'RSpec::ExampleGroups::Loan#rolled_back'
     # ./spec/quint/loan_state_spec.rb:18:in 'block (3 levels) in <top (required)>'
     # ./spec/quint/loan_state_spec.rb:17:in 'block (2 levels) in <top (required)>'

Finished in 0.61377 seconds (files took 0.90689 seconds to load)
1 example, 1 failure

Failed examples:

rspec ./spec/quint/loan_state_spec.rb:16 # Loan moves its state the way loan_state.qnt says
```

最初の行は、モデルと仕様が食い違った手を示します。
`init` の直後に、仕様のローンは保留中で、モデルのローンは下書きです。
`steps:` は `init` からのすべての手を並べるので、同じコマンドを手で動かせます。
`trace:` は、同じトレースをもう一度書く呼び出しを示します。
変更がバグなら、モデルを直します。
変更が意図したものなら、同じコミットで仕様の `init` を変えて、仕様がアプリの動きを言い続けるようにします。

次は、担当者や金額のような選択をアクションに持たせ、各呼び出しの結果のような 2 つ目の変数を比べます。
[もっと大きな仕様](#もっと大きな仕様拒否と選択)が両方を行います。

## もっと大きな仕様:拒否と選択

クイックスタートの仕様は、1 つのレコードと 1 つの変数を持ちます。
同じアプリのこの仕様は、1 人の借り手の 2 つのローンを持ち、各アクションの金額と担当者を選び、各呼び出しの結果も比べます。
ドライバーは仕様の各ローンが得た id を覚え、行を仕様の変数として読み戻します。
`Loan#approve(officer)` は、承認済みのローン、借り手の上限を超えるローン、そして担当者がシニアでないときの 10000 セントを超えるローンを断ります。

```ruby
# spec/quint/approval_driver.rb
class ApprovalDriver
  LOANS = %w[l1 l2].freeze

  def step(action, picks)
    @outcome = "Done"
    case action.delete_suffix("_refused")
    when "init"
      @borrower = Borrower.create!(name: "Ada", limit_cents: 20_000)
      @ids = {}
    when "open"
      @ids[picks.fetch("l")] = LoanDesk.open(@borrower, picks.fetch("a")).id
    when "approve"
      officer = {name: "Grace", senior: picks.fetch("senior")}
      result = Loan.find(@ids.fetch(picks.fetch("l"))).approve(officer)
      @outcome = ["Refused", result.to_s] unless result == :approved
    end
  end

  def state
    loans = LOANS.to_h { [_1, @ids[_1] && Loan.find(@ids[_1])] }
    {
      "amount" => loans.transform_values { _1&.amount_cents || 0 },
      "approved" => loans.transform_values { _1&.state == "approved" },
      "outcome" => @outcome
    }
  end
end
```

トランザクションのフィクスチャは例の後に 1 回だけロールバックしますが、1 つの例は多くのトレースを再生します。
各トレースを専用のセーブポイントで包み、どのトレースもほかのトレースの行を読まないようにします。

```ruby
# spec/quint/approval_spec.rb
require "rails_helper"
require "quint_driver"
require_relative "approval_driver"

RSpec.describe Loan, type: :model do
  def rolled_back
    ActiveRecord::Base.transaction(requires_new: true, joinable: false) do
      yield
      raise ActiveRecord::Rollback
    end
  end

  it "follows every trace Quint writes for approval.qnt" do
    QuintDriver::Quint.simulate("spec/quint/approval.qnt", traces: 50, max_steps: 8, seed: "1") do |path|
      rolled_back { QuintDriver::Trace.replay(path, ApprovalDriver.new) }
    end
  end
end
```

<details>
<summary>spec/quint/approval.qnt</summary>

```quint
// Two loans of one borrower with a limit of 20000 cents. A clerk approves
// up to 10000 cents, and a senior officer approves any amount. approve has
// a refused twin, so a trace checks the refusals too.
module approval {
  type Outcome = Done | Refused(str)

  pure val LOANS = Set("l1", "l2")
  pure val AMOUNTS = Set(500, 10000, 15000)
  pure val LIMIT = 20000

  // 0 means the loan is not open yet.
  var amount: str -> int
  var approved: str -> bool
  var outcome: Outcome

  pure def approvedCents(a: str -> int, ap: str -> bool): int =
    LOANS.filter(l => ap.get(l)).fold(0, (sum, l) => sum + a.get(l))
  pure def refusal(a: str -> int, ap: str -> bool, l: str, senior: bool): str =
    if (ap.get(l)) "already"
    else if (approvedCents(a, ap) + a.get(l) > LIMIT) "over_limit"
    else if (a.get(l) > 10000 and not(senior)) "needs_senior"
    else ""

  action init = all {
    amount' = LOANS.mapBy(_ => 0),
    approved' = LOANS.mapBy(_ => false),
    outcome' = Done,
  }

  action open(l: str, a: int): bool = all {
    amount.get(l) == 0,
    amount' = amount.put(l, a),
    approved' = approved,
    outcome' = Done,
  }
  action approve(l: str, senior: bool): bool = all {
    amount.get(l) > 0,
    refusal(amount, approved, l, senior) == "",
    amount' = amount,
    approved' = approved.put(l, true),
    outcome' = Done,
  }
  action approve_refused(l: str, senior: bool): bool = all {
    amount.get(l) > 0,
    refusal(amount, approved, l, senior) != "",
    amount' = amount,
    approved' = approved,
    outcome' = Refused(refusal(amount, approved, l, senior)),
  }

  action step = any {
    nondet l = LOANS.oneOf()
    nondet a = AMOUNTS.oneOf()
    any { open(l, a) },
    nondet l = LOANS.oneOf()
    nondet senior = Set(true, false).oneOf()
    any { approve(l, senior), approve_refused(l, senior) },
  }

  val within_limit = approvedCents(amount, approved) <= LIMIT
}
```

</details>

```sh
QUINT=quint bundle exec rspec spec/quint/approval_spec.rb
```

```text
.

Finished in 1.22 seconds (files took 0.91182 seconds to load)
1 example, 0 failures
```

50 本の各トレースが、本物のモデルとテストのデータベースで動き、ロールバックしました。
`Loan#approve` がちょうど 10000 セントでシニアを求める(`> 10_000` の代わりに `amount_cents >= 10_000`)と、同じコマンドは、そのようなローンを承認する最初のトレースで失敗します。

```text
     QuintDriver::Mismatch:
       quint: after step 6 `approve` {"l" => "l1", "senior" => false}, the driver differs from the trace
         approved: trace {"l1" => true, "l2" => true}, driver {"l1" => false, "l2" => true}
         outcome: trace "Done", driver ["Refused", "needs_senior"]
       steps:
         init {}
         open {"a" => 500, "l" => "l2"}
         approve {"l" => "l2", "senior" => false}
         open {"a" => 10000, "l" => "l1"}
         approve_refused {"l" => "l2", "senior" => false}
         approve_refused {"l" => "l2", "senior" => true}
         approve {"l" => "l1", "senior" => false}
       trace: trace_1.itf.json of Quint.simulate("spec/quint/approval.qnt", traces: 50, max_steps: 8, seed: "1", step: "step", backend: "rust")
```

セーブポイントの代わりにドライバーの `init` で行を消す方法と、セーブポイントを joinable にしてはいけない理由は、[スキル](skills/quint_driver/SKILL.md)にあります。

## バグを探す

1 つのモデルを固めるのでなくバグを探すときは、仕様に 2 種類のものを書きます。
action には、癖も含めていまのコードの動きを書きます。
そうすれば、アプリはどのトレースにも従います。
外のサービスを呼ぶ action には、どの呼び出しが失敗するかを選ぶ引数を持たせます。
そうすれば、トレースはアプリの rescue も通ります。
真偽値の `val` には、運用する人が期待することを書きます。
コードはこちらを破るかもしれません。
そして期待ごとに `violate:` で Quint のトレースをそこへ向け、同じ名前を `invariants:` に渡してトレースを再生します。

```ruby
  expectations.each do |expectation|
    it "keeps #{expectation} on the traces Quint aims at it" do
      simulation = QuintDriver::Quint.simulate(qnt, traces: 200, max_steps: 12, seed: "1", violate: expectation) do |path|
        rolled_back { QuintDriver::Trace.replay(path, driver, spec:, invariants: [ expectation ], ignore:) }
      end
      expect(simulation.never).to be_empty
    end
  end
```

`test/fixture/depot` は宅配ロッカーの小さな Rails アプリで、バグを 4 つ仕込んであります。
その `spec/quint/` が、この形でバグを探します。
どのバグも `QuintDriver::Violated` で失敗します。
アプリはどのステップでも仕様と一致したのに、運用する人の期待が成り立っていない、という意味です。

```text
quint: the system agreed with the spec at every step, and the expectation `free_compartment_has_no_code` does not hold after step 2 `release` {"offline" => 1, "p" => "p3"}
steps:
  init {}
  assignParcel {"offline" => 2, "p" => "p3"}
  release {"offline" => 1, "p" => "p3"}
state:
  everDone: {}
  intake: "none"
  live: {1}
  place: {"p1" => "Waiting", "p2" => "Waiting", "p3" => "Collected"}
  row: {"p1" => "", "p2" => "", "p3" => ""}
```

ここでは荷物は受け取られ、ボックスは空いたのに、ロッカーの制御装置はまだそのボックスの暗証番号を持っています。
受け取りのページが、制御装置のタイムアウトをトランザクションの中で rescue したからです。
`Violated` はバグの候補です。
探しているときの `Mismatch` は、たいてい仕様かドライバーの誤りです。
失敗を 1 つの example に固めるには、その `steps:` の下の文字列を `QuintDriver.replay_steps(spec, driver, <<~STEPS, invariants: [...])` に貼ります。
quint も Hegel も使わずに、その手順をもう一度動かします。
Quint のトレースにはいらない手順が混ざるので、`QuintDriver.shrink_steps` で同じ期待が破れるまま手順を減らしてから貼ります。
探す場所、候補の確かめ方、やめどきは、[スキル](skills/quint_driver/SKILL.md#hunt-for-bugs)にあります。
読み込みと書き込みの間に別のリクエストが入って更新が消えるバグは、`QuintDriver::Hold` でリクエストを途中で止めて探します。
書き方はスキルの [A request another one comes between](skills/quint_driver/SKILL.md#a-request-another-one-comes-between) にあります。

## アプリなしで試す

### インストール

```sh
gem install quint_driver rspec
npm install --global @informalsystems/quint@0.33.0
export QUINT=quint
```

ここでは Gemfile なしで gem をインストールします。
`QUINT` の働きは [gem を追加する](#gem-を追加する)にあります。

### 仕様とクラスとテストを書く

空のフォルダーで次を実行します。
3 つのファイルを書きます。
チケットを 3 枚まで売るチケット売り場の仕様、それを実装するクラス、そして両者をつなぐドライバーを含む RSpec のファイルです。

```sh
cat > tickets.qnt <<'QNT'
// A box office that sells at most 3 tickets.
module tickets {
  var sold: int
  var outcome: str

  action init = all { sold' = 0, outcome' = "ok" }
  action sell = all { sold < 3, sold' = sold + 1, outcome' = "ok" }
  action sell_refused = all { sold >= 3, sold' = sold, outcome' = "sold_out" }
  action refund = all { sold > 0, sold' = sold - 1, outcome' = "ok" }

  action step = any { sell, sell_refused, refund }
}
QNT

cat > box_office.rb <<'RUBY'
class BoxOffice
  LIMIT = 3

  attr_reader :sold

  def initialize = @sold = 0

  def sell
    return :sold_out if @sold >= LIMIT

    @sold += 1
    :ok
  end

  def refund
    @sold -= 1
    :ok
  end
end
RUBY

cat > box_office_spec.rb <<'RUBY'
require "quint_driver"
require_relative "box_office"

# Runs each action of tickets.qnt on a BoxOffice and reads it back as the spec's variables.
class BoxOfficeDriver
  def step(action, _picks)
    @office = BoxOffice.new if action == "init"
    @outcome =
      case action
      when "init" then "ok"
      when "sell", "sell_refused" then @office.sell.to_s
      when "refund" then @office.refund.to_s
      end
  end

  def state = { "sold" => @office.sold, "outcome" => @outcome }
end

RSpec.describe BoxOffice do
  it "sells tickets the way tickets.qnt says" do
    QuintDriver::Quint.simulate("tickets.qnt", traces: 20, max_steps: 10, seed: "1") do |trace|
      QuintDriver::Trace.replay(trace, BoxOfficeDriver.new)
    end
  end
end
RUBY
```

### 動かす

```sh
rspec box_office_spec.rb
```

```text
.

Finished in 0.47699 seconds (files took 0.08795 seconds to load)
1 example, 0 failures
```

Quint が最大 10 手のトレースを 20 本書き、ドライバーがその各手を新しい `BoxOffice` で動かしました。
どの手の後でも、クラスの `sold` と `outcome` は仕様と同じでした。

### 壊す

チケット売り場が 1 枚多く売るようにします。

```sh
ruby -pi -e 'sub("@sold >= LIMIT", "@sold > LIMIT")' box_office.rb
rspec box_office_spec.rb
```

```text
F

Failures:

  1) BoxOffice sells tickets the way tickets.qnt says
     Failure/Error: QuintDriver::Trace.replay(trace, BoxOfficeDriver.new)

     QuintDriver::Mismatch:
       quint: after step 8 `sell_refused` {}, the driver differs from the trace
         sold: trace 3, driver 4
         outcome: trace "sold_out", driver "ok"
       steps:
         init {}
         sell {}
         refund {}
         sell {}
         sell {}
         refund {}
         sell {}
         sell {}
         sell_refused {}
       trace: trace_2.itf.json of Quint.simulate("tickets.qnt", traces: 20, max_steps: 10, seed: "1", step: "step", backend: "rust")
     # ./box_office_spec.rb:22:in 'block (3 levels) in <top (required)>'
     # ./box_office_spec.rb:21:in 'block (2 levels) in <top (required)>'

Finished in 0.5298 seconds (files took 0.08509 seconds to load)
1 example, 1 failure

Failed examples:

rspec ./box_office_spec.rb:20 # BoxOffice sells tickets the way tickets.qnt says
```

最初の行は、クラスと仕様が食い違った手を示します。
8 手目で、3 枚売れた状態から、仕様は販売を断り、クラスは 4 枚目を売りました。
`steps:` は `init` からのすべての手を並べるので、同じコマンドを手で動かせます。
`trace:` は、同じトレースをもう一度書く呼び出しを示します。
クラスを直して、もう一度 `rspec` を実行します。

次は、自分のクラスの[ドライバーを書く](#ドライバーを書く)か、[Hegel](#動かす-1) に手順を選ばせて、失敗を最短の手順まで縮めます。

## 仕組み

手順の選び方は 2 つあり、どちらも同じドライバーを使います。

- **トレース再生。** `quint run --mbt` がトレースを書き、各トレースを 1 手ずつシステムで動かします。手順は Quint が選ぶので、深い状態にすぐ届きます。クイックスタートはこの方法を使います。
- **Hegel。** [Hegel](https://github.com/meganemura/hegel-ruby) が、仕様がいま許すアクションから 1 手ずつ選びます。システムが仕様と食い違うと、Hegel は失敗を短いコマンド列まで縮めます。

仕様は Quint の JSON IR から読み、Ruby のプロセスの中で評価します。
そのため Hegel の 1 手で別のプロセスは起動しません。

## インストール

```ruby
# Gemfile
gem "quint_driver"
gem "hegeltest", "= 0.5.1" # Hegel アダプターを使うときだけ
```

トレース再生とモデルは `require "quint_driver"` で読み込みます。
必要なのは Ruby 3.3 以降だけで、ほかの gem は要りません。

Hegel アダプターは `require "quint_driver/hegel"` で読み込みます。
こちらには hegeltest 0.5.1 が必要で、hegeltest は Ruby 3.4 以降を必要とします。
この gem は hegeltest に依存しないので、自分の Gemfile に追加してください。

この gem は、[クイックスタート](#gem-を追加する)のとおり、`QUINT` が指す `quint` コマンドを呼びます。
`QUINT` の指定がなければ `npx --yes @informalsystems/quint@0.33.0` を実行します。
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

gem にはスキルと `examples/loans` の仕様が入っています。
`bundle install` のあとは、インストールされたコピーをコピーやシンボリックリンクで入れることもできます。
この方法では GitHub へのアクセスは要りません。

```sh
mkdir -p .agents/skills
ln -s "$(bundle info --path quint_driver)/skills/quint_driver" .agents/skills/quint_driver
```

`.claude/skills/` と `.cursor/skills/` でも同じです。

## ドライバーを書く

ドライバーは、仕様のアクションをシステムで動かし、システムの状態を仕様の言葉で読み戻します。
`bundle exec quint_driver outline spec.qnt` は、書き始めるためのドライバーを出力します。
各アクションと受け取る選択、`state` が返す各変数とその値の Ruby での形、そして期待が並びます。
どのドライバーも step アクションを動かせないときは、理由を出して終了コード 1 で終わります。

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

  # 仕様の変数をすべて素の Ruby の値で返します。返さない変数があると、そのステップは失敗します。
  def state
    { "holder" => %w[b1 b2 b3].to_h { [ _1, @loans.holder(_1) || "" ] }, "outcome" => @outcome }
  end
end
```

素の値の対応は次のとおりです。
Quint の集合は `Set`、マップは `Hash`、タプルとリストは `Array`、レコードは文字列のキーを持つ `Hash` です。
直和型はタグになり、値を持つときは `[タグ, 値]` になります。
`None` と `Some` の場合を持つ直和型、つまり Option は、`None` なら `nil`、`Some` ならその値そのものです。
再生でもマシンでも同じです。

`state` が返さない変数があると、そのステップは失敗し、メッセージがその変数を名指しします。
例えば `count: trace 0, but the driver's state leaves count out` です。
そのため、返し忘れた変数が通ってしまうことはありません。
仕様は、リモートのサービスが返す答えのようなコードの外の世界を、変数で表すことがあります。
ドライバーがスタブを用意するために読むだけの変数は、`Trace.replay` か `QuintDriver.machine` の `ignore:` に名前を渡すと、比べなくなります。

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
`Mismatch` のバックトレースからは quint_driver 自身のフレームを除き、マシンでは Hegel のフレームも除きます。
そのため RSpec でも Minitest でも、再生か `Hegel.test` を呼んだ行か、`Mismatch` を投げた行が最初に出ます。
Gemfile が gem をパスから読み込むときも同じです。
その手が選ばなかった選択値は `picks` にありません。
その手が仕様の `None` を選んだ選択値は、`nil` として `picks` にあります。
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

トレースが持つのは仕様の変数で、定義は持ちません。
そのため、承認済みのローンを合計する `def approvedSum` のように仕様が導く値は、観測したときだけ比べます。
`Trace.replay` には `spec:` と一緒に `observe: %w[approvedSum]` を、`QuintDriver.machine` には `observe:` を渡します。
ドライバーの `state` では、`"approvedSum" => borrower.approved_total` のように同じ名前でその値を返します。
ドライバーは、各状態でその定義が持つ値に照らされます。
値を返さないドライバーは失敗します。
定義を評価するのはモデルです。
再生でもモデルがトレースの状態を読んで評価するので、失敗は `approvedSum: model 0, driver 15000` のようにモデルを示します。
ドライバーが返した名前がどの状態にもないときも失敗します。
例えば `dueCents: driver 0, but dueCents is not in the trace's state, which has amount, approvedBy, outcome` です。
その名前が仕様の定義なら、その行は `observe:` に名前を渡すよう示します。
パラメーターのない `val` や `def` でない名前を渡すと、モジュールにある名前を添えて `ArgumentError` を投げます。

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
バックトレースはそのエラーのものから quint_driver 自身のフレームを除いたもので、`cause` はそのエラーです。

`Quint.simulate` は、ファイル名と同じ名前のモジュールを動かします。
同じファイルの別のモジュールを動かすときは `main:` を渡します。
`Spec.new` に渡すのと同じ名前です。
quint が失敗したときや見つからないときは、`Spec.new` と `Quint.simulate` が quint の理由を添えて `QuintDriver::QuintFailed` を投げます。
そのバックトレースは gem を呼んだあなたの行から始まり、その前に quint_driver のフレームはありません。

ある状態に至る手順を試すときは、その状態で成り立つ定義の名前を `reach:` に渡します。
例えば `val two_on_loan = BOOKS.filter(b => onLoan(holder, b)).size() == 2` なら `reach: "two_on_loan"` です。
各トレースは、その定義が初めて成り立つ状態で終わり、`Quint.simulate` はそこに至ったトレースだけを渡します。
Quint は `not(two_on_loan)` を不変条件として確かめ、それが破れたところでトレースを止めます。
どのトレースも至らなかったときは、`quint: no trace of 20 reached two_on_loan within 1 steps; raise max_steps or traces` のように `QuintDriver::QuintFailed` を投げます。
`reach:` が受け取るのは述語、つまりパラメーターのない真偽値の `val` か `def` です。
`step:` が受け取るのは、パラメーターのないアクションです。
ほかの種類の名前を渡すと、quint を動かす前に `ArgumentError` を投げます。
例えば `quint: reach names borrow, an action with parameters of loans; reach takes a predicate, a boolean val or def without parameters, such as nothing_on_loan, one_book_each, two_on_loan` です。
モジュールが宣言もインポートもしていない名前を渡すと、quint が動いたあとに同じ形で `ArgumentError` を投げます。
例えば `quint: step names borow, which loans neither declares nor imports; step takes an action without parameters, such as step` です。
`reach:` には既定の `backend: "rust"` が必要です。
quint 0.33.0 の typescript バックエンドは、定義が初めて成り立つ状態を過ぎてもトレースを続け、そこに至らないトレースも至ったものとして示します。
そのため、`backend: "typescript"` と一緒に `reach:` を渡すと、quint を動かす前に `ArgumentError` を投げます。
トレースも、モデルも、マシンも、quint の既定と同じく `init` という名前のアクションから始まります。
`init` のないモジュールは `ArgumentError` を投げます。
例えば ``quint: begins neither declares nor imports an action named init; quint_driver starts every trace and every model at init, so declare `action init = ...` with what starts begins`` です。
quint_driver はほかの名前を受け取りません。
トレースは最初のステップをそのアクションの名前で呼び、ドライバーとモデルはそのステップを `init` として読むからです。
代わりに、モジュールに `action init = begin` を足してください。
quint_driver が投げる `ArgumentError` のバックトレースは、それを呼んだあなたの行から始まり、その前に quint_driver のフレームはありません。

期待（expectation）とは、すべての状態で成り立つべき述語です。
例えば `val one_book_each = MEMBERS.forall(m => BOOKS.filter(b => holder.get(b) == m).size() <= 1)` です。
その名前を、`spec:` と一緒に `Trace.replay` の `invariants:` に渡します。
各ステップでドライバーが仕様と一致したことを確かめたあと、モデルがそのステップの状態で期待を評価します。
偽になったときは `QuintDriver::Violated` を投げます。
これは `Mismatch` ではないので、`rescue QuintDriver::Mismatch` では捕まえません。
システムはどのステップでも仕様と一致したのに、それでも期待が成り立たない、という意味です。
メッセージは、``quint: the system agreed with the spec at every step, and the expectation `one_book_each` does not hold after step 4 `borrow` {"b" => "b3", "m" => "m2"}`` のように期待とステップを示します。
続けて `Mismatch` と同じく `init` からの手順を並べ、その状態での仕様の変数を `state:` の下に示し、同じ `trace:` の行で終わります。
述語でない名前を渡すと、最初のステップの前に `ArgumentError` を投げます。
`spec:` なしで `invariants:` を渡したときも同じです。

期待を破るトレースを quint に探させるには、その名前を `Quint.simulate` の `violate:` に渡します。
quint はそれを不変条件として検査します。
各トレースは期待が初めて偽になる状態で終わり、`Quint.simulate` は期待を破ったトレースだけを渡します。
渡されたトレースは、`invariants:` に同じ名前を渡して再生します。
システムがトレースと一致すれば、最後のステップで `QuintDriver::Violated` を投げます。
`reach:` と違い、どのトレースも期待を保ったときは、何も渡さず、何も投げません。
`Quint.simulate` は `QuintDriver::Quint::Simulation` を返します。
その `traces` は quint が動かしたトレースの数で、`violated` はそのうち期待を破ったトレースの数です。
`violate:` を渡さないときの `violated` は `nil` です。
`actions` はすべてのトレースで各アクションが取られた回数で、`never` は step アクションのうちどのトレースも取らなかったアクションの一覧です。
例えば `Quint.simulate("loans.qnt", traces: 50, max_steps: 20, seed: "1", violate: "one_book_each")` は `#<data QuintDriver::Quint::Simulation traces=50, violated=0, actions={"borrow" => 214, "borrow_refused" => 283, "give_back" => 161, "give_back_refused" => 342}, never=[]>` を返します。
`violate:` は `reach:` と同じく述語を受け取り、同じ理由で `backend: "rust"` を必要とします。
`reach:` と `violate:` を一緒に渡すと、quint を動かす前に `ArgumentError` を投げます。

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
- `invariants:` は期待、つまりすべての状態で成り立つべき仕様の述語の名前で、`Trace.replay` と同じように受け取ります。
Hegel は `init` と毎手のあとに、その手で仕様と一致したことを確かめてから期待を評価します。
偽になった期待は、縮めた手順を添えて `QuintDriver::Violated` を投げます。
例えば ``quint: the system agreed with the spec at every step, and the expectation `one_book_each` does not hold after step 2 `borrow` {"b" => "b2", "m" => "m1"}`` です。
述語でない名前を渡すと、`QuintDriver.machine` が `ArgumentError` を投げます。
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
import した定義は、モジュールのどこからも届かないものもすべて残ります。
モジュールに `step` という名前のアクションがなくても読めます。
そのモジュールには、コンパイルが 1 回増えます。

```ruby
QuintDriver::Quint.simulate("loans.qnt", traces: 200, max_steps: 30, seed: "7") do |path|
  QuintDriver::Trace.replay(path, spec.model)
end
```

モデルが評価できるのは、コマンドごとにアクションを書く仕様が使う演算子です。
集合 (`fold` と `i.to(j)` を含む)、マップ、レコード、タプル、リスト、`match` 付きの直和型、整数、真偽値です。
`Bool` は `false` と `true` の集合として評価します。
`Int` と `Nat` は無限なので、モデルはそこから選ぶ動きの候補を並べられず、`QuintDriver::Unsupported` を投げます。
代わりに `0.to(9)` のような有限の集合から選んでください。
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

`test/readme_test.rb` は「アプリなしで試す」を空のフォルダーで動かします。
Rails のクイックスタートと「実行結果」は、`QUINT_DRIVER_README_APP` がコピー元の Rails アプリを指すときだけ動かします。
そのアプリには、サンプルアプリと同じ rspec-rails、`Borrower`、`Loan` が要り、Gemfile に quint_driver があってはいけません。
テストはこのチェックアウトから作った gem を加え、ファイルを書き、コマンドを動かし、差分を当てて、各出力を README と比べます。

`test/skill_test.rb` は、スキルの例「A choice the code leaves to the database」を、`QUINT_DRIVER_SKILL_APP` がコピー元の Rails アプリを指すときだけ動かします。
そのアプリには、rspec-rails、`Batch` に属しブロック中は割り当てられない `Item`、`/session` と `/items/:id/release` のルートが要り、Gemfile に quint_driver があってはいけません。
テストはこのチェックアウトを加え、スキルのファイルを書き、トレースを再生し、ラップを外してから失敗をスキルと比べます。
アプリのデータベースを使うので、`DATABASE_URL` を指定すると PostgreSQL で動きます。

## ライセンス

MIT
