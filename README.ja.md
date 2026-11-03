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
ファイルの中身が変わると、もう一度コンパイルします。
仕様が import するファイルの変更は、プロセスを起動し直すまで反映されません。

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
`Quint.simulate` の中で起きたときは、再生したファイルはもう消えています。
そのため、メッセージはトレースをファイル名とシードで示し、同じトレースをもう一度書く呼び出しで終わります。
再生の様子を見るときは `Trace.replay` に `log: $stdout` を渡します。
ドライバーが動かす前に、`step 1 borrow {"b" => "b1", "m" => "m2"}` のように各ステップを書き出します。
Minitest のテストでも RSpec の example でも同じコードで動きます。
RSpec で自分の example から値を引くときは `Hegel::Syntax::Methods` を include してください。
machine 自体には不要です。

`Quint.simulate` は、ファイル名と同じ名前のモジュールを動かします。
同じファイルの別のモジュールを動かすときは `main:` を渡します。
`Spec.new` に渡すのと同じ名前です。
quint が失敗したときや見つからないときは、`Spec.new` と `Quint.simulate` が quint の理由を添えて `QuintDriver::QuintFailed` を投げます。

`QuintDriver.machine` のオプションは次のとおりです。

- `step:` は手の一覧を持つアクションで、既定は `"step"` です。各手は名前のあるアクションを呼ぶ必要があります。引数は `nondet x = S.oneOf()` から取ります。
- `invariants:` は、毎手のあとに成り立つべき仕様の `val` の名前です。
- `choose:` は Hegel が手を引く方法です。`:rule`(既定)はアクションを選び、仕様が許さなければ捨てます。最短の手順まで縮みます。`:rotate` は許されないアクションの番を次の許されるアクションに回します。少ないテストケースで深い状態に届きますが、縮めた手順に余分な手が残ることがあります。

各テストケースは、ドライバーの `init` で新しいシステムから始めます。
縮める処理は同じ手順を何度も求めるので、システムが一度一致した手順は再び動かしません。
これは、同じ手順にはシステムが毎回同じ答えを返すことを前提にしています。
食い違った手順は、毎回システムで動かし直します。

## Ruby のモデルを確かめる

Hegel のやり方は、仕様の Ruby での評価を信じています。
モデルもドライバーと同じ受け答えをするので、Quint 自身のトレースに照らして確かめられます。

```ruby
QuintDriver::Quint.simulate("loans.qnt", traces: 200, max_steps: 30, seed: "7") do |path|
  QuintDriver::Trace.replay(path, spec.model)
end
```

モデルが評価できるのは、コマンドごとにアクションを書く仕様が使う演算子です。
集合 (`fold` と `i.to(j)` を含む)、マップ、レコード、タプル、リスト、`match` 付きの直和型、整数、真偽値です。
リストは Ruby の Array になります。
リストでは `List`、`append`、`concat`、`head`、`tail`、`length`、`nth`、`indices`、`replaceAt`、`slice`、`range`、`select`、`foldl` を評価します。
整数では `+`、`-`、`*`、単項の `-`、比較を評価します。
`/` は両辺が負でないときだけ評価します。
Quint は負の値を割ったときの丸めを決めていないからです。
空のリストの `head` や、末尾より先の `nth` のように、Quint のドキュメントが未定義とする演算では、モデルは答えを選ばずに `QuintDriver::Unsupported` を投げます。
ただし `slice(l, l.length(), l.length())` は、Quint の二つの評価器と同じく `[]` です。
`foldr` や `%` など、それ以外の演算子は `QuintDriver::Unsupported` を投げるので、足りない仕様ははっきり失敗します。
アクションを名指ししない step の枝も同じです。
メッセージには、その演算子を書いたアクションか定義の名前が入ります。
例えば `quint: no evaluation for operator foldr in summed` です。

モデルは `Spec#model` で作ります。
モデルは quint がコンパイルした IR の形を信用するので、`Model.new` は private です。
トレースは選択値を素の値で渡し、モデルはその定義域から同じ値に読める値を取るので、直和型の選択値も `match` で使えます。

`model.moves(rule)` は、`spec.rules("step")` のルールがモデルの今の状態で許す手を、`[アクション, 選択値, 次の状態]` の形で、決まった順に並べます。
`model.enter(次の状態)` でその手を取ります。
Hegel のマシンはこの方法で手を選びます。

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
