# C:\Users\Yoshi\Documents\GitHub\Codebase_Memory_MCP\docs\WORKSPACE_OPERATIONS.md
# 個人用Codebase Memoryワークスペースの定義、同期、段階的な運用開始手順。

## 目的

ワークスペースは、複数のGitリポジトリを明示的に選び、同じCodebase Memoryのローカルキャッシュへ索引するための管理単位です。MCP本体が提供する個別プロジェクト索引と横断グラフを利用し、ここでは対象範囲・資源上限・横断関係を宣言します。

索引はコード読解を補助するものであり、ソース本文の確認、テスト、実行環境の検証を置き換えません。

## 初期ワークスペース

`workspaces/jmrc-kinki.json` は初回対象として、次の1リポジトリだけを登録しています。

| ID | パス | 索引モード | 横断対象 |
| --- | --- | --- | --- |
| `jmrckinki` | `C:\Users\Yoshi\Documents\GitHub\jmrckinki` | `full` | なし |

`jmrckinkimanage` は明示的に含めていません。追加は、実際に共有するAPI・DB・メッセージング・リポジトリ間依存を確認してから行います。

## 安全境界

- `allowed_root` と同一または配下かつGitリポジトリであるパスだけを受け入れます。初期ワークスペースでは `jmrckinki` 自体を許可ルートにしており、他のローカルリポジトリは索引できません。
- 同期前に全プロジェクトと横断対象を検証するため、定義誤りで一部だけ索引することを防ぎます。
- `persistence` は初期値を `false` とし、`.codebase-memory/graph.db.zst` を各リポジトリへ作成・コミットしません。
- `jmrckinki` はDB接続・メール／FCM設定、サービスアカウント、SQLダンプ、口座定義、デバッグ用ファイルを `.cbmignore` で除外します。同期スクリプトはこの除外設定が欠けていれば索引を拒否します。
- `CBM_ALLOWED_ROOT`、`CBM_CACHE_DIR`、`CBM_MEM_BUDGET_MB` はスクリプト実行プロセス内だけで設定し、既存のCodex設定・ユーザー環境変数は変更しません。
- 初期設定ではバックグラウンド監視とグラフUIを有効にしません。

## 定義形式

ワークスペース定義はJSONです。`projects[].id` は一意、`path` は `allowed_root` の配下、`cross_repo_targets` は同じ定義内の別IDだけを指定できます。

```json
{
  "schema_version": 1,
  "id": "example",
  "allowed_root": "C:\\Code",
  "runtime": {
    "cache_dir": "C:\\Users\\example\\AppData\\Local\\CodebaseMemoryMCP",
    "max_memory_mb": 2048
  },
  "projects": [
    {
      "id": "service-a",
      "path": "C:\\Code\\service-a",
      "index_mode": "full",
      "persistence": false,
      "required_cbmignore_patterns": ["/.env", "/config/credentials.json"],
      "cross_repo_targets": ["service-b"]
    }
  ]
}
```

横断対象は、HTTP、gRPC、GraphQL、tRPC、イベントチャネルのような明示的なサービス境界がある場合だけに指定します。単に同じ業務に属するという理由で接続しません。

## 実行手順

1. リリースのSHA-256と来歴を検証した `codebase-memory-mcp.exe` を用意します。
2. まず設定だけを検証します。

   ```powershell
   .\scripts\sync_workspace.ps1 -WorkspaceFile .\workspaces\jmrc-kinki.json -DryRun
   ```

3. 出力されたパス、ファイル数、容量、許可ルートを確認します。
4. 実行ファイルを明示し、一度だけ手動索引します。

   ```powershell
   .\scripts\sync_workspace.ps1 `
     -WorkspaceFile .\workspaces\jmrc-kinki.json `
     -ExecutablePath C:\\verified\\codebase-memory-mcp.exe
   ```

5. Codexに同じ実行ファイルと同じキャッシュルートをMCPとして設定し、`list_projects` と `index_status` で `jmrckinki` の登録・鮮度を確認します。
6. 索引結果を、既知のPHP関数、ルート、イベント申込・参加費処理の依存関係で通常の検索結果と照合します。

## 次の追加判断

別リポジトリを加えるときは、最初に独立した索引だけを行います。複数リポジトリの共通親を `allowed_root` にする場合は、対象専用のクローン領域を用意し、通常の作業用リポジトリ全体を許可しないでください。横断対象の指定は、呼び出し側・受け側・プロトコル・期待する関係を検証してから追加します。自動索引・監視・Git共有アーティファクトは、手動同期の正確性と資源使用量を確認した後の別変更として扱います。
