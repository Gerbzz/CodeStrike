"""Regression checks for stale and mislabelled diagnostic publications."""

from race_gates import (OTHER, audit_publications, latest, latest_expected_error, native_latest_error,
                        settled_snapshot)


class Client:
    def __init__(self, reports):
        self.diagnostics = reports
        self.diagnostics_overflow = False

    def reports(self, uri):
        return [item for item in self.diagnostics if item["uri"].casefold() == uri.casefold()]


def error(uri, version, text, token, message):
    line = next(i for i, value in enumerate(text.splitlines()) if token in value)
    start = text.splitlines()[line].index(token)
    return {"uri": uri, "version": version, "diagnostics": [{
        "code": "E0308", "source": "rust-analyzer", "message": message,
        "range": {"start": {"line": line, "character": start},
                  "end": {"line": line, "character": start + len(token)}},
    }]}


def main():
    other_uri = "file:///fixture/other.rs"
    initial = error(other_uri, 1, OTHER, '"wrong"',
                    "mismatched types: found &'static str")
    empty = {"uri": other_uri, "version": 1, "diagnostics": []}
    stale = Client([initial, empty])
    if native_latest_error(latest(stale, other_uri), 1, OTHER):
        raise AssertionError("historical other.rs E0308 passed after empty latest report")

    main_text = 'fn main() { let value: i32 = "wrong"; }\n'
    main_uri = "file:///fixture/main.rs"
    main_error = error(main_uri, 1, main_text, '"wrong"', "found &'static str")
    main_empty = {"uri": main_uri, "version": 1, "diagnostics": []}
    if (latest_expected_error(latest(Client([main_error, main_empty]), main_uri), 1, main_text)
            or not latest_expected_error(main_error, 1, main_text)):
        raise AssertionError("cancel-save accepted empty final diagnostics or rejected E0308")

    class LateClient(Client):
        def __init__(self, reports, late):
            super().__init__(reports)
            self.late = late
            self.exact_calls = 0

        def exact(self, path, text):
            self.exact_calls += 1
            if self.exact_calls == 2:
                self.diagnostics.append(self.late)
                self.diagnostics_overflow = True
            return True

        def hold(self, seconds):
            pass

    late_client = LateClient([initial], empty)
    exact, reports, audit = settled_snapshot(late_client, [
        ("first", "main.rs", "any"), ("second", "other.rs", OTHER),
    ], {other_uri: {1: OTHER}}, native_only=True)
    if (not all(exact.values()) or native_latest_error(reports[other_uri], 1, OTHER)
            or not any("exceeded 128" in problem for problem in audit["problems"])):
        raise AssertionError("late empty or overflow after final RPC passed")

    original = main_text
    valid = original.replace('"wrong"', '7')
    final = original.replace('"wrong"', 'true')
    v1 = error(main_uri, 1, original, '"wrong"', "found &'static str")
    v3 = error(main_uri, 3, final, "true", "found bool")
    coalesced = audit_publications(Client([v1, v3]),
                                   {main_uri: {1: original, 2: valid, 3: final}},
                                   native_only=True)
    if coalesced["problems"]:
        raise AssertionError(f"legitimate coalescing rejected: {coalesced}")

    stale_v2 = dict(v1, version=2)
    if not audit_publications(Client([v1, stale_v2]),
                              {main_uri: {1: original, 2: valid}},
                              native_only=True)["problems"]:
        raise AssertionError("stale E0308 on valid text passed")
    stale_v3 = dict(v1, version=3)
    if not audit_publications(Client([v1, stale_v3]),
                              {main_uri: {1: original, 3: final}},
                              native_only=True)["problems"]:
        raise AssertionError("old string error tagged as final bool passed")
    foreign = dict(v1, uri="file:///fixture/unexpected.rs")
    if not audit_publications(Client([v1, foreign]),
                              {main_uri: {1: original}},
                              native_only=True)["problems"]:
        raise AssertionError("unexpected fixture publication passed")
    if not audit_publications(Client([v3, v1]),
                              {main_uri: {1: original, 3: final}},
                              native_only=True)["problems"]:
        raise AssertionError("regressing publication version passed")

    print("RACE_PUBLICATION_AUDIT_TESTS=passed")


if __name__ == "__main__":
    main()
