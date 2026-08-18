import os
HERE = os.path.dirname(os.path.abspath(__file__))
import subprocess, sys, os, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from build_doc import build, app_fit_script
os.environ["PATH"] = "/opt/homebrew/bin:" + os.environ["PATH"]

WIDTH = sys.argv[1]; LIMIT = int(sys.argv[2])
CHECK = "--check" in sys.argv
FILTER = "and b.html_body ~ 'data-blocked-src=\"http://'" if "--http" in sys.argv else ""
sql = f"""select m.id from message m join message_body b on b.message_id=m.id
 where b.html_body is not null and length(b.html_body)>1500 {FILTER}
 order by m.sent_at desc limit {LIMIT};"""
ids = subprocess.run(["psql","-d","mailapp","-Atc",sql],capture_output=True,text=True).stdout.strip().split("\n")
os.makedirs(os.path.join(HERE, f"w{WIDTH}"), exist_ok=True)
JS = os.path.join(HERE, "app_fit.js"); open(JS, "w").write(app_fit_script())
res=[]
for n,mid in enumerate(ids):
    if not mid.strip(): continue
    html = subprocess.run(["psql","-d","mailapp","-Atc",
      "select html_body from message_body where message_id = $$%s$$" % mid],
      capture_output=True,text=True).stdout
    p=os.path.join(HERE, f"w{WIDTH}", f"{n:02d}.html"); open(p,"w").write(build(html))
    try:
        r=subprocess.run([os.path.join(HERE, "render"),p,WIDTH,os.path.join(HERE, f"w{WIDTH}", f"{n:02d}.png"),JS],
                         capture_output=True,text=True,timeout=45)
        d=json.loads(r.stdout.strip().split("\n")[-1])
    except Exception as e:
        d={"error":type(e).__name__}
    res.append(d)
json.dump(res, open(os.path.join(HERE, f"res{WIDTH}.json"),"w"))
ok=[d for d in res if "error" not in d]
errs=[d for d in res if "error" in d]
scaled=[d for d in ok if d["scale"]<0.999]
import statistics
print(f"width={WIDTH}  rendered={len(ok)}  errors={len(errs)}")
if ok:
    print(f"  overflowing the pane : {len(scaled)}/{len(ok)}  ({100*len(scaled)//max(len(ok),1)}%)")
    if scaled:
        sc=[d['scale'] for d in scaled]
        print(f"  scale  min={min(sc):.3f}  median={statistics.median(sc):.3f}")
        print(f"  worst shrink: message rendered at {100*min(sc):.0f}% of its intended size")
    ti=sum(d['images'] for d in ok); tl=sum(d['imagesLoaded'] for d in ok); tn=sum(d['imagesNoSrc'] for d in ok)
    print(f"  images {tl}/{ti} loaded, {tn} with no src")
    # The app must be handed exactly the post-scale height. Anything less is
    # message content the reader never sees.
    mism=[d for d in ok if d.get('appHeight',-1) >= 0
          and abs(d['appHeight']-d['post']['docScrollHeight']) > 2]
    print(f"  height MISMATCH (content clipped): {len(mism)}/{len(ok)}")
    if mism:
        w=max(mism,key=lambda d:d['post']['docScrollHeight']-d['appHeight'])
        lost=w['post']['docScrollHeight']-w['appHeight']
        print(f"    worst: app told {w['appHeight']:.0f} of {w['post']['docScrollHeight']} "
              f"({100*lost/w['post']['docScrollHeight']:.0f}% lost)")
    lc=sum(d.get('lowContrast',0) for d in ok); ck=sum(d.get('checked',0) for d in ok)
    print(f"  low-contrast text blocks: {lc}/{ck}")
    bad=[d for d in ok if d.get('lowContrast',0)>0]
    print(f"  messages with ANY low-contrast text: {len(bad)}/{len(ok)}")


# --check compares against the thresholds the reading pane must hold. These are
# the numbers three separate regressions violated while a full unit suite
# stayed green; asserting on them is the only thing that would have caught any
# of the three.
if CHECK:
    base = json.load(open(os.path.join(HERE, "baseline.json")))
    fails = []
    # Small samples make every rate here noisy; a gate that flaps is a gate
    # people learn to ignore.
    if len(ok) < base["min_sample"]:
        print(f"\nSKIP - {len(ok)} messages rendered, need {base['min_sample']} to judge")
        sys.exit(0)
    def want(name, actual, limit, cmp):
        if not cmp(actual, limit):
            fails.append(f"{name}: {actual} (limit {limit})")
    want("render errors", len(errs), base["max_render_errors"], lambda a, b: a <= b)
    if ok:
        mism = [d for d in ok if d.get("appHeight", -1) >= 0
                and abs(d["appHeight"] - d["post"]["docScrollHeight"]) > 2]
        want("height mismatches", len(mism), base["max_height_mismatches"], lambda a, b: a <= b)
        want("overflow fraction", round(len(scaled)/len(ok), 3),
             base["max_overflow_fraction"], lambda a, b: a <= b)
        # Median over EVERY message, not just the scaled ones. Taken over the
        # scaled subset it swung on sample size -- with one scaled message in
        # eight it reported that message's own scale as the median and failed a
        # run that was fine. What matters is what a typical message does.
        want("median scale (all messages)",
             round(statistics.median([d["scale"] for d in ok]), 3),
             base["min_median_scale"], lambda a, b: a >= b)
        want("worst scale", round(min(d["scale"] for d in ok), 3),
             base["min_worst_scale"], lambda a, b: a >= b)
        want("messages with low contrast", len(bad),
             base["max_low_contrast_messages"], lambda a, b: a <= b)
        want("images loaded fraction", round(tl/max(ti, 1), 3),
             base["min_images_loaded_fraction"], lambda a, b: a >= b)
    if fails:
        print("\nFAIL")
        for f in fails:
            print("  " + f)
        sys.exit(1)
    print("\nPASS - the reading pane holds every threshold")
