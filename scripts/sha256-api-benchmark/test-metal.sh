#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
out="$root/artifacts/metal-sha256"
logdir="$out/host-tests-$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$logdir"
"$root/Libraries/MetalSHA256/test.sh" "$out" > "$logdir/library-tests.log" 2>&1
"$root/scripts/sha256-api-benchmark/test.sh" > "$logdir/legacy-cpu-tests.log" 2>&1
# Optimized no-copy owner-lifetime regression: includes actual CPU/GPU use after
# extracting Data views, with every output and full rolling digest checked.
"$out/bin/sha256-api-benchmark" --metal-batch --smoke --output-dir "$logdir/mini" > "$logdir/mini.log" 2>&1
python3 - "$logdir/mini" <<'PY'
from pathlib import Path
import json,csv,sys,collections,math
p=Path(sys.argv[1]);r=json.loads((p/'batch-report.json').read_text());rows=r['measurements']
assert r['completed'] and len(rows)==24 and len(r['summaries'])==12
assert len(list(csv.DictReader((p/'batch-measurements.csv').open())))==24
seen=set();groups=collections.defaultdict(list)
for m in rows:
 key=(m['messageBytes'],m['messageCount'],m['api'],m['repetition']);assert key not in seen;seen.add(key)
 assert m['totalBytes']==m['messageBytes']*m['messageCount']*m['iterations']
 assert math.isclose(m['gbPerSecond'],m['totalBytes']/m['elapsedNanoseconds'],rel_tol=1e-12)
 groups[(m['messageBytes'],m['messageCount'],m['repetition'])].append(m)
 if m['api']!='CryptoKitCPU-batch':
  assert m['completedGPUCommands']==m['iterations'] and m['gpuCommandSeconds']>0
  assert m['lastGPUEndSeconds']>m['firstGPUStartSeconds']>0
 else:assert m['completedGPUCommands']==0
for group in groups.values():assert len(group)==3 and group[0]['sink']==group[1]['sink']==group[2]['sink']
print('PASS: 24 matched CPU/GPU rows, 12 summaries, every digest signature, GPU command evidence and CSV arithmetic')
PY
printf 'PASS: public GPU clients, legacy CPU tests and optimized lifetime regression\nLogs: %s\n' "$logdir"
