def dependency_error:
  .engine == "security"
  and .rule == "security/vulnerable-dependency"
  and .severity == "error";

# Stable identity for an inherited vulnerability: package + severity + advisory count.
# The rest of the message is remediation prose ("may need override or parent upgrade",
# "upgrade to n8n-workflow@1.75.1") and it changes as soon as the *other* advisories in
# the tree are fixed — keying on the whole message re-failed a pre-existing advisory as
# if it were new. Findings that do not match the "<package> (<severity>)" shape (the
# pip-audit / govulncheck emitters) keep their full message as the identity.
def dependency_identity:
  (.message | capture("^(?<package>\\S+) \\((?<severity>[a-z]+)\\)")) as $head
  | ([.message | capture("\\((?<count>[0-9]+) advisories\\)") | .count] | first // "1") as $count
  | "\($head.package)|\($head.severity)|\($count)";

def fingerprint:
  [.rule, (dependency_identity // .message), (.detail // "")];

($baseline[0].diagnostics // []
  | map(select(dependency_error) | fingerprint)) as $known
| .diagnostics = ((.diagnostics // []) | map(
    . as $diagnostic
    | ($diagnostic | fingerprint) as $candidate
    | if dependency_error and ($known | any(. == $candidate)) then
      .severity = "warning"
      | .message = "\(.message) — baseline on \($base)"
    else
      .
    end
  ))
| .summary.errors = ([.diagnostics[]? | select(.severity == "error")] | length)
| .summary.warnings = ([.diagnostics[]? | select(.severity == "warning")] | length)
