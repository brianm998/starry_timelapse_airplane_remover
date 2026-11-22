import importlib.util, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("compare_formats", os.path.join(HERE, "..", "compare-formats.py"))
cf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cf)


def report(ratios, stars, ext):
    return {"objects": [{"frame": f"{fr}.{ext}", "id": i, "status": "reported", "measurement": {"medianRatio": r}}
                        for (fr, i), r in ratios.items()],
            "stars": {f"{fr}.{ext}": {"medianRatio": v} for fr, v in stars.items()}}


JPG = report({("f1", "a"): 0.1, ("f1", "b"): 0.9, ("f2", "c"): 0.2, ("f2", "d"): 0.3}, {"f1": 0.95, "f2": 0.97}, "jpg")
TIF = report({("f1", "a"): 0.12, ("f1", "b"): 0.9, ("f2", "c"): 0.8, ("f2", "d"): 0.3}, {"f1": 0.96, "f2": 0.99}, "tif")


def test_compare_reports_agreement_and_disagreeing_ids():
    r = cf.compare(JPG, TIF, 0.6)
    assert r["objects_compared"] == 4
    assert r["verdict_agreement"] == 0.75
    assert [(d["frame"], d["id"]) for d in r["disagreeing"]] == [("f2", "c")]
    assert r["removed_fraction_jpeg"] == 0.75 and r["removed_fraction_tiff"] == 0.5
    assert abs(r["removed_fraction_delta"] - 0.25) < 1e-9
    assert abs(r["stretch_ratio_diff_max"] - 0.6) < 1e-9
    assert abs(r["star_flux_diff_median"] - (-0.015)) < 1e-9


def _write(tmp_path, thresholds):
    for n, rep in (("j.json", JPG), ("t.json", TIF)):
        (tmp_path / n).write_text(json.dumps(rep))
    th = {"removed_max": {"value": 0.6}, **{k: {"value": v} for k, v in thresholds.items()}}
    (tmp_path / "th.json").write_text(json.dumps(th))
    return ["--jpeg", str(tmp_path / "j.json"), "--tiff", str(tmp_path / "t.json"),
            "--thresholds", str(tmp_path / "th.json"), "--gate"]


def test_gate_fails_under_agreement_threshold(tmp_path, capsys):
    args = _write(tmp_path, {"format_parity_verdict_agreement_min": 0.8})
    assert cf.main(args) == 1
    assert "c" in capsys.readouterr().out


def test_gate_passes_at_threshold(tmp_path):
    args = _write(tmp_path, {"format_parity_verdict_agreement_min": 0.75, "format_parity_removed_fraction_delta_max": 0.25})
    assert cf.main(args) == 0


def test_gate_fails_on_removed_fraction_delta(tmp_path):
    args = _write(tmp_path, {"format_parity_verdict_agreement_min": 0.5, "format_parity_removed_fraction_delta_max": 0.1})
    assert cf.main(args) == 1


def test_without_gate_never_fails(tmp_path):
    args = _write(tmp_path, {"format_parity_verdict_agreement_min": 0.99})
    args.remove("--gate")
    assert cf.main(args) == 0
