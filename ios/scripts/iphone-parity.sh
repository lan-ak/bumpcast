#!/bin/zsh
# The iPhone must look exactly as it did before (the Duo work changes the Duo only). Renders every
# iPhone screen and state in an earlier commit and in the current working tree, then diffs them
# pixel for pixel.
#
#   scripts/iphone-parity.sh [base-ref] [out-dir]
#
# base-ref defaults to HEAD. Both trees are exported without Secrets.xcconfig, so both build as demo
# builds and can never reach production. Main's working tree is only read. Screens render on an
# iPhone 17 Pro and an iPhone SE (3rd generation), plus the closed Duo's outer screen (466x678), at
# the default text size and AX3, online and offline (-forceOffline). Set PRO_UDID and SE_UDID to
# use particular simulators.
set -euo pipefail

BASE=${1:-HEAD}
OUT=${2:-${TMPDIR:-/tmp}/iphone-parity}
REPO=$(git -C "$(dirname "$0")/.." rev-parse --show-toplevel)
PRO=${PRO_UDID:?set PRO_UDID to an iPhone 17 Pro simulator}
SE=${SE_UDID:?set SE_UDID to an iPhone SE simulator}

rm -rf "$OUT"; mkdir -p "$OUT/base" "$OUT/current" "$OUT/images"

# The two trees.
git -C "$REPO" archive "$BASE" ios | tar -x -C "$OUT/base"
rsync -a --exclude build --exclude '*.xcodeproj' --exclude Secrets.xcconfig "$REPO/ios" "$OUT/current/"
rm -f "$OUT/base/ios/Config/Secrets.xcconfig"
cp "$REPO/ios/BumpCastTests/IPhoneParityTests.swift" "$OUT/base/ios/BumpCastTests/"
cat > "$OUT/base/ios/BumpCastTests/IPhoneParityAdapter.swift" <<'SWIFT'
import SwiftUI

@testable import BumpCast

/// The earlier build's side of the iPhone comparison: unlocked already (no Superwall key), and
/// sheets presented as it presented them.
@MainActor
enum IPhoneParityAdapter {
    static func prepare() {}
}

extension View {
    func paritySheet<Content: View>(isPresented: Binding<Bool>, content: @escaping () -> Content) -> some View {
        sheet(isPresented: isPresented, content: content)
    }
}
SWIFT

swiftc -O "$REPO/ios/scripts/parity-diff.swift" -o "$OUT/parity-diff"

# Build both first, then render base and current back to back, so clock text differs as little as possible.
for TREE in base current; do
  (cd "$OUT/$TREE/ios" && xcodegen generate --quiet)
  xcodebuild -project "$OUT/$TREE/ios/BumpCast.xcodeproj" -scheme BumpCast -destination "id=$PRO" \
    -derivedDataPath "$OUT/$TREE/dd" build-for-testing -quiet
  RUN=$(ls "$OUT/$TREE/dd/Build/Products/"*.xctestrun | grep -v offline | head -1)
  # The same run with -forceOffline for the test host, for the offline states.
  OFFLINE="${RUN%.xctestrun}-offline.xctestrun"
  cp "$RUN" "$OFFLINE"
  # Format 1 xctestruns list each test target under its own name; its host app gets these arguments.
  /usr/libexec/PlistBuddy -c "Add :BumpCastTests:CommandLineArguments:0 string -forceOffline" "$OFFLINE"
done

for MODE in online offline; do
  for DEVICE in pro se; do
    UDID=$PRO; SIZES="pro:402x874,closed-duo:466x678"
    [[ $DEVICE == se ]] && { UDID=$SE; SIZES="se:375x667"; }
    # The base twice: what two renders of the same code differ by (Liquid Glass, animation phases,
    # clock text) is the noise a real change has to stand out from.
    for RUNNING in base current base-again; do
      TREE=${RUNNING%-again}
      FILE=$(ls "$OUT/$TREE/dd/Build/Products/"*.xctestrun | grep -v offline | head -1)
      [[ $MODE == offline ]] && FILE="${FILE%.xctestrun}-offline.xctestrun"
      TEST_RUNNER_PARITY_OUT="$OUT/images/$RUNNING" TEST_RUNNER_PARITY_SIZES="$SIZES" \
        xcodebuild test-without-building -xctestrun "$FILE" -destination "id=$UDID" \
        -only-testing:BumpCastTests/IPhoneParityTests > "$OUT/$RUNNING-$MODE-$DEVICE.log" 2>&1 \
        || { echo "render failed: $RUNNING $MODE $DEVICE (see $OUT/$RUNNING-$MODE-$DEVICE.log)"; exit 2; }
    done
  done
done

"$OUT/parity-diff" "$OUT/images/base" "$OUT/images/current" "$OUT" || true
"$OUT/parity-diff" "$OUT/images/base" "$OUT/images/base-again" "$OUT/noise" > /dev/null || true

# A case fails when the current build differs from the base clearly more than the base differs
# from itself: over three times the noise and over 3,000 pixels, or at all where the base is steady.
python3 - "$OUT/report.tsv" "$OUT/noise/report.tsv" "$OUT/flagged.tsv" <<'PY'
import csv, sys
def load(path):
    return {r["name"]: r for r in csv.DictReader(open(path), delimiter="\t")}
current, noise = load(sys.argv[1]), load(sys.argv[2])
flagged = []
for name, row in sorted(current.items()):
    if row["status"] == "same":
        continue
    base = noise.get(name, {})
    pixels = int(row["pixels"]) if row["pixels"].isdigit() else -1
    steady = int(base["pixels"]) if base.get("pixels", "").isdigit() else (0 if base.get("status") == "same" else -1)
    if row["status"] != "differs" or steady < 0 or pixels > max(3 * steady, steady + 3000):
        flagged.append(f"{name}\t{row['status']}\t{row['pixels']}\t{row['box']}\tnoise {base.get('pixels', '?')}")
open(sys.argv[3], "w").write("\n".join(flagged) + ("\n" if flagged else ""))
print(f"{len(current)} cases: {len(current) - len(flagged)} identical or within noise, {len(flagged)} flagged ({sys.argv[3]}).")
sys.exit(1 if flagged else 0)
PY
