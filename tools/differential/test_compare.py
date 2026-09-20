import json
import unittest
from pathlib import Path

from compare import compare, load_spec


class DifferentialProtocolTests(unittest.TestCase):
    def test_spec_covers_six_requested_domains(self):
        spec = load_spec(Path(__file__).with_name("fixtures.json"))
        self.assertEqual(
            {fixture["domain"] for fixture in spec["fixtures"]},
            {"layout_geometry", "animation_values", "input_traces", "text_ranges", "scene_digests", "virtualized_large_lists"},
        )

    def test_tolerance_is_applied_but_missing_records_fail(self):
        spec = load_spec(Path(__file__).with_name("fixtures.json"))
        rows = []
        for fixture in spec["fixtures"]:
            for case in fixture["cases"]:
                rows.append(json.dumps({"fixture": fixture["id"], "case": case, "values": {"value": 1.0}}))
        text = "\n".join(rows)
        self.assertEqual(compare(spec, text, text), [])
        self.assertTrue(compare(spec, text.rsplit("\n", 1)[0], text))

    def test_different_digest_is_not_hidden_by_numeric_tolerance(self):
        spec = load_spec(Path(__file__).with_name("fixtures.json"))
        fixture = spec["fixtures"][4]
        record = json.dumps({"fixture": fixture["id"], "case": fixture["cases"][0], "values": {"digest": "a"}})
        other = json.dumps({"fixture": fixture["id"], "case": fixture["cases"][0], "values": {"digest": "b"}})
        self.assertTrue(compare(spec, record, other))


if __name__ == "__main__":
    unittest.main()
