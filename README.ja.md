# code-guard

[English](README.md)

Claude Code が実行しようとする危ない操作をフックで止め、応答を終える前にプロジェクト自身の検証を走らせるプラグインです。

## 保証しないこと

- ガードはコマンドの文字列とファイルのパスを見る判定で、サンドボックスではありません。python などを経由した同じ操作は止められません。
- ガードはシェルを構文解析しません。読み切れない形 (引用符で囲んだ・分割したコマンド名やサブコマンド、引用符や展開で組み立てた `git push` の引数、守る対象のコマンドの行継続、読めない heredoc の印) は、判定せずに確認 (ask) に回します。[既知の制限](CHANGELOG.md#known-limits)を参照してください。
- Grep は、対象の `path` が機密値のファイルのときだけ止めます。ディレクトリを検索して結果に機密値のファイルが混ざる場合は止められません。
- 検証ループは Claude に直させる仕組みで、強制ではありません。`verify.sh` を通さずに終える方法は残ります。
- フックの入力の形やプラグインの仕組みは、Claude Code の版で変わることがあります。[動作を確かめた版](#動作を確かめた版)を見てください。
- リポジトリ側でプラグインを外せます。プロジェクトの `.claude/settings.json` の `enabledPlugins` は、ユーザーの設定より優先されます。Claude がこれらのファイルを書き換えるのは止まりますが (確認またはブロック)、クローンした時点で入っている設定は止められません。

## 導入

```bash
/plugin marketplace add 103kaz/claude-code-guard
/plugin install code-guard@claude-code-guard
```

bash 3.2 以上、`jq`、`perl` が要ります。対象は macOS と Linux で、Windows は対象外です。`jq` か `perl` が無いときは、そのフックが受け持つ操作をすべて止め、入れ方を返します。

## 止めるもの

判定は 3 種類です。**block** は exit 2 で止め、承認しても通りません。**ask** はユーザーに確認の画面を出します。それ以外は通します。

### 中核のルール (外せません)

| 分類 | block | ask |
|---|---|---|
| 守るブランチ | 守るブランチへの push (そのブランチにいて引数なしの `git push`、`heads/main`、`cd` や `GIT_DIR=` で移った先のリポジトリも)、`:` だけやワイルドカードの refspec | 空のリモートへの初回 push |
| push の形 | `--no-verify`、`--mirror`、`--delete` / `-d` / `:ref`、`--prune`、`--all` | force push (`+ref` も)、`confirm_push` が有効なときの作業ブランチへの push |
| フックの回避 | `core.hooksPath`、`git -c`、`--config-env`、`GIT_CONFIG_*`、alias と include の設定、core / alias / include のセクションの削除、`HOME=` / `XDG_CONFIG_HOME=` を変えた git、`~/.gitconfig` / `~/.config/git/config` の書き換え、commit / merge の `--no-verify` (`commit -n`) | |
| 機密値 | `.env` / `.env.*` (サンプルを除く)、`*.tfvars`、`*.tfstate`、`*token*.txt`、`*.pem`、`*.key`、`~/.ssh`、署名資産、サービスアカウント鍵、CLI の認証情報、git の資格情報 (`~/.git-credentials`、`git credential fill`)、キーチェーンの値。`<`、`rev:`、`--opt=` の後の名前 (terraform の `-var-file=` は除く) と、展開するとこれらになるグロブやブレース (`.en?`、`.e{n,x}v`) も | |
| ハーネス | `~/.claude` の settings・フック・プラグイン、`.claude/settings*`、`.githooks`、`.git/config`、`.git/hooks` (`.git/modules/` の下のサブモジュールも) の Bash での書き換え。書き換えに数えるのは、リダイレクト、`sed` / `perl` / `ruby -i`、`awk -i inplace`、ファイルのコマンド、`dd`、`rsync`、`curl -o`、`wget -O`、`git checkout` / `restore` / `apply` / `am`。`cd` の後の相対パスも | `.claude/hooks`、`.claude/verify.sh`、`.github/workflows` の Bash での書き換え |
| 取得したコードの実行 | `curl` / `wget` の出力を、シェル (`/bin/sh`、`env bash` など。パイプの何段後でも) やインタプリタ (`python3`、`perl`、`node` など。curl のすぐ次の段か、後ろの段で標準入力からプログラムを読む形) に渡すパイプ | プロセス置換、`bash -c "$(curl ...)"`、`eval` |
| 消す操作 | ルートやホームへの `rm -r` (`--` や長いオプションの後も) | ビルドの生成物でないディレクトリの `rm -r`、`git clean`、`reset --hard`、`restore`、`checkout [<rev>] --`、`stash drop`、`branch -D`、`xargs rm`、`find -delete` / `-exec rm` |
| マシンの設定 | | `sudo`、`launchctl` の登録、`crontab`、`defaults write` |

コミットメッセージや PR 本文 (`-m`、`--body`、heredoc) に書いただけの文字列は判定しません。ただし `bash -c`、`eval`、python などを含むコマンドでは除きません。ダブルクォートの値や引用符の無い heredoc の中の `$(...)` とバッククォートは実行されるので、判定します。

### ファイルのツール (`guard-file.sh`)

プラグインは permissions を配れないので、フックで止めます。

| ツール | block | ask |
|---|---|---|
| Read、Grep | 機密値のファイル (中核の機密値と同じパターン) | |
| Edit、Write、MultiEdit、NotebookEdit | `*.tfvars`、`.git/config`、`.git/hooks`、`~/.gitconfig`、`~/.config/git/config` | `~/.claude`、`.claude/settings*`、`.claude/hooks`、`.claude/verify.sh`、`.githooks`、`.github/workflows` |

### MCP ツール (`guard-mcp.sh`)

ツール名に `delete`、`destroy`、`drop`、`purge`、`remove`、`truncate`、`wipe`、`erase`、`deploy`、`publish`、`unpublish`、`rollback`、`secret` の語があるか、`merge_pull_request`、`merge_branch`、`push_files`、`push_branch`、`force_push`、`create_or_update_file`、`update_file`、`create_commit`、`update_ref` なら ask です。`query`、`sql`、`execute`、`exec` のツールは、入力が変更系の文 (`DROP`、`DELETE`、`UPDATE`、`INSERT`、`MERGE`、`GRANT`、`REVOKE`、`COPY` など。コメントは外して読みます) のとき ask です。`jq` か `perl` が無いときは、MCP のツールをすべて止めます。

### パック

既定ではすべて有効です。方針が自分の運用に合わないときに外します。パックを外しても、機密値の読み出しは中核で止まります。

| パック | 判定 |
|---|---|
| `github` | block: `gh secret set/delete`、`gh variable delete`、`gh repo delete`、`gh release delete`、`gh pr merge --admin/--auto`、`gh repo edit --visibility`、`gh api` の変更系 (リポジトリ設定の経路への単独の呼び出しは ask)。ask: `gh pr merge`、`gh workflow run`、`gh release create`、`gh gist create` |
| `terraform` | block: `destroy`、`import`、`taint`、`untaint`、`force-unlock`、state の変更、plan と apply を 1 コマンドで、`-auto-approve` など。ask: 保存した plan ファイルの `apply`。`.tf` を Edit / Write した後に `terraform fmt` |
| `gcp` | block: ディスク・インスタンス・プロジェクト・ストレージ・SQL インスタンスの削除、`gsutil rm/rb`、Secret Manager の値とアクセストークンの出力 |
| `cloudflare` | block: `wrangler` の deploy / delete / rollback / secret の変更 |

## 検証ループ

ファイルを変えたまま応答を終えようとしたとき、プロジェクトに `.claude/verify.sh` があれば Stop フックが走らせます。失敗したら出力の末尾 80 行を Claude に返します (exit 2)。1 回の中で `verify_max_retry` 回 (既定 3) 失敗したら、ユーザーに知らせて通します。`.claude/verify.sh` が無ければ何もしません。

「変わったか」は、プロンプトを送った時点の HEAD、追跡中のファイルの差分、追跡外のファイルの指紋と比べます。回の前からある変更だけでは走りません。git の外では、プロンプトを送った後に変わった・名前を変えた・消したファイルがあれば走ります。

`/code-guard:setup-verify` で雛形を作れます。ビルドの設定を見て速い lint とテストを提案し、同意を得てから書きます。

## トークンの消費

コンテキストを食わないように作っています。

- ガードと、回の始めを記録するフックは、通ったときは何も出力しません。block と ask のときだけ数行が足されます。
- セッションに常に載るのは `/code-guard:setup-verify` の 1 行の説明だけです。手順の本文は実行したときに読み込まれ、ビルドの設定を最小限だけ読むよう書いてあります。
- 失敗した `verify.sh` が返すのは、80 行かつ 6000 バイトまでです。`verify.sh` は成功時に静かで、速く終わるようにしてください (`--quiet` などが効きます)。

## 設定

`/plugin` の設定の画面で変えます。読まれるのはユーザーと managed の settings だけで、プロジェクトの settings からは渡せません。

| キー | 既定 | 内容 |
|---|---|---|
| `protected_branches` | `main`、`master` | push を block するブランチ |
| `confirm_push` | `true` | 作業ブランチへの push に確認を出す |
| `pack_github` / `pack_terraform` / `pack_gcp` / `pack_cloudflare` | `true` | パックの有効・無効 |
| `verify_max_retry` | `3` | 検証ループの 1 回あたりのやり直しの回数 (1〜10) |

プロジェクトごとの上書きはできません。

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

Claude Code 2.1.293 と上の設定で確かめました。2 つのテストスクリプトは通り、github.com への `git ls-remote` は成功し、プロジェクト外への書き込みは Operation not permitted で失敗し、他のホストは 403 で拒否されます。

## 動作を確かめた版

Claude Code 2.1.293 で開発しています。フックには `onFailure: "block"` を付けています。これは 2.1.295 以降の機能で、実機ではまだ確かめていません。古い版ではこのキーが無視され、終了コードによる動作になります。

## 開発

```bash
bash tests/test-guard.sh    # ガード、パック、設定 (1 分ほど)
bash tests/test-verify.sh   # 検証ループ
```

ガードの判定を変えるときは、先に `tests/test-guard.sh` にケースを足します。

## ライセンス

MIT
