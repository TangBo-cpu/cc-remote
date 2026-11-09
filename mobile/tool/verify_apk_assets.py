"""Reject APKs with missing Flutter fonts or bundled images before installation."""

import argparse
import json
from pathlib import Path
import zipfile


def verify(apk: Path) -> int:
    mobile = Path(__file__).resolve().parents[1]
    prefix = "assets/flutter_assets/"
    with zipfile.ZipFile(apk) as archive:
        entries = {entry.filename: entry.file_size for entry in archive.infolist()}

        def require(asset: str) -> None:
            if entries.get(prefix + asset, 0) == 0:
                raise ValueError(f"Missing or empty Flutter asset: {asset}")

        require("AssetManifest.bin")
        require("FontManifest.json")
        fonts = json.loads(archive.read(prefix + "FontManifest.json"))
        families = {font["family"] for font in fonts}
        for family in (
            "MaterialIcons",
            "packages/lucide_icons_flutter/Lucide",
            "packages/phosphor_icons/PhosphorFill",
        ):
            if family not in families:
                raise ValueError(f"Missing icon font family: {family}")
        for family in fonts:
            for font in family["fonts"]:
                require(font["asset"])
        for asset in (mobile / "assets").rglob("*"):
            if asset.is_file() and asset.suffix.lower() in {".png", ".ttf"}:
                require(asset.relative_to(mobile).as_posix())
        corrupt = archive.testzip()
        if corrupt:
            raise ValueError(f"Corrupt APK entry: {corrupt}")
        return sum(name.startswith(prefix) and size > 0 for name, size in entries.items())


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apk", type=Path)
    args = parser.parse_args()
    try:
        count = verify(args.apk)
    except (OSError, ValueError, KeyError, zipfile.BadZipFile) as error:
        parser.exit(1, f"APK asset check failed: {error}\n")
    print(f"APK assets verified: {count} files; icon fonts and bundled images present.")
