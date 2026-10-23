# claude-code-guard

Claude Code のプラグイン code-guard。仕様は `docs/spec.md`、使い方は `README.md` / `README.ja.md`。

## 変更するとき
- ガードの判定を変えたら、先に `tests/test-guard.sh` にケースを足してから直す。検証ループなら `tests/test-verify.sh`。
- 公開リポジトリなので、個人情報 (ユーザー名、メールアドレス、手元のパス、非公開リポジトリの名前) を書かない。
- レビューの観点 (`.claude/review/checklist.md`) には観点と確かめ方だけを書き、経緯を書かない。
- 機密パターン名 (`.env`、`*.tfvars`、`*.key` など) を含むガードやテストは、Bash の heredoc ではなく Write / Edit ツールで作る。自分のガードに止められるため。
- ガードに止められたら回避策を探さない。理由と、人間が実行するコマンドを示す。
- サンドボックスが原因と思われる失敗 (テストの失敗、通常は行える処理が止まる) は、「環境のせい」で済ませず、原因を切り分けて根本から直す。テストやスクリプトが環境に依存するなら、そちらを直す (例: macOS の `/usr/bin/git` は xcrun のシムで、`HOME` を変えるとサンドボックスの書き込めない場所へキャッシュを書こうとして stderr に出すので、テストでは実体の git を使う)。直せないものだけを、理由つきで利用者に報告する。

## 検証
```bash
bash tests/test-guard.sh
bash tests/test-verify.sh
bash tests/test-check-deps.sh
bash tests/test-check-enabled.sh
```

## PR
- 変更はブランチを切って PR にする。main へ直接 push しない (空のリモートへの初回 push だけ例外)。
- タイトルと本文は日本語、`feat:` `fix:` などのプレフィックスを付ける。
- PR を作る前に、doc-code-consistency スキルで、ブランチの差分の文書が実装と合っているかを確かめる。食い違いを直したら確かめ直す。
