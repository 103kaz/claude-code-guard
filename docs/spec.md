# code-guard 仕様 (v1)

Claude Code のプラグイン `code-guard` の仕様。Claude Code が実行しようとする危ない操作をフックで止め、ファイルを変えたまま応答を終えようとしたらプロジェクトの検証を走らせる。

## 決まっていること

| 項目 | 決定 |
|---|---|
| リポジトリ | `103kaz/claude-code-guard` |
| プラグイン名 | `code-guard` (`claude-` で始まる名前は予約されていて使えない) |
| v1 の範囲 | ガードと検証ループ。補助のスキルとして、`setup-verify` (検証ループの雛形) と `doc-code-consistency` (文書と実装の照合) |
| 中核のルール | 利用者は緩められない。設定で変えられるのは、守るブランチ、パックの有効・無効、検証ループのやり直しの回数など |
| 言語 | Claude に返すメッセージは英語。README は英語と日本語 |
| 依存 | bash 3.2 以上、jq、perl。macOS と Linux。Windows は対象外 |

## 構成

```text
claude-code-guard/
├── .claude-plugin/
│   ├── plugin.json         # メタデータと userConfig
│   └── marketplace.json    # このリポジトリ自体をマーケットプレイスにする
├── hooks/
│   └── hooks.json          # フックの登録
├── scripts/
│   ├── guard-bash.sh       # PreToolUse(Bash)
│   ├── guard-file.sh       # PreToolUse(Read|Edit|Write|MultiEdit|NotebookEdit|Grep)
│   ├── guard-mcp.sh        # PreToolUse(mcp__.*)
│   ├── fmt-terraform.sh    # PostToolUse(Edit|Write): .tf を整形
│   ├── verify-loop.sh      # UserPromptSubmit と Stop
│   ├── doc-check.sh        # PostToolUse(Skill) と PreToolUse(Bash|mcp__.*): PR の前の照合 (doc_check_before_pr)
│   └── lib/                # 共通の関数 (判定結果の出力、設定の読み込み)
├── skills/
│   ├── setup-verify/
│   │   └── SKILL.md        # /code-guard:setup-verify
│   └── doc-code-consistency/
│       └── SKILL.md        # /code-guard:doc-code-consistency (文書と実装の照合)
├── tests/
│   ├── test-guard.sh
│   ├── test-verify.sh
│   └── test-doc-check.sh
├── docs/
│   └── spec.md
├── .github/workflows/
│   └── ci.yml              # PR は ubuntu、main への push は ubuntu と macOS でテストを流す
├── .claude/
│   ├── CLAUDE.md           # このリポジトリで作業するときの決まり
│   └── review/checklist.md # 敵対的レビューの観点 (このリポジトリ用)
├── README.md
├── README.ja.md
├── CHANGELOG.md
├── SECURITY.md
└── LICENSE
```

フックは `"${CLAUDE_PLUGIN_ROOT}"/scripts/...` で参照する。状態は `${CLAUDE_PLUGIN_DATA}` に置き、`${CLAUDE_PLUGIN_ROOT}` には書かない (更新で場所が変わる)。

## ガード

### 判定の種類

| 種類 | 動き | 使う場面 |
|---|---|---|
| block | exit 2 で止め、理由を stderr で Claude に返す。承認しても通らない | 確実に危ない操作 |
| ask | `permissionDecision: "ask"` を返し、ユーザーに確認の画面を出す | 正当な用途がある操作、誤検知がありうる判定 |
| 通す | 何も出さずに exit 0 | それ以外 |

1 つのコマンドが複数の判定に当たったときは、block を優先する。ask の理由は連結して最後に 1 回だけ出す。

block を `permissionDecision: "deny"` ではなく exit 2 にするのは、フックが壊れたときに止める側へ倒すためだ。公式ドキュメント (hooks の「Exit code 2」「PreToolUse decision control」) によると、PreToolUse で exit 2 にすると、stderr が deny の理由と同じ経路で Claude に届く。一方 deny は exit 0 で JSON を出す形なので、JSON が壊れるとフックの失敗 (non-blocking error) になり、ツールは実行される。exit 2 は、stdout の JSON が壊れていても止まる。ファイルのツール (Read など) の block も exit 2 にそろえる。

Claude Code 2.1.295 以降には、フックの `onFailure: "block"` がある。フックが起動できない、時間切れ、0 と 2 以外の終了コードのときに、操作を止める設定だ。ガードのフックにはこれを付け、動作を確かめた最低の版を README に書く (手元の 2.1.293 にはまだ無く、試していない)。

block の理由には、Claude が回避策を探さず、人間が実行するコマンドをユーザーに示すよう書き添える。

```text
BLOCKED by code-guard: reading secret files (.env, *.tfvars, *.tfstate, keys) is not allowed.
This is a policy block, not a hook failure. Do not retry it another way (another command, a script, python). Tell the user why it was blocked and give them the command to run themselves.
```

### 依存が無いとき

jq が無いとフックの入力を読めない。そのときは、そのフックが受け持つ操作をすべて block し、jq の入れ方を返す (迷ったら止める)。perl も同じ扱いにする。

### 中核のルール (Bash)

設定で外せない。

| 分類 | block | ask |
|---|---|---|
| 守るブランチ | 守るブランチへの push (初回を除く)。守るブランチにいて引数なしの `git push`、`heads/main` (`refs/` を省いた形)、`cd` / `pushd` や `GIT_DIR=` で移った先のリポジトリでの push も含む。`:` だけ (一致するブランチをすべて push) とワイルドカードの refspec | 空のリモートへの初回 push |
| push の形 | `--no-verify`、`--mirror`、`--delete` (`-d` と `:` で始まる refspec を含む)、`--prune`、`--all` | force push (`+` で始まる refspec を含む) |
| フックの回避 | `core.hooksPath` の変更、`git -c` と `--config-env`、`GIT_CONFIG_*`、alias と include の設定、core / alias / include のセクションの削除と名前の変更 (`--remove-section` と新しい書式の `remove-section`)、`HOME=` / `XDG_CONFIG_HOME=` を変えて git を動かすこと、`~/.gitconfig` と `~/.config/git/config` の書き換え、commit / merge / rebase などの `--no-verify` と `commit -n` | |
| 機密値 | `.env` と `.env.*` (サンプルを除く)、`*.tfvars`、`*.tfstate`、`*token*.txt`、`*.pem`、`*.key`、`~/.ssh`、署名資産 (`*.p8`、`*.p12`、`*.mobileprovision`、`AuthKey_*`)、サービスアカウント鍵、CLI の認証情報 (`~/.aws`、`~/.config/gcloud`、gh のトークン、`~/.kube`、`~/.docker`、`~/.netrc` など)、git の資格情報 (`~/.git-credentials`、`~/.config/git/credentials`、`git credential fill` / `get`)、キーチェーンの値。名前の直前がリダイレクト (`<`)、`rev:`、`--opt=` の形 (terraform に渡すだけの `-var-file=` は除く) と、展開するとこれらの名前になるグロブやブレース展開 (`.en?`、`.e{n,x}v`、`--include=*.tfvars`) も含む。名前は大文字小文字を区別せずに比べる (macOS の既定のボリュームでは `.ENV` で `.env` が読める)。ただし先頭だけ大文字の `.Key` は JSON のフィールド (`jq '.Item.Key'`) によくあるので止めない。グロブは区別して比べる (bash がディスク上の名前と区別して照らすため)。`*`、`*.*`、`.*` だけの語は判定しない | |
| ハーネス | `~/.claude` の settings とフック、`.claude/settings*`、`.githooks`、`.git/config`、`.git/hooks` (`.git/modules/` の下の入れ子のサブモジュールも)、プラグインの置き場所 (`~/.claude/plugins`) の Bash での書き換え。書き換えに数えるのは、リダイレクト、`sed` / `perl` / `ruby` の `-i`、`awk -i inplace`、`rm` / `mv` / `cp` / `tee` / `chmod` (`+x` だけは除く) / `ln` / `truncate` / `install` / `dd` / `rsync`、`curl -o` / `-O`、`wget -O`、`git checkout` / `restore` / `apply` / `am`。`cd` / `pushd` の後の相対パスは、移った先のパスとして読む。パスの中の `//` は `/` と同じに扱う | プロジェクトの `.claude/hooks`、`.claude/verify.sh`、`.github/workflows` の Bash での書き換え |
| 取得したコードの実行 | `curl` / `wget` の出力をシェル (`/bin/sh` のようなパス、`env` / `sudo -E` / `command` を挟む形を含む) やインタプリタ (`python`、`perl`、`ruby`、`node`、`deno`、`bun`、`php`、`lua`、`osascript`) に渡すパイプ。シェルはパイプの何段後でも、インタプリタは curl のすぐ次の段 (間に `tee` / `cat` だけを挟む形を含む。`\| python3 -m json.tool` も含む) か、後ろの段で標準入力からプログラムを読む形 (引数なしか `-`) | プロセス置換、`bash -c "$(curl ...)"`、`eval "$(curl ...)"` |
| 消す操作 | ルートやホームを対象にした `rm -r` (対象のどの位置でも。`--` や `--recursive` の後も) | ビルドの生成物でないディレクトリの `rm -r`、`git clean`、`reset --hard`、`restore`、`checkout --` と `checkout <rev> -- <path>`、`stash drop`、`branch -D`、`xargs rm`、`find -delete` と `find -exec rm` |
| マシンの設定 | | `sudo`、`launchctl` の登録、`crontab` (`-l` を除く)、`defaults write` / `delete` |

コミットメッセージや PR 本文 (`-m`、`--body`、heredoc の本文) に書いただけの文字列は判定から除く。`bash -c` や `eval`、python などを含むコマンドでは除かない。ダブルクォートの値と引用符の無い heredoc の本文のうち、`$(...)` やバッククォートを含むものは実行されるので除かない。

### ファイルのツールのガード

プラグインは `permissions` の deny / ask を配れない (プラグインの settings で効くのは `agent` と `subagentStatusLine` だけ)。その代わりに、PreToolUse のフック `guard-file.sh` で止める。

| ツール | block | ask |
|---|---|---|
| Read、Grep | 中核の「機密値」と同じパターンのファイル | |
| Edit、Write、MultiEdit、NotebookEdit | `*.tfvars`、`.git/config`、`.git/hooks` (サブモジュールの `.git/modules/` の下も含む)、`~/.gitconfig`、`~/.config/git/config` | `~/.claude` の下、`.claude/settings*`、`.claude/hooks`、`.claude/verify.sh`、`.githooks`、`.github/workflows` |

Grep は、対象の `path` が機密値のファイルのときだけ止める。ディレクトリを検索して結果に機密値のファイルが混ざる場合は止められない。この限界は README に書く。

Glob はファイル名を返すだけなので対象にしない。

### MCP のガード

ツール名に削除・公開・秘密の変更を表す語 (`delete`、`destroy`、`drop`、`purge`、`remove`、`truncate`、`wipe`、`erase`、`deploy`、`publish`、`unpublish`、`rollback`、`secret`) か、ブランチへの書き込みを表す名前 (`merge_pull_request`、`merge_branch`、`push_files`、`push_branch`、`force_push`、ブランチに直接コミットする `create_or_update_file`、`update_file`、`create_commit`、ref を動かす `update_ref`) があれば ask。SQL を受けるツール (`query`、`sql`、`execute`、`exec`、`migration`、`migrations`、`migrate`) で変更系の語 (`drop`、`delete`、`truncate`、`alter`、`update`、`insert`、`replace`、`create`、`merge`、`grant`、`revoke`、`rename`、`upsert`、`copy`) なら ask。`/* */` と `--` のコメントは外し、語の直後が空白・引用符・括弧の形も見る。ほかのツールは、入力が変更系の文の形 (`delete from`、`insert into`、`replace into`、`merge into`、`update <名前> set` (別名と `join` を含む)、複数テーブルの `delete <名前> from`、`into` を省いた `insert <名前> values`、`rename table`、`drop` / `alter` / `truncate` / `create` の後に `table` や `index` などの対象の語、`grant` / `revoke` の後に権限の語) のとき ask (`apply_migration` や `run` のように名前に語が無いツールも見るため)。その形に読める文章も ask になる。名前が読むだけの語 (`get`、`list`、`search`、`read`、`describe`、`fetch`、`find`、`view`、`show`) で始まるツールは、SQL を受けるツールを除き、入力を見ない。`jq` か `perl` が無いときは、MCP のツールをすべて block する。

### パック

特定のツールに向けた判定。既定ですべて有効にし、`userConfig` で外せる。そのツールを使わない人には当たらないので、有効のままでも害は無い。外すのは、パックの方針 (たとえば terraform の apply を保存した plan ファイルに限る) が自分の運用と合わないとき。

| パック | 判定 |
|---|---|
| `github` | block: `gh secret set/delete`、`gh variable delete`、`gh repo delete`、`gh release delete`、`gh pr merge --admin/--auto`、`gh repo edit --visibility` (`gh api` 経由の公開範囲の変更を外しているのと揃える)、`gh api` の変更系 (リポジトリ設定の経路への単独の呼び出しは ask)。ask: `gh pr merge`、`gh workflow run`、`gh release create`、`gh gist create` |
| `terraform` | block: `destroy`、`import`、`taint`、`untaint`、`force-unlock`、`state` の変更、plan と apply を 1 コマンドで、apply の `-auto-approve` など。ask: 保存した plan ファイルを指定した `apply`。Edit / Write の後に `terraform fmt` |
| `gcp` | block: ディスク・インスタンス・プロジェクト・ストレージ・SQL インスタンスの削除、`gsutil rm/rb`、Secret Manager の値とアクセストークンの出力 |
| `cloudflare` | block: `wrangler` の deploy / delete / rollback / secret の変更 |

機密値の読み出し (`~/.config/gcloud` など) はパックではなく中核に置く。パックを外しても、機密値は読ませない。

### push の確認

作業ブランチへの `git push` (force 無し) に確認を出すかは、`userConfig` の `confirm_push` で選べる (既定は有効)。守るブランチへの push の block と force push の ask は、この設定によらない。push 先が読めない形 (引数のブレース展開や `$@` / `$*`、`xargs`、`parallel`、`find -exec` から呼ぶ `git push`。コマンド名は大文字小文字を区別しない) も、この設定によらず ask。

## 検証ループ

ファイルを変えたまま Claude が応答を終えようとしたら、プロジェクトの `.claude/verify.sh` を走らせる。失敗したら出力を Claude に返し、直させる。

| 項目 | 仕様 |
|---|---|
| 走る条件 | プロジェクトに `.claude/verify.sh` があり、回の始め (UserPromptSubmit) から作業ツリーが変わっている (回の中のコミットを含む) |
| `verify.sh` が無いとき | 何もしない。メッセージも出さない |
| 変わったかの判定 | HEAD、追跡中のファイルの差分、追跡外のファイルの名前と中身をまとめた指紋で比べる。コミットがまだ無いリポジトリでは、HEAD との差分の代わりに index と作業ツリーの差分を使う。git の外では、回の始めに置いた印のファイルより後に変わったファイルがあるか、ファイルの一覧 (名前の変更と削除) が変わったかで決める |
| 失敗したとき | exit 2 で止め、出力の末尾 80 行を Claude に返す |
| やり直しの回数 | `userConfig` の `verify_max_retry` (既定 3)。最後の回では、直せなければ報告して終えるよう伝える。超えたらユーザーに systemMessage で知らせて通す |
| 時間切れ | 600 秒 |
| 状態の置き場所 | `${CLAUDE_PLUGIN_DATA}/verify/<session_id>.*` |
| `verify.sh` の編集 | ガードが ask にする (テストを消して通すのを防ぐ) |

雛形は `/code-guard:setup-verify` のスキルで作る。スキルはプロジェクトの言語とビルドの設定 (`package.json`、`pyproject.toml`、`go.mod` など) を見て、速く終わる lint とテストを入れた `.claude/verify.sh` を提案する。書き込む前にユーザーに中身を見せる。

検証ループは Claude に直させるための仕組みで、強制ではない。`verify.sh` を通さずに終える方法は残る。

## 文書の照合

`/code-guard:doc-code-consistency` のスキル。文書 (README、`docs/`、`CLAUDE.md`、`CHANGELOG`、コメント) から実装に照らして真偽が決まる主張を抜き出し、1 つずつコードと照らす。結果は、矛盾・陳腐化・記載漏れ・要判断・未検証に分けて、file:line の証拠付きで報告する。

| 項目 | 決定 |
|---|---|
| 書き込み | しない。直すのは、ユーザーが頼んだときだけ |
| 実行 | 副作用の無い読み取りだけ (`--help`、`git grep` など)。文書に書かれたコマンドを確かめるために実行しない |
| 機密値 | 中核の機密値のファイルは読まない |
| 範囲 | 指定に従う。PR の前は、ブランチの差分の変更行に含まれる主張と、差分で変えた実装に触れている既存の記述 |
| トークン | 常に載るのは 1 行の説明だけ。手順の本文は実行したときに読み込まれる |
| PR の前の照合 | `userConfig` の `doc_check_before_pr` (既定は無効)。有効なとき、PostToolUse(Skill) のフック (`scripts/doc-check.sh record`) が、同梱のスキル (`code-guard:doc-code-consistency`。同じ名前の個人のスキルは数えない) を始めた時点の HEAD をリポジトリごとに記録する (`${CLAUDE_PLUGIN_DATA}/doc-check/`)。PreToolUse(Bash\|mcp__.*) のフック (`scripts/doc-check.sh gate`) は、`gh pr create` と MCP の `create_pull_request` で、PR にするブランチの先頭 (`--head` / `head`、無ければ HEAD) が記録と違えば block する。記録は照合の結果によらず残るので、強制ではない |

## 設定 (userConfig)

| キー | 型 | 既定 | 内容 |
|---|---|---|---|
| `protected_branches` | `string` (`multiple: true`) | `["main", "master"]` | push を block するブランチ |
| `confirm_push` | 真偽値 | `true` | 作業ブランチへの push に確認を出す |
| `pack_github` | 真偽値 | `true` | github パック |
| `pack_terraform` | 真偽値 | `true` | terraform パック |
| `pack_gcp` | 真偽値 | `true` | gcp パック |
| `pack_cloudflare` | 真偽値 | `true` | cloudflare パック |
| `doc_check_before_pr` | 真偽値 | `false` | PR を作る前に `/code-guard:doc-code-consistency` の照合を求める |
| `verify_max_retry` | 数値 (1〜10) | `3` | 検証ループのやり直しの回数 |

`userConfig` の型は `string`、`number`、`boolean`、`directory`、`file` の 5 つで、配列は `string` に `multiple: true` を付けて表す。`multiple` の項目は `/config` の一覧に出ないので、`/plugin` の設定の画面から変える。

フックは値を環境変数 `CLAUDE_PLUGIN_OPTION_<KEY>` (`<KEY>` は大文字) で受け取る。値が読めないときや不正なときは既定値を使う。

値は `pluginConfigs` に入る。公式ドキュメント (settings の `pluginConfigs`) によると、読まれるのはユーザーと managed の settings だけで、プロジェクトとローカルの settings に書いても無視される (クローンしたリポジトリから値を差し込めないようにするため)。守るブランチなどをプロジェクトごとに変えることはできないので、v1 の「対象外」のままにする。

Claude が設定を書き換えてガードを緩めることを防ぐため、`~/.claude/settings.json` (値の置き場所の `pluginConfigs` と、プラグインの有効・無効の `enabledPlugins` を含む) の Edit は ask、Bash での書き換えは block にする。

`enabledPlugins` は `pluginConfigs` と違い、プロジェクトの `.claude/settings.json` とローカルの `.claude/settings.local.json` からも読まれ、ユーザーの settings より優先される。そのため、リポジトリの settings に `"code-guard@claude-code-guard": false` があると、ガードは外れる。Claude による書き換えは、ファイルのツールのガード (`.claude/settings*` の Edit は ask) と中核のルール (Bash での書き換えは block) で止まる。クローンした時点で入っている設定は止められない。

## 配布

リポジトリ自体をマーケットプレイスにする。

```bash
/plugin marketplace add 103kaz/claude-code-guard
/plugin install code-guard@claude-code-guard
```

マーケットプレイスの名前 (`marketplace.json` の `name`) は `claude-code-guard` にする。プラグイン名と違い、マーケットプレイス名は `claude-` で始まっても使える。予約されているのは公式のマーケットプレイスの名前と、それを装う名前 (`claude-plugins-v2` など) だけだ (公式ドキュメント marketplace-reference の「Reserved names」)。Claude Code 2.1.293 で、`claude-code-guard` という名前のマーケットプレイスをローカルのディレクトリから追加し、`code-guard@claude-code-guard` をインストールできることを確かめた。同じ手順で `claude-plugins-v2` は `Marketplace name impersonates an official Anthropic/Claude marketplace` で拒まれた。`claude plugin validate` は名前の予約を調べないので、名前を変えたときは追加まで試す。

装う名前の判定は版ごとに厳しくなっている。将来の版で `claude-code-guard` が装う名前とみなされると、登録済みのマーケットプレイスが読み込まれなくなり、外すとプラグインの設定も消える。

`plugin.json` の `version` を上げて配る。安定したら Anthropic のディレクトリに申請する。

サンドボックスはプラグインから設定できない。README で、サンドボックスと併用する設定例を示す。サンドボックスは OS のレベルで書き込みと通信を絞り、このガードは操作の意味 (main への push、terraform destroy など) で止める。

## テストと CI

| 対象 | 方法 |
|---|---|
| ガード | `tests/test-guard.sh`。Bash のガード、ファイルのツールのガード、パックの有効・無効、曖昧な形の確認を試す |
| 検証ループ | `tests/test-verify.sh` |
| PR の前の照合 | `tests/test-doc-check.sh` |
| マニフェスト | `claude plugin validate --strict` |
| CI | GitHub Actions。PR では ubuntu、main への push では ubuntu と macOS。macOS は `/bin/bash` (3.2) で流す。public リポジトリなので無料 |

ガードの判定を変えたら、`test-guard.sh` にケースを足して通す。

## 保証しないこと

README の先頭近くに書く。

- ガードはコマンドの文字列とファイルのパスを見る判定で、サンドボックスではない。python などを経由した同じ操作は止められない。
- 検証ループは Claude に直させる仕組みで、強制ではない。
- リポジトリの `.claude/settings.json` や `.claude/settings.local.json` が `enabledPlugins` でこのプラグインを無効にしていると、ガードは働かない。
- Claude Code のフックの入力の形や、プラグインの仕組みが変わると壊れうる。動作を確かめた Claude Code の版を README に書く。

## 対象外 (v1)

- 運用ルール (PR の書き方、コミットメッセージ、文章の方針)
- コードレビューのスキル (`adversarial-review`) と `/review-loop`、`/retro`、`/address-comments`。文書と実装の照合 (`doc-code-consistency`) は同梱する
- pre-push の gitleaks
- サンドボックスの設定 (README の例だけ)
- Windows
- プロジェクトごとの設定の上書き

## 決めていないこと

確かめて決めたもの (2026-10-15、Claude Code 2.1.293):

- マーケットプレイスの名前は `claude-code-guard` (「配布」)。
- `pluginConfigs` はプロジェクトの settings から読まれない (「設定」)。
- block は exit 2 で返す (「判定の種類」)。
- メッセージの文面は下の「メッセージの案」。block の 2 行目は候補 1 にした。

まだ決めていないもの:

- `permissionDecision: "deny"` の画面の表示。exit 2 の表示はこの環境で見た (`PreToolUse:Bash hook error: [<コマンド>]: <stderr>`。「hook error」と出る)。deny を返すテスト用のプラグインを `claude -p --plugin-dir` で動かそうとしたが、`claude -p` の認証が切れていて (`OAuth session expired`) 動かせなかった。どちらで止めるかは exit 2 に決めたので、残るのは表示の違いを README に書くかどうかだけだ。
- `multiple` の項目が `CLAUDE_PLUGIN_OPTION_PROTECTED_BRANCHES` にどういう形 (JSON の配列か、区切り文字か) で入るか。ドキュメントに書かれておらず、上と同じ理由で試せていない。実装の最初に確かめる。
- マーケットプレイスの名前は `claude plugin validate --strict` を通した。公開時の登録で弾かれるかは未確認。
- フックの `onFailure: "block"` は 2.1.295 以降の機能で、開発に使った 2.1.293 では実機で確かめていない。古い版ではこのキーが無視され、終了コードの動作になる。
- Read への deny と、フックの exit 2 で、画面の表示や Claude に届く文面がどう違うか。どちらで止めるかは exit 2 に決めてあり、違いは未確認。
- リポジトリの settings の `enabledPlugins` でこのプラグインが無効にされている場合の扱い。無効だとこのプラグインのフックは一つも動かないので、プラグイン自身では知らせられない。「保証しないこと」に書くほかに手を打つかを決める。

### メッセージの案

block (exit 2 の stderr、Claude が読む)。1 行目に理由、2 行目に決まった文を付ける。画面では「hook error」の後に出るので、ガードの故障ではないことも書く。

```text
BLOCKED by code-guard: <reason>
This is a policy block, not a hook failure. Do not retry it another way (another command, a script, python). Tell the user why it was blocked and give them the command to run themselves.
```

理由の例 (書き方の例。実際の文面はスクリプトにある):

| 判定 | 文面 |
|---|---|
| 守るブランチへの push | `pushing to a protected branch (main) is not allowed. Push a work branch and open a pull request.` |
| push の形 | `git push with --no-verify, --mirror, --delete (-d) or --all is not allowed.` |
| 機密値 | `reading secret files (.env, *.tfvars, *.tfstate, keys) is not allowed.` |
| CLI の認証情報 | `reading CLI credentials (~/.aws, ~/.config/gcloud, gh tokens, ~/.kube, ~/.docker, ~/.netrc, keychain) is not allowed.` |
| ハーネス | `changing hooks or settings (~/.claude, .claude/settings*, .githooks, .git/config, .git/hooks) from Bash is not allowed.` |
| フックの回避 | `changing core.hooksPath, git aliases or includes is not allowed. It can disable hooks and push checks.` |
| 取得したコードの実行 | `piping curl/wget output into a shell is not allowed.` |
| 依存が無い | `jq was not found, so code-guard cannot read this tool call and blocks it. Install jq (macOS: brew install jq, Debian/Ubuntu: apt install jq).` |
| terraform | `terraform apply must name a saved plan file: terraform apply <planfile>.` |

ask (`permissionDecisionReason`、確認の画面でユーザーが読む)。何が起きるかと、どういうときに承認するかを書く。下の表も書き方の例で、実際の文面はスクリプトにある。

| 判定 | 文面 |
|---|---|
| force push | `git push --force overwrites remote history. Approve only if you asked for a force push of this branch.` |
| 空のリモートへの初回 push | `First push to an empty remote (main). Approve only if you meant to publish this branch to this repository.` |
| 作業ブランチへの push | `git push to <branch>. Approve if you want this pushed.` |
| `git clean`、`reset --hard` など | `This discards uncommitted or untracked files. Approve only if you asked for it.` |
| terraform apply | `terraform apply <planfile>. Approve only if you reviewed this plan.` |
| `.claude/verify.sh` の編集 | `Editing .claude/verify.sh changes what the verify loop checks. Approve only if you asked for this change.` |
| 誤検知がありうる判定 | 理由の後に `If this is a false positive, approve it.` を付ける |

block の 2 行目の書き方の候補 (1 に決めた):

1. 上の案。ガードの故障ではないことと、別の手段で試さないことを書く。
2. 短くする: `Do not work around this. Tell the user why, and give them the command to run themselves.`
3. 短い命令形だけにしたもの: `A human must do this. If needed, tell the user why and the command to run. Do not look for a workaround.`
