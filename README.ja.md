# code-guard

[English](README.md)

Claude Code にハーネスを組み込むプラグインです。ハーネスは、危ない操作をフックで止める仕組みです。検証ループは、応答を終える前にプロジェクト自身の検証を走らせ、その `verify.sh` は `/code-guard:setup-verify` で作れます。レビューのループと文書の照合は、0.3.0 で削除しました。

## 保証しないこと

- ガードはコマンドの文字列とファイルのパスを見る判定で、サンドボックスではありません。python などを経由した同じ操作は止められません。
- ガードはシェルを構文解析しません。読み切れない形 (引用符で囲んだ・分割したコマンド名やサブコマンド、引用符や展開で組み立てた `git push` の引数、守る対象のコマンドの行継続、読めない heredoc の印) は、判定せずに確認 (ask) に回します。[既知の制限](CHANGELOG.md#known-limits)を参照してください。
- Grep は、対象の `path` が機密値のファイルのときだけ止めます。ディレクトリを検索して結果に機密値のファイルが混ざる場合は止められません。
- 検証ループは Claude に直させる仕組みで、強制ではありません。`verify.sh` を通さずに終える方法は残ります。
- フックの入力の形やプラグインの仕組みは、Claude Code の版で変わることがあります。[動作を確かめた版](#動作を確かめた版)を見てください。
- リポジトリ側でプラグインを外せます。プロジェクトの `.claude/settings.json` の `enabledPlugins` は、ユーザーの設定より優先されます。Claude がこれらのファイルを書き換えるのは止まりますが (確認またはブロック)、クローンした時点で入っている設定は止められません。プラグインを外されるとフックは一つも動かないので、プラグイン自身では気づけません。知るための方法は「[リポジトリがプラグインを外すとき](#リポジトリがプラグインを外すとき)」にあります。

## 導入

ターミナルとデスクトップ版それぞれの手順、入ったことの確かめ方、設定、更新、削除は [docs/setup.ja.md](docs/setup.ja.md) にあります。要点だけ書くと、シェルで次を実行し、新しくセッションを始めます。

```bash
claude plugin marketplace add 103kaz/claude-code-guard
claude plugin install code-guard@claude-code-guard
```

bash 3.2 以上、`jq`、`perl` が要ります。対象は macOS と Linux で、Windows は対象外です。`jq` か `perl` が無いときは、そのフックが受け持つ操作をすべて止め、入れ方を返します。セッションの開始時にも、足りないものを知らせます (両方あるときは何も出しません)。

## 止めるもの

判定は 3 種類です。**block** は exit 2 で止め、承認しても通りません。**ask** はユーザーに確認の画面を出します。それ以外は通します。

### 中核のルール (外せません)

| 分類 | block | ask |
|---|---|---|
| 守るブランチ | 守るブランチへの push (そのブランチにいて引数なしの `git push`、`heads/main`、`cd` や `GIT_DIR=` で移った先のリポジトリも)、`:` だけやワイルドカードの refspec | 空のリモートへの初回 push |
| push の形 | `--no-verify`、`--mirror`、`--delete` / `-d` / `:ref`、`--prune`、`--all` | force push (`+ref` も)、`confirm_push` が有効なときの作業ブランチへの push |
| フックの回避 | `core.hooksPath`、`git -c`、`--config-env`、`GIT_CONFIG_*`、alias と include の設定、core / alias / include のセクションの削除、`HOME=` / `XDG_CONFIG_HOME=` を変えた git、`~/.gitconfig` / `~/.config/git/config` の書き換え、commit / merge の `--no-verify` (`commit -n`) | |
| 機密値 | `.env` / `.env.*` (サンプルを除く)、`*.tfvars`、`*.tfstate`、`*token*.txt`、`*.pem`、`*.key`、`~/.ssh`、署名資産、サービスアカウント鍵、CLI の認証情報、git の資格情報 (`~/.git-credentials`、`git credential fill`)、キーチェーンの値。`<`、`rev:`、`--opt=` の後の名前 (terraform の `-var-file=` は除く) と、展開するとこれらになるグロブやブレース (`.en?`、`.e{n,x}v`) も。名前は大文字小文字を区別しない (`.ENV`) | 文字列を組み立てるコマンド置換 (`cat $(printf .e%snv)`) |
| ハーネス | `~/.claude` の settings・フック・プラグイン、`.claude/settings*`、`.githooks`、`.git/config`、`.git/hooks` (`.git/modules/` の下のサブモジュールも) の Bash での書き換え。書き換えに数えるのは、リダイレクト、`sed` / `perl` / `ruby -i`、`awk -i inplace`、ファイルのコマンド、`dd`、`rsync`、`curl -o`、`wget -O`、`git checkout` / `restore` / `apply` / `am`。`cd` の後の相対パスも。保護パスは書き込み先だけで見るので、`cp ~/.claude/settings.json .` のようなコピー元の読み出しは止めません | `.claude/hooks`、`.claude/verify.sh`、`.github/workflows` の Bash での書き換え |
| 取得したコードの実行 | `curl` / `wget` の出力を、シェル (`/bin/sh`、`env bash` など。パイプの何段後でも) やインタプリタ (`python3`、`perl`、`node` など。curl のすぐ次の段か、後ろの段で標準入力からプログラムを読む形) に渡すパイプ | プロセス置換、`bash -c "$(curl ...)"`、`eval` |
| 消す操作 | ルートやホームへの `rm -r` (`--` や長いオプションの後も) | ビルドの生成物でないディレクトリの `rm -r`、`git clean`、`reset --hard`、`restore`、`checkout [<rev>] --`、`stash drop`、`branch -D`、`xargs rm`、`find -delete` / `-exec rm` |
| マシンの設定 | | `sudo`、`launchctl` の登録、`crontab`、`defaults write` |

守るブランチは、ブランチ名で判定します。使い捨ての一時リポジトリかどうかは見ないので、一時リポジトリでの `main` への push も止まります。例外は、届く空のリモートへの初回 push (force なし、リモート追跡ブランチがまだ無いとき) だけです (これは ask)。push を試すときは作業ブランチを使います。

コミットメッセージや PR 本文 (`-m`、`--body`、heredoc) に書いただけの文字列は判定しません。ただし `bash -c`、`eval`、python などを含むコマンドでは除きません。ダブルクォートの値や引用符の無い heredoc の中の `$(...)` とバッククォートは実行されるので、判定します。`git push` の refspec の規則 (`:`、`:` だけ、ワイルドカード、ブレース展開) は、引用符を外した文字列で判定するため、文字を探すだけ、表示するだけのコマンド (`grep -n "git push *" f`) が push に読めてしまいます。コマンド全体が、`grep`、`egrep`、`fgrep`、`rg`、`ag`、`echo`、`printf`、`head`、`tail`、`wc`、`ls`、`cat` の区間を `&&`、`||`、`;`、`|` でつないだものだけで、どの引数も、ふつうの語か、`$`・バッククォート・エスケープを含まない引用符の文字列であるときに限り、その引用符の中の文字列を読みません。`-` で始まる語 (オプション) は、`-n` や `-rn` のような、引用符のない短いオプションの連なりだけを認めます。`rg` と `ag` にはプログラムを実行するオプション (`--pre`、`--pager`、その略称、シェルが `--pre` に直す `--p'r'e`) があるため、長いオプションと引用符で書いたオプションは認めません。ほかのコマンド (`$(...)`、`<(...)`、`#`、改行、リダイレクト、プログラムを実行するオプション (`--pre`、`--pager`)、そのほかのコマンドを含むもの) は、これまでどおり判定します。引用符の無い言及 (`echo git push *`) も、これまでどおり判定します。

### ファイルのツール (`guard-file.sh`)

プラグインは permissions を配れないので、フックで止めます。

| ツール | block | ask |
|---|---|---|
| Read、Grep | 機密値のファイル (中核の機密値と同じパターン) | |
| Edit、Write、MultiEdit、NotebookEdit | `*.tfvars`、`.git/config`、`.git/hooks`、`~/.gitconfig`、`~/.config/git/config` | `~/.claude`、`.claude/settings*`、`.claude/hooks`、`.claude/verify.sh`、`.githooks`、`.github/workflows` |

### MCP ツール (`guard-mcp.sh`)

ツール名に `delete`、`destroy`、`drop`、`purge`、`remove`、`truncate`、`wipe`、`erase`、`deploy`、`publish`、`unpublish`、`rollback`、`secret` の語があるか、`merge_pull_request`、`merge_branch`、`push_files`、`push_branch`、`force_push`、`create_or_update_file`、`update_file`、`create_commit`、`update_ref` なら ask です。ブランチに書くもの (`push_files`、`push_branch`、`force_push`、`create_or_update_file`、`update_file`、`create_commit`、`update_ref`、ブランチを指定した `delete_file`、`create_file`、`write_file`、`edit_file`、`commit_files`) は、引数の `branch` か `ref` (入力の入れ子の中も読みます) が守るブランチなら block です。名前に `push` の語があるツール (`git_push`、`push`) も同じ扱いで (`refspec` は行き先を読みます)、`branch`、`ref`、`refspec` の引数があるか、名前の最後の語が `push` (`git_push` は引数なしで今のブランチを push する) なら ask です。`query`、`sql`、`execute`、`exec`、`statement`、`statements`、`migration`、`migrations`、`migrate` のツールは、入力に変更系の語 (`DROP`、`DELETE`、`UPDATE`、`INSERT`、`MERGE`、`GRANT`、`REVOKE`、`COPY` など。コメントは外して読みます) があるとき ask です。ほかのツールは、項目名が `sql`、`statement`、`statements`、`stmt` の値 (入れ子の中も) だけを同じ規則で読み、変更系の語があれば ask です。`text`、`message`、`query`、`q` などほかの項目は読まないので、文の形に読める文章は通り、別の名前の項目に入れた SQL も通ります。名前が `get`、`list`、`search`、`read`、`describe`、`fetch`、`find`、`view`、`show` で始まるツールは、入力を見ません。ただし名前に書く語 (`or`、`and`、`then`、`create`、`update`、`insert`、`upsert`、`set`、`put`、`write`、`add`、`apply`、`replace`、`save`、`edit`、`modify`、`send`) が混じるもの (`get_or_create`、`find_and_replace`) は見ます。`jq` か `perl` が無いときは、MCP のツールをすべて止めます。

### サンドボックスの除外コマンドへの連結 (`guard-chain.sh`)

サンドボックスが有効なとき、`sandbox.excludedCommands` に載るコマンドがサンドボックスの外で動くのは、コマンド全体がそれ 1 つのときだけです。`&&`、`||`、`;`、`|`、改行でつなぐとサンドボックスの中で動き、失敗します (`.git` への git の書き込み、`gh` の呼び出し)。このガードは `~/.claude/settings.json`、`.claude/settings.json`、`.claude/settings.local.json` から `sandbox.enabled` と `sandbox.excludedCommands` を読み、そのような連結を block して、1 コマンドずつ別の呼び出しにするよう返します。引用符の中、`2>&1` などのリダイレクト、heredoc の本文は区切りに数えません。パターンは 1 つのセグメント全体に照合し、末尾の空白とアスタリスク (`git push *`) や `:*` は、引数のないコマンドにも一致します。`git` のように 1 語だけのパターンは、その語だけのコマンドに一致します。最後まで読めないコマンド (閉じていない引用符) は通します。見落とす形は、`$(...)` や `bash -c "..."` の中の連結、環境変数の接頭辞 (`FOO=1 git push && ls`)、サブシェル、`if ...; then ...; fi` です。サンドボックスが無効なとき、パターンが無いとき、設定を読めないときは何もしません。使いやすさのための補助で、セキュリティのガードではなく、外す設定もありません。

### パック

既定ではすべて有効です。方針が自分の運用に合わないときに外します。パックを外しても、機密値の読み出しは中核で止まります。

| パック | 判定 |
|---|---|
| `github` | block: `gh secret set/delete`、`gh variable delete`、`gh repo delete`、`gh release delete`、`gh pr merge --admin/--auto`、`gh repo edit --visibility`、`gh api` の変更系 (リポジトリ設定の経路への単独の呼び出しは ask)。ask: `gh pr merge`、`gh workflow run`、`gh release create`、`gh gist create` |
| `terraform` | block: `destroy`、`import`、`taint`、`untaint`、`force-unlock`、state の変更、plan と apply を 1 コマンドで、`-auto-approve` など。ask: 保存した plan ファイルの `apply`。`.tf` を Edit / Write した後に `terraform fmt` |
| `gcp` | block: ディスク・インスタンス・プロジェクト・ストレージ・SQL インスタンスの削除、`gsutil rm/rb`、Secret Manager の値とアクセストークンの出力 |
| `cloudflare` | block: `wrangler` の deploy / delete / rollback / secret の変更 |

## 検証ループ

ファイルを変えたまま応答を終えようとしたとき、プロジェクトに `.claude/verify.sh` があれば Stop フックが走らせます。失敗したら出力の末尾 80 行を Claude に返します (exit 2)。1 回の中で `verify_max_retry` 回 (既定 3) 失敗したら、ユーザーに知らせて通します。`.claude/verify.sh` が無ければループは動きません。ファイルが変わっていたときは、`/code-guard:setup-verify` で作れることをセッションにつき 1 回知らせます (`verify_missing_notice` で止められます)。

「変わったか」は、プロンプトを送った時点の HEAD、追跡中のファイルの差分、追跡外のファイルの指紋と比べます。回の前からある変更だけでは走りません。git の外では、プロンプトを送った後に変わった・名前を変えた・消したファイルがあれば走ります。

クローンしたリポジトリの `verify.sh` は他人が書いたコードなので、ループが走らせるのは、あなたが承認した内容のときだけです。承認するまでは走らせず、セッションにつき 1 回だけ知らせます。中身を読んだうえで、ターミナルで承認します。

```bash
bash <プラグインのディレクトリ>/scripts/trust-verify.sh [プロジェクトのディレクトリ]
```

ファイルの全体 (制御文字は見える形にして。日本語のコメントなど、表示できる UTF-8 はそのまま) と SHA-256 を表示し、`yes` と打ったときだけ承認します。承認はプロジェクトのディレクトリごとに `~/.claude/code-guard/verify-trust/` の下へ残り、ファイルを変えると外れます。シンボリックリンクの `verify.sh` は承認しません。Claude が `trust-verify.sh` (や承認のコード) を実行しようとすると Bash のガードが ask にし、Bash から承認のファイルを書くのは block なので、Claude が自分で `yes` と答えても、あなたの確認が要ります。ask は補助で、実行時に組み立てた名前は通ります。承認が及ぶのは `verify.sh` 自身で、それが呼ぶファイル (`make`、`npm test`、`bash scripts/ci.sh`) には及びません。

`/code-guard:setup-verify` で雛形を作れます。ビルドの設定を見て速い lint とテストを提案し、同意を得てから書きます。

### pre-push や CI から同じ検査を呼ぶ

Stop フックが走らせるのは `.claude/verify.sh` だけです。同じ検査を別の場所 (`.githooks/pre-push`、CI) からも呼びたいときは、`.claude/verify.sh` を薄い入口にして、検査の本体をプロジェクトのスクリプトに置きます。

```bash
#!/bin/bash
exec "${CLAUDE_PROJECT_DIR:-.}/scripts/verify.sh"
```

`.githooks/pre-push` や CI は `scripts/verify.sh` を直接呼びます。承認の対象は `.claude/verify.sh` の中身だけで、そこから呼ぶファイルは含まれません。入口を承認した後で `scripts/verify.sh` が変わると (他人のコミットを `git pull` したときなど)、あらためて確認されずに走ります。この形は、中身を信頼できるリポジトリだけで使います。クローンしたリポジトリでは、検査を `.claude/verify.sh` に直接書きます。

## トークンの消費

コンテキストを食わないように作っています。

- ガードと、回の始めを記録するフックは、通ったときは何も出力しません。block と ask のときだけ数行が足されます。
- セッションに常に載るのは、スキル `/code-guard:setup-verify` の 1 行の説明だけです。手順の本文は実行したときだけ読み込まれ、ビルドの設定は最小限だけ読むよう書いてあります。
- 失敗した `verify.sh` が返すのは、80 行かつ 6000 バイトまでです。`verify.sh` は成功時に静かで、速く終わるようにしてください (`--quiet` などが効きます)。

## 設定

`/plugin` の設定の画面で変えます。読まれるのはユーザーと managed の settings だけで、プロジェクトの settings からは渡せません。

| キー | 既定 | 内容 |
|---|---|---|
| `protected_branches` | `main`、`master` | push を block するブランチ (`*` は任意の並びに合う: `release/*`) |
| `confirm_push` | `false` | 作業ブランチへの push に確認を出す |
| `pack_github` / `pack_terraform` / `pack_gcp` / `pack_cloudflare` | `true` | パックの有効・無効 |
| `verify_missing_notice` | `true` | `.claude/verify.sh` が無いままファイルが変わったとき、セッションにつき 1 回知らせる |
| `verify_max_retry` | `3` | 検証ループの 1 回あたりのやり直しの回数 (1〜10) |

プロジェクトごとの上書きはできません。

## リポジトリがプラグインを外すとき

プロジェクトの `.claude/settings.json` や `.claude/settings.local.json` の `enabledPlugins` はあなたの設定より優先され、外されたプラグインはフックを一つも動かさないので、code-guard は内側から警告できません。知るには、プラグインの外にあたる自分の settings に、`scripts/check-enabled.sh` を SessionStart のフックとして登録します。プロジェクトの settings が `code-guard@...` を `false` にしているときだけ警告を出し、止めはしません。

`scripts/check-enabled.sh` を `~/.claude/hooks/code-guard-check-enabled.sh` にコピーし、`~/.claude/settings.json` に次を足します。

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "bash \"$HOME/.claude/hooks/code-guard-check-enabled.sh\"" } ] }
    ]
  }
}
```

Claude が `~/.claude` を書き換えるのは止まるので、あなたの手で行ってください。`jq` が要ります。見るのはその 2 つのプロジェクトのファイルだけで、managed settings など別の場所での無効化は見ません。上書きできないようにするには、`enabledPlugins` を managed settings に置きます。

## サンドボックスとの併用

サンドボックスは OS のレベルで書き込みと通信を絞ります。code-guard は操作の意味 (main への push、`terraform destroy` など) で止めます。役割が違うので、併用できます。プラグインからはサンドボックスを設定できないので、自分の settings に書きます。

```json
{
  "sandbox": {
    "enabled": true,
    "allowUnsandboxedCommands": false,
    "excludedCommands": ["gh pr *", "gh issue *", "gh api *", "gh run *", "gh auth status"],
    "network": { "allowedDomains": ["github.com"] }
  }
}
```

空のリモートへの初回 push かどうかは `git ls-remote` で判定します。これは外向きの通信を使うので、リモートのホストが `allowedDomains` に無いと失敗し、ガードは block に倒れます。`excludedCommands` は、使う `gh` のサブコマンドに合わせて変えます。

`excludedCommands` が一致するのは、コマンドの先頭だけです。`cd x && gh pr view` のような複合コマンドは除外されず、サンドボックスの中で動くので、除外したいコマンドは単独で実行します。

Claude Code 2.1.293 と上の設定で確かめました。2 つのテストスクリプトは通り、github.com への `git ls-remote` は成功し、プロジェクト外への書き込みは Operation not permitted で失敗し、他のホストは 403 で拒否されます。

## 動作を確かめた版

Claude Code 2.1.293 で開発しています。フックには `onFailure: "block"` を付けています。これは 2.1.295 以降の機能で、2.1.306 で `tests/manual-check-onfailure.sh` により確かめました。PreToolUse のフックが exit 1 になる、時間切れになる、起動できないときは、ツールの呼び出しが止まります。キーが無い exit 1 は止まりません。2.1.295 から 2.1.305 は試していません。古い版ではこのキーが無視され、終了コードによる動作になります。

## 開発

```bash
bash tests/test-guard.sh    # ガード、パック、設定 (チェックは並列に走る。GUARD_TEST_JOBS で数を変えられる。最大 8)
bash tests/test-verify.sh   # 検証ループ
bash tests/test-check-deps.sh  # セッション開始時の依存の確認
bash tests/test-check-enabled.sh  # プロジェクトがプラグインを外すときの警告
bash tests/test-chain.sh  # サンドボックスの除外コマンドへの連結
bash tests/test-defaults.sh  # plugin.json の default とフック側の既定が一致するか
bash tests/manual-check-onfailure.sh  # ログイン済みの claude が要る: onFailure "block" がツールの呼び出しを止めるかの確認 (CI では流さない)
bash tests/manual-check-multiple.sh  # ログイン済みの claude が要る: multiple の設定がフックに渡る形の確認 (CI では流さない)
```

ガードの判定を変えるときは、先に `tests/test-guard.sh` にケースを足します。

## ライセンス

MIT
