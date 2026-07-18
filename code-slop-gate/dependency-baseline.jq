def dependency_error:
  .engine == "security"
  and .rule == "security/vulnerable-dependency"
  and .severity == "error";

def fingerprint:
  [.rule, .message, (.detail // "")];

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
