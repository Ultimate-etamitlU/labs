#!/usr/bin/env python3
"""Add or update a labportal user. Run as root on the lab host."""
import argparse
import os
import sqlite3
import subprocess
import sys

DB = os.environ.get("LABPORTAL_DB", "/root/labs/labportal/labportal.db")


def hash_password(password):
    from argon2 import PasswordHasher
    return PasswordHasher().hash(password)


def main():
    p = argparse.ArgumentParser(description="Add/update a labportal user")
    p.add_argument("email")
    p.add_argument("first_name")
    p.add_argument("last_name")
    p.add_argument("password")
    p.add_argument("linux_username")
    p.add_argument("--admin", action="store_true")
    p.add_argument("--inactive", action="store_true")
    p.add_argument("--must-change", action="store_true")
    args = p.parse_args()

    h = hash_password(args.password)
    conn = sqlite3.connect(DB)
    conn.row_factory = sqlite3.Row

    existing = conn.execute("SELECT id FROM users WHERE email=?", (args.email,)).fetchone()
    if existing:
        conn.execute(
            "UPDATE users SET first_name=?, last_name=?, password_hash=?, linux_username=?, "
            "is_admin=?, is_active=?, must_change_password=? WHERE email=?",
            (args.first_name, args.last_name, h, args.linux_username,
             1 if args.admin else 0, 0 if args.inactive else 1,
             1 if args.must_change else 0, args.email)
        )
        print(f"Updated: {args.email}")
    else:
        conn.execute(
            "INSERT INTO users (email, first_name, last_name, password_hash, linux_username, "
            "is_admin, is_active, must_change_password) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (args.email, args.first_name, args.last_name, h, args.linux_username,
             1 if args.admin else 0, 0 if args.inactive else 1,
             1 if args.must_change else 0)
        )
        print(f"Created: {args.email}")

    conn.commit()

    row = conn.execute(
        "SELECT id, email, first_name, last_name, linux_username, is_admin, is_active, must_change_password "
        "FROM users WHERE email=?", (args.email,)
    ).fetchone()
    for k in row.keys():
        print(f"  {k}: {row[k]}")

    # Create Linux user if not exists
    result = subprocess.run(["id", args.linux_username], capture_output=True)
    if result.returncode != 0:
        subprocess.run(["useradd", "-m", "-s", "/bin/bash", args.linux_username], check=True)
        print(f"Linux user created: {args.linux_username}")
    else:
        print(f"Linux user exists: {args.linux_username}")

    subprocess.run(["chpasswd"], input=f"{args.linux_username}:{args.password}", text=True, check=True)
    print(f"Linux password set for: {args.linux_username}")


if __name__ == "__main__":
    main()
