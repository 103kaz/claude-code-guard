# 導入

[English](setup.md)

code-guard を入れる、動いていることを確かめる、設定を変える、更新する、外す手順です。迷ったらターミナルを使ってください。以下の手順はどれもターミナルでできます。

## 必要なもの

- macOS か Linux (Windows は対象外)
- bash 3.2 以上、`jq`、`perl`
- Claude Code。確かめたバージョンは [README の「動作を確かめた版」](../README.ja.md#動作を確かめた版) を見てください

`jq` か `perl` が無いときは、そのフックが受け持つ操作をすべて止め、入れ方を返します。

## 入れる

user スコープで入れます。このマシンのすべてのプロジェクトで有効になります。ターミナル、デスクトップ版のローカルセッション、VS Code 拡張は同じ設定ファイルを読むので、どれかで入れれば他でも使えます。クラウドのセッションには読み込まれません。

### ターミナル

シェルで次を実行します。

```bash
claude plugin marketplace add 103kaz/claude-code-guard
claude plugin install code-guard@claude-code-guard
```

2 つ目のコマンドは `Successfully installed plugin: code-guard@claude-code-guard (scope: user)` と表示します。あわせて、`userConfig` の一部が未設定だと表示しますが、全項目に既定値があるので無視して構いません。[設定](#設定)を見てください。

入れたあとは、新しくセッション (`claude`) を始めてください。すでに開いていたセッションには入っていません。そのセッションに読み込むときは `/reload-plugins` を使います。

`claude` を起動した中で同じことをする方法もあります。`/plugin marketplace add 103kaz/claude-code-guard`、続けて `/plugin install code-guard@claude-code-guard` です。install は、プラグインの詳細を開くので、**Install for you (user scope)** を選びます。

### デスクトップ版

先にマーケットプレイスを追加しておく必要があります。デスクトップ版のプラグインの一覧には、追加済みのマーケットプレイスのものしか出ません。上のターミナルのコマンド (`claude plugin marketplace add 103kaz/claude-code-guard`) で、一度だけ追加してください。

そのあと、**Code** タブのローカルまたは SSH のセッションで次の手順をします。

1. プロンプト欄の横の **+** を押し、**Add plugins** を選びます。メニューが **Plugins** になっているときは、それを選んで **Browse plugins** に進みます。
2. **code-guard** を選びます。
3. スコープを選びます。ふつうは自分のアカウント (user) です。

あとで有効・無効の切り替えや削除をするときは、同じメニューの **Manage plugins** を使います。プラグインの一覧は、クラウドのセッションにはありません。WSL のセッションでもプラグインは使えません。

## 動いていることを確かめる

- 新しいセッションで `/` を打ちます。`/code-guard:setup-verify` が出れば入っています。
- `/plugin` の **Installed** タブで、`code-guard @ claude-code-guard` の `Version: 0.2.1` (以降) と `Status: Enabled` を見ます。
- シェルで `claude plugin list` を実行すると、同じ情報が出ます。

デスクトップ版の設定にあるプラグインの画面は、ターミナルと違う一覧を出すことがあります。確かめるときは `claude plugin list` を基準にしてください。

## 設定

全項目に既定値があるので、何も設定しなくても動きます。変えるときは、セッションで `/plugin` を開き、**Installed** タブで **code-guard** を選び、**Configure options** を選びます。項目と既定値は [README の「設定」](../README.ja.md#設定)にあります。設定は、ユーザーと管理者の設定からだけ読まれ、プロジェクト側からは渡せません。

## 更新

`/plugin` の **Installed** タブでプラグインを開き、**Update now** を選ぶか、次を実行します。

```bash
claude plugin update code-guard@claude-code-guard
```

新しい版は、次のセッションから読み込まれます。`Version` は、上と同じ方法で確かめてください。

## 削除

```bash
claude plugin uninstall code-guard@claude-code-guard
```

`/plugin` のプラグインの詳細で **Uninstall** を選んでも同じです。

## うまくいかないとき

| 症状 | 原因と対処 |
|---|---|
| `claude plugin install` が、マーケットプレイスが不明だと失敗する | 先に追加します。`claude plugin marketplace add 103kaz/claude-code-guard` |
| `/code-guard:...` が不明なスキルと言われる、ガードが何も止めない | 入れる前に開いたセッションです。新しくセッションを始めます |
| ガードが受け持つ操作がすべて止まり、メッセージに `jq` か `perl` とある | 足りないものを入れます (macOS なら `brew install jq`) |
| プロジェクトがプラグインを外している | [リポジトリがプラグインを外すとき](../README.ja.md#リポジトリがプラグインを外すとき) を見ます |
| Claude Code のエラーメッセージが出る | `/plugin` の **Errors** タブを開き、[Troubleshoot plugins](https://code.claude.com/docs/en/plugins/troubleshooting) を見ます |

## 次に

- [止めるもの](../README.ja.md#止めるもの)
- [検証ループ](../README.ja.md#検証ループ): `/code-guard:setup-verify` で `.claude/verify.sh` を作ります
