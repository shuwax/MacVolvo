#!/usr/bin/env python3
"""
Package DXMT pipeline cache backups into a distributable community seed tarball.

The seed contains recipe JSON files and Metal AIR library files gathered from real
CS2 gameplay sessions. When placed at cache/pipelines/seed/ in a MacVolvo
installation, portable_pipeline.swift imports them before every session so new
users start with pre-compiled shader data rather than an empty cache.

Usage:
    python3 package_seed_cache.py [backup_folder ...] [-o seed-cache.tar.gz]

Each backup_folder must contain a subdirectory with recipes/ and libraries/
(the structure DXMT writes). Multiple folders are merged; duplicates are skipped.

Output: seed-cache.tar.gz  (seed/recipes/*.json + seed/libraries/*.air)
        SHA256 printed on stdout for embedding in portable_setup.m
"""

import argparse
import hashlib
import json
import os
import sys
import tarfile
import tempfile


def find_namespace_dirs(root: str) -> list[str]:
    """Return all valid DXMT namespace dirs (64-hex name with recipes/ subdir)."""
    found = []
    try:
        for name in os.listdir(root):
            if len(name) == 64 and all(c in "0123456789abcdef" for c in name):
                p = os.path.join(root, name)
                if os.path.isdir(os.path.join(p, "recipes")):
                    found.append(p)
    except FileNotFoundError:
        pass
    return found


def collect(backup_dirs: list[str]) -> tuple[dict[str, str], dict[str, str]]:
    """
    Collect unique recipes and libraries from all backup dirs.
    Returns (recipes: {filename: src_path}, libraries: {filename: src_path}).
    """
    recipes: dict[str, str] = {}
    libraries: dict[str, str] = {}

    for backup in backup_dirs:
        # Accept either a direct namespace dir (has recipes/) or a parent with
        # namespace subdirs.
        if os.path.isdir(os.path.join(backup, "recipes")):
            ns_dirs = [backup]
        else:
            ns_dirs = find_namespace_dirs(backup)

        if not ns_dirs:
            print(f"Warning: no DXMT namespace dirs found in {backup}", file=sys.stderr)
            continue

        for ns in ns_dirs:
            r_dir = os.path.join(ns, "recipes")
            l_dir = os.path.join(ns, "libraries")

            for fname in os.listdir(r_dir) if os.path.isdir(r_dir) else []:
                if fname.endswith(".json") and fname not in recipes:
                    recipes[fname] = os.path.join(r_dir, fname)

            for fname in os.listdir(l_dir) if os.path.isdir(l_dir) else []:
                if fname.endswith(".air") and fname not in libraries:
                    libraries[fname] = os.path.join(l_dir, fname)

    return recipes, libraries


def validate_recipe(path: str) -> tuple[bool, list[str]]:
    """Return (valid, [library_hashes]) for a recipe file."""
    try:
        with open(path) as f:
            data = json.load(f)
        cost = data.get("cost_us")
        if not isinstance(cost, (int, float)) or cost < 0:
            return False, []
        recipe = data.get("recipe", {})
        if not isinstance(recipe.get("vertex"), dict):
            return False, []
        needed = []
        for key in ("vertex", "fragment"):
            entry = recipe.get(key)
            if isinstance(entry, dict):
                lib = entry.get("library", "")
                if len(lib) == 64 and all(c in "0123456789abcdef" for c in lib):
                    needed.append(lib)
        return True, needed
    except Exception:
        return False, []


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(131072):
            h.update(chunk)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("backups", nargs="*", help="Backup folder(s) to merge")
    ap.add_argument("-o", "--output", default="seed-cache.tar.gz", help="Output tarball path (default: seed-cache.tar.gz)")
    args = ap.parse_args()

    if not args.backups:
        # Default: look for the two standard backup locations from previous sessions
        default_dirs = [
            os.path.expanduser("~/Downloads/cs2_recipes_backup_20261025_163324"),
            os.path.expanduser("~/Downloads/pipelines_backup_20261025_173343"),
        ]
        args.backups = [d for d in default_dirs if os.path.isdir(d)]
        if not args.backups:
            print("No backup folders found. Pass them as arguments.", file=sys.stderr)
            sys.exit(1)

    print(f"Collecting from {len(args.backups)} backup folder(s)...")
    all_recipes, all_libraries = collect(args.backups)
    print(f"  Found {len(all_recipes)} unique recipes, {len(all_libraries)} unique libraries")

    # Validate recipes and find which libraries are actually referenced
    valid_recipes: dict[str, str] = {}
    needed_libs: set[str] = set()
    skipped = 0
    for fname, path in all_recipes.items():
        ok, libs = validate_recipe(path)
        if not ok:
            skipped += 1
            continue
        # Only keep recipes whose required .air files exist in our collection
        missing = [lib + ".air" for lib in libs if (lib + ".air") not in all_libraries]
        if missing:
            skipped += 1
            continue
        valid_recipes[fname] = path
        needed_libs.update(lib + ".air" for lib in libs)

    if skipped:
        print(f"  Skipped {skipped} invalid/incomplete recipes")
    print(f"  Keeping {len(valid_recipes)} recipes, {len(needed_libs)} referenced libraries")

    # Sort by cost descending so the seed prioritises expensive PSOs
    def recipe_cost(item):
        try:
            with open(item[1]) as f:
                return json.load(f).get("cost_us", 0)
        except Exception:
            return 0

    sorted_recipes = sorted(valid_recipes.items(), key=recipe_cost, reverse=True)
    sorted_libs = [(n, all_libraries[n]) for n in needed_libs if n in all_libraries]

    print(f"Building {args.output} ...")
    with tarfile.open(args.output, "w:gz", compresslevel=6) as tar:
        for fname, src in sorted_recipes:
            tar.add(src, arcname=f"seed/recipes/{fname}")
        for fname, src in sorted_libs:
            tar.add(src, arcname=f"seed/libraries/{fname}")

    digest = sha256_file(args.output)
    size_mb = os.path.getsize(args.output) / 1024 / 1024
    print(f"Done: {args.output} ({size_mb:.1f} MB)")
    print(f"SHA256: {digest}")
    print()
    print("Embed in portable_setup.m:")
    print(f'    #define SEED_CACHE_SHA256 @"{digest}"')
    print(f'    // URL: https://github.com/shuwax/MacVolvo/releases/download/seed-cache-v1/seed-cache.tar.gz')


if __name__ == "__main__":
    main()
