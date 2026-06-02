import subprocess, sys, os, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
MERGE = os.path.join(HERE, "zoom-audio-merge.py")

CSV_HEADER = "start,end,text\n"


def run(me_csv, others_csv, timeline, audio_start):
    d = tempfile.mkdtemp()
    paths = {}
    for name, content in [("me.csv", me_csv), ("others.csv", others_csv), ("tl.tsv", timeline)]:
        p = os.path.join(d, name)
        with open(p, "w") as f:
            f.write(content)
        paths[name] = p
    out = subprocess.run(
        [sys.executable, MERGE, "--me", paths["me.csv"], "--others", paths["others.csv"],
         "--timeline", paths["tl.tsv"], "--audio-start", str(audio_start)],
        capture_output=True, text=True)
    assert out.returncode == 0, out.stderr
    return out.stdout


def test_me_segments_labelled_me():
    me = CSV_HEADER + '0,2000," I will present now"\n'
    others = CSV_HEADER
    out = run(me, others, "epoch\tname\tmuted\n", 1000.0)
    assert "Me" in out
    assert "I will present now" in out


def test_single_unmuted_gets_name():
    others = CSV_HEADER + '0,2000," sounds good to me"\n'  # 1000.0-1002.0 wallclock
    tl = "epoch\tname\tmuted\n" + "1001.0\tAlice\t0\n" + "1001.0\tBob\t1\n"
    out = run(CSV_HEADER, others, tl, 1000.0)
    assert "Alice" in out
    assert "Bob" not in out
    assert "sounds good to me" in out


def test_multiple_unmuted_gets_candidate_set():
    others = CSV_HEADER + '0,2000," lets discuss"\n'
    tl = "epoch\tname\tmuted\n" + "1001.0\tAlice\t0\n" + "1001.0\tBob\t0\n"
    out = run(CSV_HEADER, others, tl, 1000.0)
    assert "[Alice|Bob]" in out or "[Bob|Alice]" in out


def test_none_unmuted_falls_back_to_others():
    others = CSV_HEADER + '0,2000," background noise"\n'
    tl = "epoch\tname\tmuted\n" + "1001.0\tAlice\t1\n"
    out = run(CSV_HEADER, others, tl, 1000.0)
    assert "Others" in out


def test_chronological_interleave():
    me = CSV_HEADER + '3000,4000," my reply"\n'
    others = CSV_HEADER + '0,2000," their question"\n'
    tl = "epoch\tname\tmuted\n" + "1001.0\tAlice\t0\n"
    out = run(me, others, tl, 1000.0)
    assert out.index("their question") < out.index("my reply")


if __name__ == "__main__":
    # Stdlib runner (no pytest dependency): run every test_* function.
    failures = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn()
                print(f"PASS {name}")
            except AssertionError as e:
                failures += 1
                print(f"FAIL {name}: {e}")
            except Exception as e:
                failures += 1
                print(f"ERROR {name}: {type(e).__name__}: {e}")
    print(f"\n{'OK' if failures == 0 else 'FAILED'} — {failures} failure(s)")
    sys.exit(1 if failures else 0)
