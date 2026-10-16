"""round_stack 加列空间占用实测（只读实验，产出数字供报告引用）。

对同一批"代"行分别建三份库：
  A 基线（现行 20 列）
  B 加两列，两列恒为 NULL
  C 加两列，message_status 全为 'warning' / 'error'，message 为真实长度中文文本
再叠加：ALTER TABLE ADD COLUMN 增量（不重写）与 VACUUM 后的稳态占用。
"""

import os
import random
import sqlite3
import tempfile

ZH = "这是模型生成的中文剧情正文，包含对话、动作、环境描写与心理活动。"
EN = "The model produced narrative text with dialogue and description. "


def zh(n):
    return (ZH * (n // len(ZH) + 1))[:n]


BASE_DDL = """
CREATE TABLE round_stack (
{EXTRA}
  uuid             TEXT PRIMARY KEY,
  book_uuid        TEXT NOT NULL,
  father_uuid      TEXT,
  round_index      INTEGER NOT NULL,
  round_serial_num INTEGER NOT NULL,
  round_state      TEXT,
  round_created_at INTEGER NOT NULL DEFAULT 0,
  user_input         TEXT DEFAULT '',
  ai_narrative       TEXT DEFAULT '',
  world_state        TEXT DEFAULT '',
  character_state    TEXT DEFAULT '',
  memory_summary     TEXT DEFAULT '',
  current_time       TEXT DEFAULT '',
  recommended_action TEXT DEFAULT '',
  tokens_in          INTEGER,
  tokens_out         INTEGER,
  cached_tokens_in   INTEGER,
  model_name         TEXT DEFAULT '',
  user_images        TEXT NOT NULL DEFAULT '[]',
  ai_images          TEXT NOT NULL DEFAULT '[]',
  FOREIGN KEY (book_uuid) REFERENCES books (uuid) ON DELETE CASCADE
)
"""

BOOKS_DDL = "CREATE TABLE books (uuid TEXT PRIMARY KEY, title TEXT)"
IDX = [
    "CREATE INDEX ix_stack_group ON round_stack (book_uuid, round_index, father_uuid, round_serial_num)",
    "CREATE INDEX ix_stack_father ON round_stack (father_uuid)",
    "CREATE INDEX ix_stack_book ON round_stack (book_uuid, round_index)",
]

random.seed(20261017)


def make_rows(n_books, rounds_per_book, gens_per_round):
    rows = []
    for b in range(n_books):
        book = f"book-{b:03d}-uuid"
        for r in range(rounds_per_book):
            father = None
            for g in range(gens_per_round):
                rows.append(
                    dict(
                        uuid=f"{book}-{r}-{g}-uuid-0000-0000",
                        book_uuid=book,
                        father_uuid=father,
                        round_index=r,
                        round_serial_num=g + 1,
                        round_state="use" if g == gens_per_round - 1 else None,
                        round_created_at=1760000000000 + random.randint(0, 10**7),
                        user_input=zh(random.randint(20, 80)),
                        ai_narrative=zh(random.randint(800, 1600)),
                        world_state=zh(random.randint(200, 600)),
                        character_state=zh(random.randint(200, 600)),
                        memory_summary=zh(random.randint(100, 300)),
                        current_time="第三日 · 黄昏",
                        recommended_action=zh(random.randint(10, 40)),
                        tokens_in=random.randint(2000, 6000),
                        tokens_out=random.randint(300, 1200),
                        cached_tokens_in=random.choice([None, 1024]),
                        model_name="deepseek-chat",
                        user_images="[]",
                        ai_images="[]",
                    )
                )
                father = None  # 简化：每代同父（对体积无影响）
    return rows


def col_list(extra):
    cols = [
        "uuid", "book_uuid", "father_uuid", "round_index", "round_serial_num",
        "round_state", "round_created_at", "user_input", "ai_narrative",
        "world_state", "character_state", "memory_summary", "current_time",
        "recommended_action", "tokens_in", "tokens_out", "cached_tokens_in",
        "model_name", "user_images", "ai_images",
    ]
    return cols + extra


def build(path, rows, extra=(), filler=None, vacuum=True):
    if os.path.exists(path):
        os.remove(path)
    con = sqlite3.connect(path)
    con.execute(BOOKS_DDL)
    extra_ddl = "".join(f"  {c} TEXT,\n" for c in extra)
    con.execute(BASE_DDL.replace("{EXTRA}", extra_ddl))
    for ix in IDX:
        con.execute(ix)
    books = sorted({r["book_uuid"] for r in rows})
    con.executemany("INSERT INTO books VALUES (?, ?)", [(b, b) for b in books])
    cols = col_list(list(extra))
    sql = f"INSERT INTO round_stack ({', '.join(cols)}) VALUES ({', '.join('?' * len(cols))})"
    payload = []
    for r in rows:
        vals = [r[c] for c in cols if c not in extra]
        for c in extra:
            vals.append(filler(r, c) if filler else None)
        payload.append(vals)
    con.executemany(sql, payload)
    con.commit()
    if vacuum:
        con.execute("VACUUM")
        con.commit()
    pages = con.execute("PRAGMA page_count").fetchone()[0]
    ps = con.execute("PRAGMA page_size").fetchone()[0]
    con.close()
    return os.path.getsize(path), pages * ps


def report(title, path, rows, extra=(), filler=None):
    size, logical = build(path, rows, extra, filler)
    print(f"{title:<46} 文件 {size/1024/1024:8.3f} MB  页内 {logical/1024/1024:8.3f} MB  行数 {len(rows)}")
    return size


def main():
    tmp = tempfile.mkdtemp(prefix="stack_probe_")
    scenarios = [
        ("小书库 5 本 × 60 轮 × 2 代", make_rows(5, 60, 2)),
        ("中等 20 本 × 80 轮 × 3 代", make_rows(20, 80, 3)),
    ]
    for label, rows in scenarios:
        print(f"\n=== {label}（{len(rows)} 代）===")
        a = report("A 基线（现行 schema）", os.path.join(tmp, "a.db"), rows)
        b = report("B +2 列，全 NULL", os.path.join(tmp, "b.db"), rows,
                   ("message", "message_status"))
        c = report("C +2 列，约 12% 行有中文警告(~60 字)",
                   os.path.join(tmp, "c.db"), rows, ("message", "message_status"),
                   lambda r, col: (None if random.random() > 0.12 else
                                   (zh(60) if col == "message" else "warning")))

        # ALTER TABLE 增量（不重写旧行）与稳态
        p = os.path.join(tmp, "alter.db")
        build(p, rows, (), vacuum=True)
        before = os.path.getsize(p)
        con = sqlite3.connect(p)
        con.execute("ALTER TABLE round_stack ADD COLUMN message TEXT")
        con.execute("ALTER TABLE round_stack ADD COLUMN message_status TEXT")
        con.commit()
        after_alter = os.path.getsize(p)
        print(f"{'D ALTER 加列后（未 VACUUM，无行改写）':<46} 文件 {after_alter/1024/1024:8.3f} MB  "
              f"（Δ {(after_alter-before)/1024:+.1f} KB）")
        con.execute("UPDATE round_stack SET message_status='warning', message=? WHERE rowid % 8 = 0",
                    (zh(60),))
        con.commit()
        after_upd = os.path.getsize(p)
        con.execute("VACUUM")
        con.commit()
        after_vacuum = os.path.getsize(p)
        con.close()
        print(f"{'E 追加约 1/8 行警告后':<46} 文件 {after_upd/1024/1024:8.3f} MB  "
              f"（Δ {(after_upd-before)/1024:+.1f} KB）")
        print(f"{'F VACUUM 稳态（含 1/8 行警告）':<46} 文件 {after_vacuum/1024/1024:8.3f} MB  "
              f"（Δ {(after_vacuum-a)/1024:+.1f} KB / {100*(after_vacuum-a)/a:+.2f}%）")
        print(f"{'   单行边际成本（B - A）':<46} {(b-a)/len(rows):+.2f} B/行；"
              f"（C - A）{(c-a)/len(rows):+.2f} B/行")

    # message 长度 → 单行成本关系
    print("\n=== 单行消息长度 → 边际成本（同一行数下 B 与 C 之差）===")
    rows = make_rows(2, 40, 1)
    null_size = build(os.path.join(tmp, "n.db"), rows, ("message", "message_status"))[0]
    for n_chars in (20, 60, 120, 300):
        s = build(os.path.join(tmp, f"m{n_chars}.db"), rows, ("message", "message_status"),
                  lambda r, col, n=n_chars: (zh(n) if col == "message" else "error"))[0]
        print(f"  message = {n_chars:>3} 个中文汉字（UTF-8 {n_chars*3:>4} B）→ "
              f"整库 Δ {(s-null_size)/1024:+.1f} KB / {len(rows)} 行 = "
              f"{(s-null_size)/len(rows):.2f} B/行")

    print("\n=== 最坏情况：每一代都带消息（同一批 600 代）===")
    rows = make_rows(5, 60, 2)
    base = build(os.path.join(tmp, "w0.db"), rows)[0]
    all_null = build(os.path.join(tmp, "w1.db"), rows, ("message", "message_status"))[0]
    print(f"  全 NULL            {all_null/1024/1024:.3f} MB  Δ {(all_null-base)/1024:+.1f} KB")
    for n_chars, status in ((30, "warning"), (80, "warning"), (400, "error")):
        s = build(os.path.join(tmp, f"w_{n_chars}.db"), rows, ("message", "message_status"),
                  lambda r, col, n=n_chars, st=status: (zh(n) if col == "message" else st))[0]
        print(f"  每代 {n_chars:>3} 汉字 + {status:<7} {s/1024/1024:.3f} MB  "
              f"Δ {(s-base)/1024:+.1f} KB（{(s-base)/len(rows):.2f} B/行，"
              f"{100*(s-base)/base:+.2f}%）")


main()
